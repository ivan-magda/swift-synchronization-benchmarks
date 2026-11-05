import UIKit

/// The only screen. Shows the run status, which never changes during timed work.
@MainActor
final class RunViewController: UIViewController {
    private var decodedRequest = false
    private var pendingRequest: RunRequest?
    private var displayLink: CADisplayLink?
    private var launchReadiness = LaunchReadiness()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.text = "SyncBench idle"
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    /// The text the status label shows now.
    var currentStatus: String {
        statusLabel.text ?? ""
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor
            ),
            statusLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor
            )
        ])
    }

    func showStatus(_ text: String) {
        statusLabel.text = text
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard !decodedRequest else {
            return
        }
        decodedRequest = true

        do {
            pendingRequest = try RunRequest.decode(
                launchArguments: ProcessInfo.processInfo.arguments
            )
        } catch {
            showStatus(error.message)
            exit(2)
        }

        guard pendingRequest != nil else {
            return
        }

        for name in [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willResignActiveNotification,
            UIScene.didActivateNotification,
            UIScene.willDeactivateNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(activationChanged), name: name, object: nil
            )
        }

        let link = CADisplayLink(target: self, selector: #selector(frameDisplayed))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func activationChanged() {
        launchReadiness.activationChanged()
    }

    @objc private func frameDisplayed() {
        guard launchReadiness.frameDisplayed(
            applicationIsActive: UIApplication.shared.applicationState == .active,
            sceneIsActive: view.window?.windowScene?.activationState == .foregroundActive
        ) else {
            return
        }

        displayLink?.invalidate()
        displayLink = nil

        guard let request = pendingRequest else {
            return
        }
        pendingRequest = nil

        RunController.launch(request) { [weak self] status in
            MainActor.assumeIsolated {
                self?.showStatus(status)
            }
        }
    }
}
