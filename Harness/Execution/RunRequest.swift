import Foundation

enum QoS: String, Codable, Sendable, CaseIterable {
    case userInteractive
    case userInitiated
    case `default`
    case utility
    case background
}

/// Smoke runs only: intentionally fail to exercise the Mac runner's recovery.
enum Simulation: String, Codable, Sendable {
    /// `fatalError` after the first block.
    case crash

    /// Sleep forever on the run thread after the first block, leaving main free.
    case hang
}

struct Tunables: Codable, Equatable, Sendable {
    var threads: Int
    var qos: QoS
    var warmupBatches: Int
    var measuredBatches: Int

    /// CPU readings divide each batch into this many sub-batches.
    var subBatches: Int

    /// The "default" entry covers mechanisms without their own entry.
    var operationsPerBatch: [String: Int]
    var referenceLoopIterations: Int

    /// Calibration only: samples per measurement.
    var repeats: Int?
    var asyncCode: AsyncCodeTunables?
    var priorityInversion: PriorityInversionTunables?
}

/// Tunables of experiment 7, path "fromManyTasks".
struct AsyncCodeTunables: Codable, Equatable, Sendable {
    /// Timed calls per task.
    var callsPerTask: Int

    /// Untimed calls per task before the timed ones.
    var warmupCallsPerTask: Int
}

/// Tunables of experiment 8B.
struct PriorityInversionTunables: Codable, Equatable, Sendable {
    /// `referenceLoop` iterations the holder runs under the lock.
    var holderWorkIterations: Int
    var loadQoS: QoS
    var loadMilliseconds: Int
    var mainDelayMicroseconds: Int
    var pauseMilliseconds: Int
    var warmupTrials: Int
    var trials: Int
}

struct RunRequest: Codable, Equatable, Sendable {
    var schema: Int
    var runID: String
    var attemptID: String
    var attempt: Int
    var experiment: String
    var variant: String
    var seed: UInt64
    var smoke: Bool
    var simulation: Simulation?
    var mechanisms: [String]
    var operations: [String]
    var tunables: Tunables

    /// True only in traced plans; omitted otherwise.
    var traced: Bool?

    /// Decode separately from validation so an invalid attempt can be reported.
    /// No `--bench-request` means an idle app launch.
    static func decode(launchArguments: [String]) throws(RequestError) -> RunRequest? {
        guard let index = launchArguments.firstIndex(of: "--bench-request") else {
            return nil
        }

        guard launchArguments.indices.contains(index + 1) else {
            throw RequestError(message: "--bench-request requires a base64 JSON argument")
        }

        guard let data = Data(base64Encoded: launchArguments[index + 1]) else {
            throw RequestError(message: "--bench-request is not valid base64")
        }

        do {
            return try JSONDecoder().decode(RunRequest.self, from: data)
        } catch {
            throw RequestError(message: "--bench-request is not a valid RunRequest: \(error)")
        }
    }

    func validate() throws(RequestError) {
        guard schema == 1 else {
            throw RequestError(message: "schema must be 1")
        }

        guard Self.isValidIdentifier(runID) else {
            throw RequestError(message: "runID must match [A-Za-z0-9._-]{1,128}")
        }

        guard Self.isValidIdentifier(attemptID) else {
            throw RequestError(message: "attemptID must match [A-Za-z0-9._-]{1,128}")
        }

        guard attempt >= 1 else {
            throw RequestError(message: "attempt must be at least 1")
        }

        guard seed < (1 << 53) else {
            throw RequestError(message: "seed must be below 2^53")
        }

        guard (1...64).contains(tunables.threads) else {
            throw RequestError(message: "threads must be in 1...64")
        }

        guard tunables.warmupBatches >= 0 else {
            throw RequestError(message: "warmupBatches must be at least 0")
        }

        guard tunables.measuredBatches >= 1 else {
            throw RequestError(message: "measuredBatches must be at least 1")
        }

        guard tunables.subBatches >= 1 else {
            throw RequestError(message: "subBatches must be at least 1")
        }

        guard tunables.operationsPerBatch["default"] != nil else {
            throw RequestError(message: "operationsPerBatch requires a default entry")
        }

        for (mechanism, operations) in tunables.operationsPerBatch {
            guard operations >= tunables.subBatches,
                operations % tunables.subBatches == 0
            else {
                throw RequestError(
                    message:
                        "operationsPerBatch[\(mechanism)] must be a multiple of subBatches and at least subBatches"
                )
            }
        }

        guard tunables.referenceLoopIterations >= 1 else {
            throw RequestError(message: "referenceLoopIterations must be at least 1")
        }

        for operations in tunables.operationsPerBatch.values {
            try BatchLayout(
                warmupBatches: tunables.warmupBatches,
                measuredBatches: tunables.measuredBatches,
                operationsPerBatch: operations,
                subBatches: tunables.subBatches
            ).validate(threads: tunables.threads)
        }

        if let asyncCode = tunables.asyncCode {
            try Self.require(asyncCode.callsPerTask, atLeast: 1, "asyncCode.callsPerTask")
            try Self.require(asyncCode.warmupCallsPerTask, atLeast: 0, "asyncCode.warmupCallsPerTask")
        }

        if let priorityInversion = tunables.priorityInversion {
            try Self.require(
                priorityInversion.holderWorkIterations,
                atLeast: 1,
                "priorityInversion.holderWorkIterations"
            )
            try Self.require(priorityInversion.loadMilliseconds, atLeast: 1, "priorityInversion.loadMilliseconds")
            try Self.require(
                priorityInversion.mainDelayMicroseconds,
                atLeast: 0,
                "priorityInversion.mainDelayMicroseconds"
            )
            try Self.require(priorityInversion.pauseMilliseconds, atLeast: 0, "priorityInversion.pauseMilliseconds")
            try Self.require(priorityInversion.warmupTrials, atLeast: 0, "priorityInversion.warmupTrials")
            try Self.require(priorityInversion.trials, atLeast: 1, "priorityInversion.trials")

            let (_, overflow) = priorityInversion.warmupTrials.addingReportingOverflow(priorityInversion.trials)
            guard !overflow else {
                throw RequestError(message: "priorityInversion.warmupTrials + priorityInversion.trials overflows")
            }
        }

        guard simulation == nil || smoke else {
            throw RequestError(message: "simulation requires smoke")
        }
    }

    private static func require(_ value: Int, atLeast minimum: Int, _ field: String) throws(RequestError) {
        guard value >= minimum else {
            throw RequestError(message: "\(field) must be at least \(minimum)")
        }
    }

    func operationsPerBatch(for mechanism: String) -> Int {
        // Only validated requests reach experiment execution.
        tunables.operationsPerBatch[mechanism] ?? tunables.operationsPerBatch["default"]!
    }

    /// ASCII only; also used by the writer before accepting a file stem.
    static func isValidIdentifier(_ value: String) -> Bool {
        let bytes = value.utf8
        return (1...128).contains(bytes.count)
            && bytes.allSatisfy {
                (65...90).contains($0)
                    || (97...122).contains($0)
                    || (48...57).contains($0)
                    || $0 == 46
                    || $0 == 95
                    || $0 == 45
            }
    }
}

struct RequestError: Error, Equatable, Sendable {
    let message: String
}
