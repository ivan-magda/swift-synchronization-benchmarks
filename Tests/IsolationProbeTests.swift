import IsolationProbeSwift6
import IsolationProbeTemplate
import Testing

/// Serialized: the probe's counters are shared by every test that calls it.
@Suite(.serialized)
struct IsolationProbeTests {
    @MainActor
    @Test func templateSettingsKeepNonisolatedAsyncOnTheMainThread() async {
        IsolationProbeTemplate.IsolationProbe.reset()
        for _ in 0..<10 {
            await IsolationProbeTemplate.IsolationProbe.nonisolatedWork()
        }
        #expect(IsolationProbeTemplate.IsolationProbe.counts() == (calls: 10, onMainThread: 10))
    }

    @MainActor
    @Test func swift6SettingsMoveNonisolatedAsyncOffTheMainThread() async {
        IsolationProbeSwift6.IsolationProbe.reset()
        for _ in 0..<10 {
            await IsolationProbeSwift6.IsolationProbe.nonisolatedWork()
        }
        #expect(IsolationProbeSwift6.IsolationProbe.counts() == (calls: 10, onMainThread: 0))
    }

    @MainActor
    @Test func concurrentAttributeMovesTheCallOffTheMainThread() async {
        IsolationProbeTemplate.IsolationProbe.reset()
        for _ in 0..<10 {
            await IsolationProbeTemplate.IsolationProbe.concurrentWork()
        }
        #expect(IsolationProbeTemplate.IsolationProbe.counts() == (calls: 10, onMainThread: 0))
    }
}
