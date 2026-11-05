import Darwin
import Synchronization

extension QoS {
    var qosClass: qos_class_t {
        switch self {
        case .userInteractive: QOS_CLASS_USER_INTERACTIVE
        case .userInitiated: QOS_CLASS_USER_INITIATED
        case .default: QOS_CLASS_DEFAULT
        case .utility: QOS_CLASS_UTILITY
        case .background: QOS_CLASS_BACKGROUND
        }
    }

    var taskPriority: TaskPriority {
        TaskPriority(rawValue: UInt8(qosClass.rawValue))
    }
}

/// Owns a pthread handle. The handle mutex serializes joins and detachment;
/// the independently retained entry owns the sendable body until it returns.
/// Dropping an unjoined handle detaches it, allowing fire-and-forget test bridges.
final class BenchmarkThread: @unchecked Sendable {
    /// The pointer is an opaque pthread identity, accessed only under the handle mutex.
    private struct Handle: @unchecked Sendable {
        var thread: pthread_t?
    }

    private final class Entry {
        let name: String
        let body: @Sendable () -> Void

        init(name: String, body: @escaping @Sendable () -> Void) {
            self.name = name
            self.body = body
        }
    }

    private let handle: Mutex<Handle>

    private init(handle: pthread_t) {
        self.handle = Mutex(Handle(thread: handle))
    }

    static func start(
        name: String,
        qos: QoS,
        body: @escaping @Sendable () -> Void
    ) -> BenchmarkThread {
        var attributes = pthread_attr_t()
        let initializeResult = pthread_attr_init(&attributes)
        precondition(initializeResult == 0)
        defer {
            let destroyResult = pthread_attr_destroy(&attributes)
            precondition(destroyResult == 0)
        }
        let qosResult = pthread_attr_set_qos_class_np(&attributes, qos.qosClass, 0)
        precondition(qosResult == 0)

        let entry = Unmanaged.passRetained(Entry(name: name, body: body))
        var thread: pthread_t?
        let result = pthread_create(&thread, &attributes, { pointer in
            let entry = Unmanaged<Entry>.fromOpaque(pointer).takeRetainedValue()
            let nameResult = pthread_setname_np(entry.name)
            precondition(nameResult == 0)
            entry.body()
            return nil
        }, entry.toOpaque())
        guard result == 0, let thread else {
            entry.release()
            preconditionFailure("Cannot create benchmark thread: \(result)")
        }
        return BenchmarkThread(handle: thread)
    }

    /// Call from a dedicated thread, never from the main thread or a task executor.
    func join() {
        handle.withLock { handle in
            guard let current = handle.thread else { return }
            precondition(pthread_equal(current, pthread_self()) == 0)
            let result = pthread_join(current, nil)
            precondition(result == 0)
            handle.thread = nil
        }
    }

    deinit {
        handle.withLock { handle in
            if let thread = handle.thread {
                let result = pthread_detach(thread)
                precondition(result == 0)
            }
        }
    }
}
