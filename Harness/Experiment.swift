/// One mechanism and operation, executed by the declared number of workers.
struct BlockDescription: Equatable, Sendable {
    let mechanism: String
    let operation: String
    let threads: Int
    let qos: QoS
    let operationsPerBatch: Int
}

struct BatchLayout: Equatable, Sendable {
    let warmupBatches: Int
    let measuredBatches: Int
    let operationsPerBatch: Int
    let subBatches: Int

    var totalBatches: Int { warmupBatches + measuredBatches }
    var operationsPerSubBatch: Int { operationsPerBatch / subBatches }

    /// Reject unrepresentable storage and counts before allocating worker logs.
    func validate(threads: Int) throws(RequestError) {
        guard (1...64).contains(threads), warmupBatches >= 0, measuredBatches >= 1,
            subBatches >= 1, operationsPerBatch >= subBatches,
            operationsPerBatch % subBatches == 0
        else {
            throw RequestError(message: "invalid block batch layout")
        }
        let (batches, batchOverflow) = warmupBatches.addingReportingOverflow(measuredBatches)
        let (readings, readingOverflow) = subBatches.addingReportingOverflow(1)
        guard !batchOverflow, !readingOverflow else {
            throw RequestError(message: "batch layout count overflow")
        }
        let bytes = try ThreadLog.storageByteCount(batches: batches, readingsPerBatch: readings)
        let (_, storageOverflow) = bytes.multipliedReportingOverflow(by: threads)
        let (batchLines, lineOverflow) = batches.multipliedReportingOverflow(by: threads)
        let (_, operationOverflow) = batchLines.multipliedReportingOverflow(by: operationsPerBatch)
        guard !storageOverflow, !lineOverflow, !operationOverflow else {
            throw RequestError(message: "aggregate block size overflow")
        }
    }
}

protocol Experiment: Sendable {
    init(request: RunRequest) throws(RequestError)
    /// Fixed input order; the controller shuffles it with the request's seed.
    var blocks: [BlockDescription] { get }
    func run(_ block: BlockContext) -> [CheckResult]
}

enum ExperimentRegistry {
    static func makeExperiment(for request: RunRequest) throws(RequestError) -> any Experiment {
        if request.experiment == "baseComparison" {
            return try BaseComparison(request: request)
        }
        if request.experiment == "calibration" {
            return try Calibration(request: request)
        }
        throw RequestError(message: "unknown experiment: \(request.experiment)")
    }
}
