/// A single-writer executor slot. The owner keeps its allocation alive. Read only after
/// the executor has completed; concurrent writes must target distinct slots.
struct CPUReadingSlot: @unchecked Sendable {
    fileprivate let owner: ThreadLog
    fileprivate let address: UnsafeMutablePointer<Int>
    fileprivate let written: UnsafeMutablePointer<Bool>

    @inline(__always)
    func store(_ cpu: Int) {
        withExtendedLifetime(owner) {
            address.pointee = cpu
            written.pointee = true
        }
    }
}

/// One preallocated, 128-byte-aligned buffer for a thread's block. The owning thread
/// writes timing, check values and caller CPUs; each executor slot has one writer.
/// The run thread reads only after joins or equivalent executor completion.
final class ThreadLog: @unchecked Sendable {
    private struct Batch {
        var start: UInt64 = 0
        var end: UInt64 = 0
        var checkValue: Int = 0
    }

    private let allocation: UnsafeMutableRawPointer
    private let batches: Int
    private let readingsPerBatch: Int
    private let readingCount: Int
    private let times: UnsafeMutablePointer<Batch>
    private let callerCPUs: UnsafeMutablePointer<Int>
    private let executorCPUs: UnsafeMutablePointer<Int>
    private let executorSlotsWritten: UnsafeMutablePointer<Bool>

    /// Mirrors the allocation's exact byte layout without allocating it.
    static func storageByteCount(batches: Int, readingsPerBatch: Int) throws(RequestError) -> Int {
        guard batches >= 0, readingsPerBatch >= 0 else {
            throw RequestError(message: "negative thread log size")
        }

        let (readings, readingsOverflow) = batches.multipliedReportingOverflow(by: readingsPerBatch)
        let (batchBytes, batchOverflow) = batches.multipliedReportingOverflow(by: MemoryLayout<Batch>.stride)
        let (readingBytes, readingOverflow) = readings.multipliedReportingOverflow(by: MemoryLayout<Int>.stride)
        let (allReadingBytes, allReadingOverflow) = readingBytes.multipliedReportingOverflow(by: 2)
        let (writtenBytes, writtenOverflow) = readings.multipliedReportingOverflow(by: MemoryLayout<Bool>.stride)
        let (valueBytes, valueOverflow) = batchBytes.addingReportingOverflow(allReadingBytes)
        let (totalBytes, totalOverflow) = valueBytes.addingReportingOverflow(writtenBytes)

        guard !readingsOverflow, !batchOverflow, !readingOverflow, !allReadingOverflow,
            !writtenOverflow, !valueOverflow, !totalOverflow
        else {
            throw RequestError(message: "thread log size overflow")
        }

        return max(totalBytes, 1)
    }

    init(batches: Int, readingsPerBatch: Int) {
        let totalBytes: Int
        do throws(RequestError) {
            totalBytes = try Self.storageByteCount(batches: batches, readingsPerBatch: readingsPerBatch)
        } catch {
            preconditionFailure(error.message)
        }

        self.batches = batches
        self.readingsPerBatch = readingsPerBatch
        // Every operation below was checked by storageByteCount before allocation.
        let readingCount = batches * readingsPerBatch
        self.readingCount = readingCount
        let batchBytes = batches * MemoryLayout<Batch>.stride
        let readingBytes = readingCount * MemoryLayout<Int>.stride
        let valueBytes = batchBytes + readingBytes * 2

        allocation = UnsafeMutableRawPointer.allocate(byteCount: totalBytes, alignment: 128)

        times = allocation.bindMemory(to: Batch.self, capacity: batches)
        callerCPUs = allocation.advanced(by: batchBytes).bindMemory(
            to: Int.self,
            capacity: readingCount
        )
        executorCPUs = allocation.advanced(by: batchBytes + readingBytes).bindMemory(
            to: Int.self,
            capacity: readingCount
        )
        executorSlotsWritten = allocation.advanced(by: valueBytes).bindMemory(
            to: Bool.self,
            capacity: readingCount
        )

        times.initialize(repeating: Batch(), count: batches)
        callerCPUs.initialize(repeating: -1, count: readingCount)
        executorCPUs.initialize(repeating: -1, count: readingCount)
        executorSlotsWritten.initialize(repeating: false, count: readingCount)
    }

    var baseAddressForTesting: UInt {
        UInt(bitPattern: allocation)
    }

    @inline(__always)
    func recordTimes(batch: Int, start: UInt64, end: UInt64) {
        precondition(batch >= 0 && batch < batches)
        times[batch].start = start
        times[batch].end = end
    }

    @inline(__always)
    func recordCPU(batch: Int, reading: Int, cpu: Int) {
        callerCPUs[readingIndex(batch: batch, reading: reading)] = cpu
    }

    @inline(__always)
    func executorSlot(batch: Int, reading: Int) -> CPUReadingSlot {
        let index = readingIndex(batch: batch, reading: reading)

        return CPUReadingSlot(
            owner: self,
            address: executorCPUs.advanced(by: index),
            written: executorSlotsWritten.advanced(by: index)
        )
    }

    @inline(__always)
    func recordCheckValue(batch: Int, value: Int) {
        precondition(batch >= 0 && batch < batches)
        times[batch].checkValue = value
    }

    func start(ofBatch batch: Int) -> UInt64 {
        precondition(batch >= 0 && batch < batches)
        return times[batch].start
    }

    func end(ofBatch batch: Int) -> UInt64 {
        precondition(batch >= 0 && batch < batches)
        return times[batch].end
    }

    func cpuReadings(ofBatch batch: Int) -> [Int] {
        precondition(batch >= 0 && batch < batches)

        return Array(UnsafeBufferPointer(
            start: callerCPUs.advanced(by: batch * readingsPerBatch),
            count: readingsPerBatch
        ))
    }

    func executorCPUReadings(ofBatch batch: Int) -> [Int]? {
        precondition(batch >= 0 && batch < batches)

        let written = UnsafeBufferPointer(
            start: executorSlotsWritten.advanced(by: batch * readingsPerBatch),
            count: readingsPerBatch
        )
        guard written.contains(true) else {
            return nil
        }

        let readings = UnsafeBufferPointer(
            start: executorCPUs.advanced(by: batch * readingsPerBatch),
            count: readingsPerBatch
        )
        return Array(readings)
    }

    func checkValue(ofBatch batch: Int) -> Int {
        precondition(batch >= 0 && batch < batches)
        return times[batch].checkValue
    }

    @inline(__always)
    private func readingIndex(batch: Int, reading: Int) -> Int {
        precondition(batch >= 0 && batch < batches)
        precondition(reading >= 0 && reading < readingsPerBatch)

        return batch * readingsPerBatch + reading
    }

    deinit {
        times.deinitialize(count: batches)
        callerCPUs.deinitialize(count: readingCount)
        executorCPUs.deinitialize(count: readingCount)
        executorSlotsWritten.deinitialize(count: readingCount)
        allocation.deallocate()
    }
}
