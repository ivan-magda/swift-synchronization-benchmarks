/// The actor row: the protected value is the actor's own state.
/// Both sides return after submitting; the actor runs their work later.
final class ContendedActorLock: ContendedLock {
    private let state = ContendedActor()
    private let holderPriority: TaskPriority

    init(holderPriority: TaskPriority) {
        self.holderPriority = holderPriority
    }

    func hold(trial: Int, work: HolderWork, timestamps: HolderTimestamps) {
        let state = state
        Task.detached(priority: holderPriority) {
            await state.hold(trial: trial, work: work, timestamps: timestamps)
        }
    }

    @MainActor
    func touch(done: @escaping @Sendable (_ acquired: UInt64, _ observedTrial: Int) -> Void) {
        let state = state
        Task { @MainActor in
            let (acquired, observedTrial) = await state.touch()
            done(acquired, observedTrial)
        }
    }
}

/// Holds the trial index the holder last wrote; -1 means no holder has written yet.
actor ContendedActor {
    private var value = -1

    func hold(trial: Int, work: HolderWork, timestamps: HolderTimestamps) {
        timestamps.markAcquired()
        let resultCorrect = work.run()
        value = trial
        timestamps.markReleased(resultCorrect: resultCorrect)
    }

    /// The acquire tick is read when the actor runs this call.
    func touch() -> (acquired: UInt64, observedTrial: Int) {
        (Clock.now(), value)
    }
}
