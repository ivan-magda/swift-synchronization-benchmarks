import Foundation
import Synchronization
import Testing

@testable import SyncBench

@Suite struct TransactionalStoreTests {
    // Missing drains, skipped groups, warm-up samples or a missing row break this contract.
    @Test(.timeLimit(.minutes(1)))
    func transactionalStoreSmokeRunPasses() async throws {
        let attempt = try await runAttempt(.transactionalStoreSmoke)
        #expect(attempt.status == "completed")
        #expect(attempt.blocks.count == 26)
        #expect(attempt.checks.count == 26)
        #expect(attempt.checks.allSatisfy { $0["passed"] as? Bool == true })
        for block in attempt.blocks {
            let position = try #require(block["block"] as? Int)
            let single = block["operation"] as? String == "singleRecord"
            #expect(block["threads"] as? Int == 6)
            let samples = attempt.lines(type: "samples", block: position)
            #expect(samples.count == 12)
            for thread in 0..<6 {
                let own = samples.filter { $0["thread"] as? Int == thread }
                #expect(own.count == 2)
                let writes = try #require(own.first { $0["metric"] as? String == "writeTime" })
                let reads = try #require(own.first {
                    $0["metric"] as? String == (single ? "hundredReadsTime" : "readTime")
                })
                #expect((writes["values"] as? [UInt64])?.count == 200)
                #expect((reads["values"] as? [UInt64])?.count == (single ? 98 : 9_800))
                #expect(writes["unit"] as? String == "ticks")
                #expect((writes["values"] as? [UInt64])?.allSatisfy { $0 > 0 } == true)
            }
        }
    }

    // A probabilistic write decision or splitting read runs changes exact counts.
    @Test(arguments: [1, 100])
    func operationListHasTwoPercentWrites(readsPerRun: Int) {
        let list = OperationList.make(seed: 7, thread: 2, batches: 2,
            transactionsPerBatch: 5_000, readsPerRun: readsPerRun, groups: 500)
        #expect(list == OperationList.make(seed: 7, thread: 2, batches: 2,
            transactionsPerBatch: 5_000, readsPerRun: readsPerRun, groups: 500))
        #expect(list != OperationList.make(seed: 8, thread: 2, batches: 2,
            transactionsPerBatch: 5_000, readsPerRun: readsPerRun, groups: 500))
        for batch in 0..<2 {
            let runs = list.runs[(batch * list.runsPerBatch)..<((batch + 1) * list.runsPerBatch)]
            #expect(runs.reduce(0) { $0 + $1.reads.count } == 4_900)
            #expect(runs.reduce(0) { $0 + $1.writes.count } == 100)
            #expect(runs.allSatisfy { $0.reads.count == readsPerRun })
            #expect(runs.last?.writes.isEmpty == true)
        }
        #expect(list.groups.allSatisfy { (0..<500).contains($0) })
    }

    // The real read scanner and block check must reject a writer that updates only half.
    @Test func aTornReadIsCounted() async throws {
        var request = RunRequest.transactionalStoreSmoke
        request.mechanisms = ["mutex"]
        request.operations = ["twentyRecords"]
        let configured = request
        let checks = await onBenchmarkThread {
            let experiment = try! TransactionalStore(request: configured)
            let description = experiment.blocks[0]
            let block = BlockContext(position: 0, description: description,
                layout: try! configured.validatedLayout(operationsPerBatch: 5_000, threads: 6),
                request: configured, lines: ResultLineBuffer())
            return experiment.measure(HalfWrittenStore(), block)
        }
        let check = try #require(checks.first)
        #expect(!check.passed)
        #expect((check.violations ?? 0) > 0)
    }

    @Test func transactionalStoreRejectsIncompleteWriteRatio() throws {
        var request = RunRequest.transactionalStoreSmoke
        request.tunables.subBatches = 1
        request.tunables.operationsPerBatch = ["default": 4_999]
        do {
            _ = try ExperimentRegistry.makeExperiment(for: request)
            Issue.record("Accepted transactions that cannot form whole read runs and 2% writes")
        } catch {
            #expect(error.message.contains("operationsPerBatch"))
        }
    }
}

/// The mutex keeps test scheduling race-free; only the intentionally partial update is wrong.
private final class HalfWrittenStore: RecordStore {
    private let records = Mutex(Array(repeating: Record(version: 0, value: 0), count: 10_000))

    func readGroup(_ group: Int) -> GroupRead {
        records.withLock { $0.readGroup(group, size: 20) }
    }

    func writeGroup(_ group: Int, endTimes: CallTimes, slot: Int) {
        records.withLock { records in
            for index in (group * 20)..<(group * 20 + 10) {
                records[index].version += 1
                records[index].value = records[index].version
            }
            endTimes.record(call: slot, ticks: Clock.now())
        }
    }
}

extension RunRequest {
    static var transactionalStoreSmoke: RunRequest {
        var request = RunRequest.hotFlagSmoke
        request.experiment = "transactionalStore"
        request.mechanisms.removeAll { ["atomic", "atomicRelaxed", "managedAtomic", "managedAtomicRelaxed"].contains($0) }
        request.operations = ["singleRecord", "twentyRecords"]
        request.tunables.threads = 6
        request.tunables.subBatches = 8
        request.tunables.operationsPerBatch = ["default": 5_000]
        return request
    }
}
