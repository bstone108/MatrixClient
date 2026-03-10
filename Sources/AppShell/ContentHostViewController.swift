import AppKit
import MediaKit
import TimelineUI

final class ContentHostViewController: NSViewController {
    private let state: WorkspaceStateController
    private let videoPlaybackEngine: any VideoPlaybackEngine
    private lazy var timelineViewController = TimelineViewController(state: state, videoPlaybackEngine: videoPlaybackEngine)
    private lazy var securitySettingsViewController = SecuritySettingsViewController(state: state)
    private var currentViewController: NSViewController?

    init(state: WorkspaceStateController, videoPlaybackEngine: any VideoPlaybackEngine) {
        self.state = state
        self.videoPlaybackEngine = videoPlaybackEngine
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        state.addSelectionObserver { [weak self] in
            self?.updateContent()
        }
        updateContent()
    }

    private func updateContent() {
        let nextViewController: NSViewController
        switch state.selectedSettingsDestination {
        case .securityVerification:
            nextViewController = securitySettingsViewController
        case .none:
            nextViewController = timelineViewController
        }

        guard currentViewController !== nextViewController else { return }

        if let currentViewController {
            currentViewController.view.removeFromSuperview()
            currentViewController.removeFromParent()
        }

        addChild(nextViewController)
        let childView = nextViewController.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(childView)
        NSLayoutConstraint.activate([
            childView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            childView.topAnchor.constraint(equalTo: view.topAnchor),
            childView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        currentViewController = nextViewController
    }
}
