import Dispatch

// Ordinary application counters for the Release disassembly comparison.
// No harness protocols, generic state callbacks, or exclusivity overrides.
public final class ReferenceSerialCounter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "reference.serial")
    private var value: Int

    public init(_ value: Int) { self.value = value }
    public func read() -> Int { queue.sync { value } }
    public func write(_ newValue: Int) { queue.sync { value = newValue } }
    public func increment() { queue.sync { value &+= 1 } }
}

public final class ReferenceSyncBarrierCounter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "reference.concurrent", attributes: .concurrent)
    private var value: Int

    public init(_ value: Int) { self.value = value }
    public func read() -> Int { queue.sync { value } }
    public func write(_ newValue: Int) { queue.sync(flags: .barrier) { value = newValue } }
    public func increment() { queue.sync(flags: .barrier) { value &+= 1 } }
}

public final class ReferenceAsyncBarrierCounter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "reference.concurrent", attributes: .concurrent)
    private var value: Int

    public init(_ value: Int) { self.value = value }
    public func read() -> Int { queue.sync { value } }
    public func write(_ newValue: Int) { queue.async(flags: .barrier) { self.value = newValue } }
    public func increment() { queue.async(flags: .barrier) { self.value &+= 1 } }
    public func waitForPendingWrites() { queue.sync(flags: .barrier) {} }
}
