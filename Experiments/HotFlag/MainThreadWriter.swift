import Dispatch

/// Main-thread ownership covers the timer, write count and last value.
@MainActor
final class MainThreadWriter {
    struct State: Sendable {
        let writes: Int
        let last: Bool
    }

    private let flag: any SharedFlag
    private var timer: DispatchSourceTimer?
    private var writes = 0
    private var last = false

    nonisolated init(_ flag: some SharedFlag) {
        self.flag = flag
    }

    func start() {
        write()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.write() }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() -> State {
        timer?.cancel()
        timer = nil
        return State(writes: writes, last: last)
    }

    private func write() {
        last.toggle()
        flag.write(last)
        writes += 1
    }

    nonisolated static func deadline() -> UInt64 {
        let timebase = Clock.timebase
        let duration = 1_000_000_000 * UInt64(timebase.denom) / UInt64(timebase.numer)
        return Clock.now() + duration
    }
}
