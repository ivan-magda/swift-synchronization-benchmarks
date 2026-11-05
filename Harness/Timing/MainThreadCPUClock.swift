import Darwin

/// CPU time of the main thread, readable from any thread.
struct MainThreadCPUClock: Sendable {
    /// The main thread lives as long as the process, so its port name stays valid.
    private let mainThread: thread_act_t

    /// Keeps the main thread's Mach port. Must run on the main thread: the iOS SDK has
    /// no `pthread_main_thread_np`.
    @MainActor
    init() {
        precondition(pthread_main_np() != 0)
        mainThread = pthread_mach_thread_np(pthread_self())
    }

    /// User plus system time of the main thread, in microseconds.
    func microseconds() -> UInt64 {
        var information = thread_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { information in
                thread_info(mainThread, thread_flavor_t(THREAD_BASIC_INFO), information, &count)
            }
        }
        precondition(result == KERN_SUCCESS)

        return Self.microseconds(information.user_time) + Self.microseconds(information.system_time)
    }

    private static func microseconds(_ time: time_value_t) -> UInt64 {
        UInt64(time.seconds) * 1_000_000 + UInt64(time.microseconds)
    }
}
