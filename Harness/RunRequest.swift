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

    /// Decode separately from validation so an invalid attempt can be reported.
    /// No `--bench-request` means an idle app launch.
    static func decode(launchArguments: [String]) throws(RequestError) -> RunRequest? {
        guard let index = launchArguments.firstIndex(of: "--bench-request") else { return nil }
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
        guard schema == 1 else { throw RequestError(message: "schema must be 1") }
        guard Self.isValidIdentifier(runID) else {
            throw RequestError(message: "runID must match [A-Za-z0-9._-]{1,128}")
        }
        guard Self.isValidIdentifier(attemptID) else {
            throw RequestError(message: "attemptID must match [A-Za-z0-9._-]{1,128}")
        }
        guard attempt >= 1 else { throw RequestError(message: "attempt must be at least 1") }
        guard seed < (1 << 53) else { throw RequestError(message: "seed must be below 2^53") }
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
            guard operations >= tunables.subBatches, operations % tunables.subBatches == 0 else {
                throw RequestError(
                    message:
                        "operationsPerBatch[\(mechanism)] must be a multiple of subBatches and at least subBatches"
                )
            }
        }
        guard tunables.referenceLoopIterations >= 1 else {
            throw RequestError(message: "referenceLoopIterations must be at least 1")
        }
        guard simulation == nil || smoke else {
            throw RequestError(message: "simulation requires smoke")
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
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || $0 == 46 || $0 == 95 || $0 == 45
            }
    }
}

struct RequestError: Error, Equatable, Sendable {
    let message: String
}
