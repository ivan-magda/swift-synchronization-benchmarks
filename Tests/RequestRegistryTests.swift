import Foundation
import Testing

@testable import SyncBench

@Suite struct RequestRegistryTests {
    // Missing rows, warm-up samples or lost removals break the exported contract.
    @Test(.timeLimit(.minutes(1)), arguments: ["normal", "burst"])
    func requestRegistrySmokeRunPasses(_ variant: String) async throws {
        let attempt = try await runAttempt(.requestRegistrySmoke(variant: variant))
        #expect(attempt.status == "completed")
        #expect(attempt.blocks.count == 10)
        #expect(attempt.checks.count == 10)
        #expect(attempt.checks.allSatisfy { $0["passed"] as? Bool == true })
        #expect(Set(attempt.checks.compactMap { $0["name"] as? String }) == ["requestRegistry.addAndRemove"])
        for block in attempt.blocks {
            let position = try #require(block["block"] as? Int)
            let samples = attempt.lines(type: "samples", block: position)
            #expect(samples.count == 10)
            for metric in ["callStart", "callTime"] {
                let calls = samples.filter { $0["metric"] as? String == metric }
                #expect(calls.count == 4)
                #expect(Set(calls.compactMap { $0["thread"] as? Int }) == [0, 1, 2, 3])
                #expect(calls.allSatisfy { ($0["values"] as? [Int])?.count == 32 })
            }
            for metric in ["cancelAllStart", "cancelAllTime"] {
                let line = try #require(samples.first { $0["metric"] as? String == metric })
                #expect(line["thread"] == nil)
                #expect((line["values"] as? [Int])?.count == 8)
            }
            #expect(samples.allSatisfy { $0["unit"] as? String == "ticks" })
        }
    }

    // A no-op cancelAll can satisfy accounting alone; verify its real effects.
    @Test func registriesCancelAndClearReusedDownloads() {
        let registries: [any DownloadRegistry] = [
            MutexRegistry(capacity: 2), AllocatedUnfairLockRegistry(capacity: 2),
            AdaptiveSpinUnfairLockRegistry(capacity: 2), UnfairLockRegistry(capacity: 2),
            NSLockRegistry(capacity: 2), NSRecursiveLockRegistry(capacity: 2),
            PthreadMutexRegistry(capacity: 2), SerialQueueRegistry(capacity: 2),
            DispatchSemaphoreRegistry(capacity: 2), ObjcSyncRegistry(capacity: 2),
        ]
        for registry in registries {
            let first = Download(id: 1, workIterations: 10)
            let second = Download(id: 2, workIterations: 10)
            registry.add(first, id: 1)
            registry.add(second, id: 2)
            #expect(registry.cancelAll() == 2)
            #expect(first.cancelCount.load(ordering: .relaxed) == 1)
            #expect(second.cancelCount.load(ordering: .relaxed) == 1)
            #expect(registry.remove(id: 1) == nil)
            #expect(registry.remove(id: 2) == nil)
            registry.add(first, id: 1)
            #expect(registry.cancelAll() == 1)
            #expect(first.cancelCount.load(ordering: .relaxed) == 2)
            #expect(second.cancelCount.load(ordering: .relaxed) == 1)
            #expect(registry.cancelAll() == 0)
        }
    }

    @Test(arguments: [
        ("missing", "requestRegistry"), ("variant", "variant"),
        ("normalPause", "requestRegistry.pauseMicroseconds"),
        ("burstPause", "requestRegistry.pauseMicroseconds"), ("threads", "threads"),
        ("cancelInterval", "requestRegistry.cancelAllEvery"), ("capacity", "requestRegistry.inFlightPerThread"),
    ])
    func registryRejectsInvalidWorkload(_ mutation: String, _ field: String) throws {
        var request = try RunRequest.requestRegistrySmoke()
        switch mutation {
        case "missing": request.tunables.requestRegistry = nil
        case "variant": request.variant = "default"
        case "normalPause": request.variant = "normal"
        case "burstPause": request.tunables.requestRegistry!.pauseMicroseconds = 1
        case "threads": request.tunables.threads = 1
        case "cancelInterval": request.tunables.requestRegistry!.cancelAllEvery = 300
        case "capacity": request.tunables.requestRegistry!.inFlightPerThread = Int.max
        default: preconditionFailure("Test mutation")
        }
        let error = #expect(throws: RequestError.self) { try ExperimentRegistry.makeExperiment(for: request) }
        #expect(error?.message.contains(field) == true)
    }

    // Partial windows and odd windows cannot produce balanced add/remove samples.
    @Test(arguments: [100, 1, 3])
    func requestRegistryRejectsUndividedSamples(_ sampleEvery: Int) throws {
        let request = try RunRequest.requestRegistrySmoke(sampleEvery: sampleEvery)
        let error = #expect(throws: RequestError.self) {
            try ExperimentRegistry.makeExperiment(for: request)
        }
        #expect(error?.message.contains("requestRegistry.sampleEvery") == true)
    }
}

extension RunRequest {
    static func requestRegistrySmoke(variant: String = "burst", sampleEvery: Int = 64) throws -> RunRequest {
        var request = RunRequest.golden
        request.experiment = "requestRegistry"
        request.variant = variant
        request.mechanisms = [
            "mutex", "osAllocatedUnfairLock", "osAllocatedUnfairLockAdaptiveSpin",
            "osUnfairLock", "nsLock", "nsRecursiveLock", "pthreadMutex",
            "serialQueue", "dispatchSemaphore", "objcSync",
        ]
        request.operations = ["addAndRemove"]
        request.tunables.threads = 4
        request.tunables.operationsPerBatch = ["default": 1_024]
        request.tunables.requestRegistry = RequestRegistryTunables(
            inFlightPerThread: 16, workIterations: 10,
            pauseMicroseconds: variant == "normal" ? 1 : 0,
            cancelAllEvery: 256, sampleEvery: sampleEvery
        )
        return request
    }
}
