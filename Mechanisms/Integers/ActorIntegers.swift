actor ActorInteger: AsyncSharedInteger {
    private var value: Int

    init(_ initialValue: Int) {
        value = initialValue
    }

    func read() -> Int {
        value
    }

    func write(_ value: Int) {
        self.value = value
    }

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

@MainActor
final class MainActorInteger: AsyncSharedInteger {
    private var value: Int

    init(_ initialValue: Int) {
        value = initialValue
    }

    func read() -> Int {
        value
    }

    func write(_ value: Int) {
        self.value = value
    }

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
