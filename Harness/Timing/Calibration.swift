import Synchronization

/// Clock overhead and fixed CPU work, measured alone and across all CPUs, and the
/// single-thread work that sizes the priority-inversion holder, plus display callbacks.
struct Calibration: Experiment {
    let blocks: [BlockDescription]
    private let repeats: Int
    private let iterations: Int

    init(request: RunRequest) throws(RequestError) {
        try request.validate()

        guard request.variant == "default" else {
            throw RequestError(message: "variant must be default for calibration")
        }

        guard request.mechanisms.isEmpty else {
            throw RequestError(message: "mechanisms must be empty for calibration")
        }

        guard request.operations.isEmpty else {
            throw RequestError(message: "operations must be empty for calibration")
        }

        guard let repeats = request.tunables.repeats, repeats >= 1 else {
            throw RequestError(message: "repeats must be at least 1 for calibration")
        }

        let cpuCount = PhoneFacts.read().cpuCount
        let (bytes, overflow) = repeats.multipliedReportingOverflow(by: MemoryLayout<CalibrationSample>.stride)
        let (_, aggregateOverflow) = bytes.multipliedReportingOverflow(by: cpuCount)

        guard !overflow, !aggregateOverflow else {
            throw RequestError(message: "repeats sample storage size overflow")
        }

        let (frameNanoseconds, frameOverflow) = UInt64(repeats).multipliedReportingOverflow(by: 50_000_000)
        let (durationNanoseconds, durationOverflow) = frameNanoseconds.addingReportingOverflow(5_000_000_000)
        let timebase = Clock.timebase
        let durationProduct = durationNanoseconds.multipliedFullWidth(by: UInt64(timebase.denom))
        guard !frameOverflow, !durationOverflow, durationProduct.high < UInt64(timebase.numer) else {
            throw RequestError(message: "repeats display deadline overflow")
        }
        self.repeats = repeats
        iterations = request.tunables.referenceLoopIterations
        blocks = [
            "clockSingleThread",
            "clockAllCPUs",
            "cpuSpeedUserInteractive",
            "cpuSpeedBackground",
            "holderWorkSingleThread",
            "displayFrames"
        ].map {
            BlockDescription(
                mechanism: $0,
                operation: "",
                threads: ($0.hasSuffix("SingleThread") || $0 == "displayFrames") ? 1 : cpuCount,
                qos: $0 == "cpuSpeedBackground" ? .background : .userInteractive,
                operationsPerBatch: request.operationsPerBatch(for: $0)
            )
        }

        for description in blocks {
            try BatchLayout(
                warmupBatches: request.tunables.warmupBatches,
                measuredBatches: request.tunables.measuredBatches,
                operationsPerBatch: description.operationsPerBatch,
                subBatches: request.tunables.subBatches
            ).validate(threads: description.threads)
        }
    }

    func run(_ block: BlockContext) -> [CheckResult] {
        if block.description.mechanism == "displayFrames" {
            return runDisplayFrames(block)
        }

        // Allocate and initialize every worker's storage before the block envelope starts.
        let buffers = (0..<block.description.threads).map { _ in
            CalibrationSamples(capacity: repeats)
        }
        let measuresClock = block.description.mechanism.hasPrefix("clock")

        // The holder work has its own metric: the core map pools every referenceLoop line.
        let workMetric = block.description.mechanism == "holderWorkSingleThread"
            ? "holderWork" : "referenceLoop"
        let repeats = repeats
        let iterations = iterations

        _ = block.runOnThreads(recording: .samplesOnly) { thread, barrier, _ in
            let buffer = buffers[thread]
            barrier.arriveAndWait()

            for _ in 0..<repeats {
                if measuresClock {
                    let start = Clock.now()
                    Self.readClock1000()
                    let end = Clock.now()
                    buffer.append(CalibrationSample(ticks: end - start))
                } else {
                    let cpuAtStart = CPU.current()
                    let start = Clock.now()
                    let value = referenceLoop(iterations: iterations)
                    let end = Clock.now()
                    let cpuAtEnd = CPU.current()
                    blackHole(value)
                    buffer.append(CalibrationSample(
                        ticks: end - start,
                        cpuAtStart: cpuAtStart,
                        cpuAtEnd: cpuAtEnd
                    ))
                }
            }
        }

        var passed = true
        for (thread, buffer) in buffers.enumerated() {
            let samples = buffer.samples
            let values = samples.map(\.ticks)
            passed = passed && values.count == repeats

            block.appendSamples(SamplesLine(
                block: block.position,
                thread: thread,
                metric: measuresClock ? "clockRead1000" : workMetric,
                unit: "ticks",
                values: values,
                cpuAtStart: measuresClock ? nil : samples.map(\.cpuAtStart),
                cpuAtEnd: measuresClock ? nil : samples.map(\.cpuAtEnd)
            ))
        }

        return [CheckResult(
            name: "calibration.samples",
            block: block.position,
            passed: passed,
            detail: "Every samples line must contain \(repeats) values",
            violations: nil
        )]
    }

    private func runDisplayFrames(_ block: BlockContext) -> [CheckResult] {
        let samples = CallTimes(calls: repeats)
        let completed = Atomic<Bool>(false)
        let frames = repeats
        // The initializer validated this duration and its tick conversion.
        let nanoseconds = UInt64(repeats) * 50_000_000 + 5_000_000_000
        let timebase = Clock.timebase
        let product = nanoseconds.multipliedFullWidth(by: UInt64(timebase.denom))
        let duration = UInt64(timebase.numer).dividingFullWidth(product).quotient
        _ = block.runOnThreads(recording: .samplesOnly) { _, _, _ in
            let (deadline, overflow) = Clock.now().addingReportingOverflow(duration)
            guard !overflow else { return }
            let finished = waitForMainThreadWork(until: deadline) { done in
                let loop = DisplayLinkLoop(frames: frames) { frame, _ in
                    samples.record(call: frame, ticks: Clock.now())
                }
                loop.start(finished: done)
            }
            completed.store(finished, ordering: .releasing)
        }
        let passed = completed.load(ordering: .acquiring)
        // A late loop keeps its buffer alive; only completion permits reading its writes.
        block.appendSamples(SamplesLine(
            block: block.position,
            thread: 0,
            metric: "displayFrame",
            unit: "ticks",
            values: passed ? samples.values : [],
            cpuAtStart: nil,
            cpuAtEnd: nil
        ))
        return [CheckResult(
            name: "calibration.samples",
            block: block.position,
            passed: passed,
            detail: "Display callbacks must produce \(frames) values before the deadline",
            violations: nil
        )]
    }

    /// Keep the read loop separate for optimized-code inspection. Darwin clock reads
    /// remain observable calls without a sink or data dependency on each iteration.
    @inline(never)
    private static func readClock1000() {
        for _ in 0..<1_000 {
            _ = Clock.now()
        }
    }
}

private struct CalibrationSample {
    var ticks: UInt64 = 0
    var cpuAtStart: Int = -1
    var cpuAtEnd: Int = -1
}

/// Each buffer has exactly one worker writer. The run thread reads only after join;
/// the captured buffer array keeps all allocations alive until workers finish.
private final class CalibrationSamples: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<CalibrationSample>
    private let capacity: Int
    private var count = 0

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: CalibrationSample(), count: capacity)
    }

    func append(_ sample: CalibrationSample) {
        precondition(count < capacity)
        storage[count] = sample
        count += 1
    }

    var samples: UnsafeBufferPointer<CalibrationSample> {
        UnsafeBufferPointer(start: storage, count: count)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }
}
