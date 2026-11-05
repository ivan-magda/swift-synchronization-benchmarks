import Foundation

struct RunLine: Encodable {
    let type = "run"
    let schema: Int
    let request: RunRequest
    let build: BuildInfo
    let phone: PhoneFacts
    let conditions: Conditions
}

struct PhoneFacts: Encodable {
    let machine: String
    let osVersion: String
    let osBuild: String
    let cpuCount: Int
    let activeCPUCount: Int
    let performanceLevels: [PerformanceLevel]
    let cacheLineBytes: Int
    let memoryBytes: UInt64
    let timebaseNumerator: UInt32
    let timebaseDenominator: UInt32
    let mainThreadQoSClass: UInt32
    let mutexDefaultPolicy: String?
    let ulockAdaptiveSpinMicroseconds: Int?
}

struct PerformanceLevel: Encodable {
    let index: Int
    let name: String
    let logicalCPUCount: Int
    let physicalCPUCount: Int
    let l1DataCacheBytes: Int
    let l2CacheBytes: Int
    let cpusPerL2: Int
}

struct Conditions: Encodable, Sendable {
    let thermalState: String
    let lowPowerMode: Bool
    let batteryState: String
    let batteryLevelPermille: Int
    let screenBrightnessPermille: Int
    let debuggerAttached: Bool
    let applicationState: String
    let environment: [String: String]
    let ticks: UInt64
    /// ISO 8601 UTC, with seconds and no fractional part.
    let wallClock: String
}

struct ReferenceLine: Encodable {
    let type = "reference"
    let when: String
    let iterations: Int
    let start: UInt64
    let end: UInt64
    let cpuReadings: [Int]
}

struct BlockLine: Encodable {
    let type = "block"
    let block: Int
    let mechanism: String
    let operation: String
    let threads: Int
    let qos: QoS
    let operationsPerBatch: Int
    let start: UInt64
    let end: UInt64
    let voluntaryContextSwitches: Int
    let involuntaryContextSwitches: Int
    let taskContextSwitches: Int
    let thermalStateAtStart: String
    let thermalStateAtEnd: String
}

struct BatchLine: Encodable {
    let type = "batch"
    let block: Int
    let batch: Int
    let thread: Int
    let warmup: Bool
    let operations: Int
    let start: UInt64
    let end: UInt64
    let cpuReadings: [Int]
    let executorCPUReadings: [Int]?
}

struct SamplesLine: Encodable {
    let type = "samples"
    let block: Int?
    let thread: Int?
    let metric: String
    let unit: String
    let values: [UInt64]
    let cpuAtStart: [Int]?
    let cpuAtEnd: [Int]?
}

struct EndLine: Encodable {
    let type = "end"
    let status: String
    let reasonCode: String?
    let reason: String?
    let checks: [CheckResult]
    let blockLines: Int
    let warmupBatchLines: Int
    let measuredBatchLines: Int
    let conditions: Conditions
    let thermalChanges: [ThermalChange]
}

struct CheckResult: Encodable {
    let name: String
    let block: Int?
    let passed: Bool
    let detail: String
    let violations: Int?
}

struct ThermalChange: Encodable, Sendable {
    let ticks: UInt64
    let thermalState: String
}
