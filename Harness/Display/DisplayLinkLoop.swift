import UIKit

/// Delivers a finite sequence of display callbacks on the main thread.
/// The display link retains the loop until completion or an explicit stop.
@MainActor final class DisplayLinkLoop: NSObject {
    private let frames: Int
    private let onFrame: @MainActor (Int, CADisplayLink) -> Void
    private var link: CADisplayLink?
    private var finished: (@Sendable () -> Void)?
    private var frame = 0
    private var started = false

    init(frames: Int, onFrame: @escaping @MainActor (_ frame: Int, _ link: CADisplayLink) -> Void) {
        precondition(frames >= 0)
        self.frames = frames
        self.onFrame = onFrame
    }

    func start(finished: @escaping @Sendable () -> Void) {
        precondition(!started, "A display loop starts once")
        started = true
        self.finished = finished
        guard frames > 0 else {
            stop()
            return
        }

        let screen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?.screen
        let maximum = Float(screen?.maximumFramesPerSecond ?? 60)
        let link = CADisplayLink(target: self, selector: #selector(onDisplayLink(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: maximum, maximum: maximum, preferred: maximum
        )
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    /// Invalidation and completion are idempotent, including when called inside onFrame.
    func stop() {
        link?.invalidate()
        link = nil
        let completion = finished
        finished = nil
        completion?()
    }

    @objc private func onDisplayLink(_ link: CADisplayLink) {
        guard frame < frames, self.link != nil else { return }
        let current = frame
        frame += 1
        onFrame(current, link)
        if frame == frames {
            stop()
        }
    }
}
