/// Delays the one-shot request until both lifecycles are active for two display callbacks.
struct LaunchReadiness {
    private var displayedFrames = 0
    private var launched = false

    mutating func activationChanged() {
        displayedFrames = 0
    }

    mutating func frameDisplayed(applicationIsActive: Bool, sceneIsActive: Bool) -> Bool {
        guard !launched else {
            return false
        }
        guard applicationIsActive, sceneIsActive else {
            displayedFrames = 0
            return false
        }
        displayedFrames += 1
        guard displayedFrames == 2 else {
            return false
        }
        launched = true
        return true
    }
}
