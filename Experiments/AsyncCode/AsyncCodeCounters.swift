import Foundation
import os
import Synchronization

// Experiment 7 writes each mechanism as ordinary app code: a counter type that owns its
// lock or isolation. The increment matches experiment 1's (`&+= 1`).

actor CounterActor {
    private var value = 0

    func increment() {
        value &+= 1
    }

    /// For path "onActor": an async method of the same actor, awaited from inside it.
    func incrementAsync() async {
        value &+= 1
    }

    /// Path "onActor": runs the batch loop on this actor; one operation is `await incrementAsync()`.
    func runBatchesOnActor(layout: BatchLayout, barrier: TaskBarrier, log: ThreadLog) async {
        await BatchTimer.timeBatchesOnCallerIsolation(
            layout: layout,
            barrier: barrier,
            log: log,
            isolation: self,
            recordExecutorCPU: { _ in },
            runOperations: { _, _, count in
                for _ in 0..<count {
                    await self.incrementAsync()
                }
                return 0
            }
        )
    }

    func executorCPU() -> Int {
        CPU.current()
    }

    func finalValue() -> Int {
        value
    }
}

@MainActor
final class MainActorCounter {
    private var value = 0

    func increment() {
        value &+= 1
    }

    func executorCPU() -> Int {
        CPU.current()
    }

    func finalValue() -> Int {
        value
    }
}

/// The three lock counters, so each caller path is written once for all of them.
/// Generic callers are specialized, so every call is a direct call.
protocol LockCounter: Sendable {
    func increment()
    func finalValue() -> Int
}

final class MutexCounter: LockCounter {
    private let value = Mutex(0)

    func increment() {
        value.withLock { $0 &+= 1 }
    }

    func finalValue() -> Int {
        value.withLock { $0 }
    }
}

final class AllocatedUnfairLockCounter: LockCounter {
    private let value = OSAllocatedUnfairLock(initialState: 0)

    func increment() {
        value.withLock { $0 &+= 1 }
    }

    func finalValue() -> Int {
        value.withLock { $0 }
    }
}

/// The lock guards every access to `value`.
final class NSLockCounter: LockCounter, @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }

    func finalValue() -> Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return value
    }
}

// Experiment 7B state: 128 counters; operation k increments counter k % 128. With a single
// `Int` the compiler would fold a group of increments into one addition.

actor CounterGroupActor {
    private var counters = [Int](repeating: 0, count: 128)

    /// `AsyncCode.groupSize` operations in one call.
    func incrementGroup(startingAt operation: Int) {
        for index in operation..<(operation + AsyncCode.groupSize) {
            counters[index % 128] &+= 1
        }
    }

    func incrementOne(at operation: Int) {
        counters[operation % 128] &+= 1
    }

    func executorCPU() -> Int {
        CPU.current()
    }

    func total() -> Int {
        counters.reduce(0, &+)
    }
}

final class MutexCounterGroup: Sendable {
    private let counters = Mutex([Int](repeating: 0, count: 128))

    /// `AsyncCode.groupSize` operations under one `withLock`.
    func incrementGroup(startingAt operation: Int) {
        counters.withLock { counters in
            for index in operation..<(operation + AsyncCode.groupSize) {
                counters[index % 128] &+= 1
            }
        }
    }

    func total() -> Int {
        counters.withLock { $0.reduce(0, &+) }
    }
}
