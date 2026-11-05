import Darwin

struct ContextSwitches: Equatable, Sendable {
    /// Process voluntary switches from `getrusage`.
    var voluntary: Int

    /// Process involuntary switches from `getrusage`.
    var involuntary: Int

    /// Task context switches from `task_info(TASK_EVENTS_INFO)`.
    var task: Int

    static func now() -> ContextSwitches {
        var usage = rusage()
        let usageResult = getrusage(RUSAGE_SELF, &usage)
        precondition(usageResult == 0)

        var events = task_events_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_events_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let taskResult = withUnsafeMutablePointer(to: &events) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { information in
                task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), information, &count)
            }
        }
        precondition(taskResult == KERN_SUCCESS)

        return ContextSwitches(
            voluntary: usage.ru_nvcsw,
            involuntary: usage.ru_nivcsw,
            task: Int(events.csw)
        )
    }

    static func - (later: ContextSwitches, earlier: ContextSwitches) -> ContextSwitches {
        ContextSwitches(
            voluntary: later.voluntary - earlier.voluntary,
            involuntary: later.involuntary - earlier.involuntary,
            task: later.task - earlier.task
        )
    }
}
