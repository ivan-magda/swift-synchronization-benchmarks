import Darwin
import Dispatch
import Synchronization

/// Called on the run thread. Completion publishes the main thread's writes;
/// a timeout gives no permission to read state that main-thread work still owns.
/// `beforeWait` runs after submission setup, letting allocation-sensitive work wait
/// until the caller has finished creating and releasing its submission buffers.
func waitForMainThreadWork(
    until deadline: UInt64,
    beforeWait: () -> Void = {},
    _ start: @escaping @MainActor (_ done: @escaping @Sendable () -> Void) -> Void
) -> Bool {
    precondition(pthread_main_np() == 0)
    let completedAt = Mutex<UInt64?>(nil)
    let completion = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            start {
                completedAt.withLock { tick in
                    if tick == nil { tick = Clock.now() }
                }
                completion.signal()
            }
        }
    }

    let now = Clock.now()
    if now < deadline {
        let timebase = Clock.timebase
        let product = (deadline - now).multipliedFullWidth(by: UInt64(timebase.numer))
        let nanoseconds = product.high < UInt64(timebase.denom)
            ? UInt64(timebase.denom).dividingFullWidth(product).quotient : UInt64.max
        let timeout = DispatchTime.now() + .nanoseconds(Int(clamping: nanoseconds))
        beforeWait()
        _ = completion.wait(timeout: timeout)
    } else {
        beforeWait()
    }
    return completedAt.withLock { tick in tick.map { $0 <= deadline } ?? false }
}
