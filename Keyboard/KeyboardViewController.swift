import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private lazy var model = KeyboardModel(controller: self)
    /// Created early but activated only after `viewWillAppear`, in `updateViewConstraints`, just below required:
    /// activating it earlier makes iOS show the keyboard at a wrong, taller height for a moment while switching.
    private var heightConstraint: NSLayoutConstraint?
    private var willAppearCalled = false

    /// The height of Apple's keyboard including its suggestion bar, so this keyboard is never taller than Apple's.
    private static func standardHeight(for traits: UITraitCollection) -> CGFloat {
        if traits.userInterfaceIdiom == .pad { return 264 }
        return traits.verticalSizeClass == .compact ? 162 : 243
    }

    /// A plain root, not a UIInputView: iOS draws the keyboard's translucent background itself.
    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: KeyboardView(model: model, controller: self))
        // The SwiftUI content must never push the keyboard's height.
        host.sizingOptions = []
        host.view.setContentCompressionResistancePriority(.fittingSizeLevel, for: .vertical)
        host.view.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let height = view.heightAnchor.constraint(equalToConstant: Self.standardHeight(for: traitCollection))
        height.priority = UILayoutPriority(UILayoutPriority.required.rawValue - 1)
        heightConstraint = height
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        willAppearCalled = true
        view.setNeedsUpdateConstraints()
        model.refresh()
    }

    override func updateViewConstraints() {
        super.updateViewConstraints()
        guard willAppearCalled, let heightConstraint else { return }
        heightConstraint.constant = Self.standardHeight(for: traitCollection)
        if !heightConstraint.isActive { heightConstraint.isActive = true }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Locking the phone or switching keyboards mid-recording keeps what was said: it is transcribed, and typed if
        // this keyboard comes back.
        model.disappear()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if model.showsGlobe != needsInputModeSwitchKey { model.showsGlobe = needsInputModeSwitchKey }
        heightConstraint?.constant = Self.standardHeight(for: traitCollection)
    }

    /// The host app's own setting while a recording keeps the screen awake, restored afterwards.
    private var hostKeptScreenAwake: Bool?

    /// The app hosting the keyboard, found through the responder chain, since extensions cannot call UIApplication.shared.
    private var hostApplication: UIApplication? {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication { return application }
            responder = current.next
        }
        return nil
    }

    /// Keeps the screen from locking on its own while recording.
    func keepScreenAwake(_ awake: Bool) {
        guard let application = hostApplication else { return }
        if awake {
            hostKeptScreenAwake = application.value(forKey: "idleTimerDisabled") as? Bool
            application.setValue(true, forKey: "idleTimerDisabled")
        } else if let previous = hostKeptScreenAwake {
            // Restores what the host app had, so a video player keeps its screen on.
            application.setValue(previous, forKey: "idleTimerDisabled")
            hostKeptScreenAwake = nil
        }
    }

    /// Opens the container app.
    func openContainerApp(_ url: URL) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        guard let application = hostApplication, application.responds(to: selector) else { return }
        typealias OpenURL = @convention(c) (UIApplication, Selector, NSURL, NSDictionary, UnsafeRawPointer?) -> Void
        let open = unsafeBitCast(application.method(for: selector), to: OpenURL.self)
        open(application, selector, url as NSURL, NSDictionary(), nil)
    }
}
