import Darwin

enum CreationCostChecks {
    struct MemorySample: Sendable {
        let before: (blocks: UInt64, bytes: UInt64)
        let afterCreate: (blocks: UInt64, bytes: UInt64)
        let afterDestroy: (blocks: UInt64, bytes: UInt64)
        let heapBlocks: Int
        let liveBefore: UInt64?
        let liveAfterDestroy: UInt64?
    }

    /// Inspect every retained class outside timing; cache-level statistics cannot
    /// prove one new reported block per malloc-backed object.
    static func heapBlockCount<Object: AnyObject>(_ objects: ContiguousArray<Object>) -> Int {
        var blocks = 0
        for object in objects {
            if malloc_size(Unmanaged.passUnretained(object).toOpaque()) > 0 {
                blocks += 1
            }
        }
        return blocks
    }

    static func check(
        operation: String, block: Int, objects: Int, batches: Int,
        destroyed: Int, samples: [MemorySample], completed: Bool
    ) -> CheckResult {
        let allowance = UInt64(objects / 100)
        let expectedDestroyed = objects * batches
        var passed = completed && destroyed == expectedDestroyed
        var detail = "destroyed \(destroyed)/\(expectedDestroyed); completed \(completed)"
        var minimum: UInt64?
        var growth: UInt64 = 0
        for sample in samples {
            let before = sample.before.blocks
            let created = sample.afterCreate.blocks
            let afterDestroy = sample.afterDestroy.blocks
            let allObjectsUseHeap = sample.heapBlocks == objects
            detail += "; heap blocks \(sample.heapBlocks)/\(objects); blocks \(before), \(created), \(afterDestroy)"
            guard let liveBefore = sample.liveBefore, let liveAfterDestroy = sample.liveAfterDestroy else {
                passed = false
                detail += "; live enumeration failed"
                continue
            }
            let returnedToBaseline = liveAfterDestroy <= liveBefore || liveAfterDestroy - liveBefore <= allowance
            passed = passed && allObjectsUseHeap && returnedToBaseline
            detail +=
                "; live blocks \(liveBefore), \(liveAfterDestroy); growth \(Int64(liveAfterDestroy) - Int64(liveBefore))"
            let earlierMinimum = minimum ?? liveAfterDestroy
            if liveAfterDestroy >= earlierMinimum {
                growth = max(growth, liveAfterDestroy - earlierMinimum)
            }
            minimum = min(earlierMinimum, liveAfterDestroy)
        }
        passed = passed && growth <= allowance
        detail += "; post-destroy growth \(growth), allowance \(allowance)"
        return CheckResult(
            name: "creationCost.\(operation)", block: block, passed: passed, detail: detail, violations: nil)
    }
}
