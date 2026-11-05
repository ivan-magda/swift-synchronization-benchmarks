import Darwin
import Synchronization

/// Reusable pthread barrier. The mutex protects every access to arrivals and generation.
/// Use between timed batches, and keep the barrier alive until every party has left.
final class ThreadBarrier: @unchecked Sendable {
    private let parties: Int
    private var mutex = pthread_mutex_t()
    private var condition = pthread_cond_t()
    private var arrivals = 0
    private var generation: UInt64 = 0

    init(parties: Int) {
        precondition(parties > 0)
        self.parties = parties

        let mutexResult = pthread_mutex_init(&mutex, nil)
        precondition(mutexResult == 0)

        let conditionResult = pthread_cond_init(&condition, nil)
        precondition(conditionResult == 0)
    }

    func arriveAndWait() {
        let lockResult = pthread_mutex_lock(&mutex)
        precondition(lockResult == 0)

        let arrivedGeneration = generation
        arrivals += 1

        if arrivals == parties {
            arrivals = 0
            generation &+= 1

            let broadcastResult = pthread_cond_broadcast(&condition)
            precondition(broadcastResult == 0)
        } else {
            while generation == arrivedGeneration {
                let waitResult = pthread_cond_wait(&condition, &mutex)
                precondition(waitResult == 0)
            }
        }

        let unlockResult = pthread_mutex_unlock(&mutex)
        precondition(unlockResult == 0)
    }

    deinit {
        let conditionResult = pthread_cond_destroy(&condition)
        precondition(conditionResult == 0)

        let mutexResult = pthread_mutex_destroy(&mutex)
        precondition(mutexResult == 0)
    }
}

/// Suspends tasks until every party arrives. All parties must participate in every round,
/// including after cancellation. Continuation storage is used only between timed batches.
final class TaskBarrier: Sendable {
    private let parties: Int
    private let waiters = Mutex<[CheckedContinuation<Void, Never>]>([])

    init(parties: Int) {
        precondition(parties > 0)
        self.parties = parties
    }

    func arriveAndWait() async {
        await withCheckedContinuation { continuation in
            let ready = waiters.withLock { waiters -> [CheckedContinuation<Void, Never>] in
                waiters.append(continuation)

                guard waiters.count == parties else {
                    return []
                }

                let ready = waiters
                waiters = []

                return ready
            }

            for waiter in ready {
                waiter.resume()
            }
        }
    }
}
