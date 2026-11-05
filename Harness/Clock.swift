import Darwin

enum Clock {
    /// `mach_absolute_time()` returns ticks, not nanoseconds.
    @inline(__always)
    static func now() -> UInt64 {
        mach_absolute_time()
    }

    static let timebase: mach_timebase_info_data_t = {
        var information = mach_timebase_info_data_t()
        let result = mach_timebase_info(&information)
        precondition(result == KERN_SUCCESS)
        return information
    }()
}

enum CPU {
    /// The CPU at this instant only; -1 means the query failed.
    @inline(__always)
    static func current() -> Int {
        var number = -1
        let result = pthread_cpu_number_np(&number)
        return result == 0 ? Int(number) : -1
    }
}
