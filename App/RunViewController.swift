import UIKit

/// The only screen. Shows the run status, which never changes during timed work.
@MainActor
final class RunViewController: UIViewController {
    private let statusLabel: UILabel = {
        let label = UILabel()
        label.text = "SyncBench idle"
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    /// The text the status label shows now.
    var currentStatus: String { statusLabel.text ?? "" }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor)
        ])
    }

    func showStatus(_ text: String) {
        statusLabel.text = text
    }
}
