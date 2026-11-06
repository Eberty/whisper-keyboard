import UIKit

/// Keyboard-side state: talks to the app, interprets the mic gestures and types the results.
final class KeyboardModel: ObservableObject {
    /// A press held at least this long is push-to-talk; a shorter one toggles recording.
    private static let holdThreshold: TimeInterval = 0.4
    private static let pongTimeout: TimeInterval = 0.6
    /// Longer wait after a command: a busy app (transcribing on the CPU) can answer late without being gone.
    private static let busyPongTimeout: TimeInterval = 3
    private static let startURL = URL(string: "whisperkeyboard://start")!

    @Published private(set) var status: VoiceStatus = .off {
        // The screen must not lock on its own in the middle of a recording.
        didSet {
            if (status == .recording) != (oldValue == .recording) { controller?.keepScreenAwake(status == .recording) }
        }
    }
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasFullAccess = true
    @Published var showsGlobe = true

    private weak var controller: KeyboardViewController?
    private let channel = VoiceChannel()
    private let haptics = UIImpactFeedbackGenerator(style: .medium)
    private var lastResultID = 0
    private var awaitingResult = false
    /// A result that arrives while the keyboard is off screen waits for it to come back: typing it then would be lost.
    private var isVisible = false
    /// The start command of this keyboard's latest recording; the app tags its result with it.
    private var recordingID: UUID?
    /// A recording that ended while the keyboard was off screen, typed when it is back. Static because iOS creates a new
    /// controller then, in the same process; matched by recording, so a result from another app is never typed here.
    private static var awayRecordingID: UUID?
    private var pressBegan: Date?
    private var stopOnRelease = false
    private var pongTimeout: DispatchWorkItem?
    private var heartbeat: Timer?

    init(controller: KeyboardViewController) {
        self.controller = controller
        // Start from the app's last known state (a stale recording shows as ready), so the first frame does not flash off.
        switch VoiceChannel.readState()?.status {
        case .recording?, .transcribing?: status = .ready
        case let known?: status = known
        case nil: status = .off
        }
        channel.observe(.pong) { [weak self] in self?.handlePong() }
        channel.observe(.stateChanged) { [weak self] in self?.applySharedState() }
    }

    var hint: String {
        if !hasFullAccess { return String(localized: "Turn on Full Access in Settings") }
        switch status {
        case .off: return String(localized: "Tap the mic to turn it on")
        case .loading: return String(localized: "Loading model...")
        case .ready: return String(localized: "Hold to talk, or tap to start and stop")
        case .recording: return String(localized: "Listening...")
        case .transcribing: return String(localized: "Transcribing...")
        case .unavailable: return errorMessage ?? String(localized: "Open the app")
        }
    }

    func refresh() {
        isVisible = true
        hasFullAccess = controller?.hasFullAccess ?? false
        let state = VoiceChannel.readState()
        lastResultID = state?.resultID ?? lastResultID
        awaitingResult = false
        guard hasFullAccess else { return }
        // A recording this keyboard did not start (an earlier instance was killed) must not be kept; one it finished
        // as it went away may still be stopping.
        if state?.status == .recording && Self.awayRecordingID == nil { channel.send(.cancel) }
        pingApp()
    }

    func micPressed() {
        guard hasFullAccess else { return }
        switch status {
        case .ready:
            pressBegan = Date()
            stopOnRelease = false
            awaitingResult = false
            Self.awayRecordingID = nil
            status = .recording
            haptics.impactOccurred()
            recordingID = channel.send(.start)
            pingApp(timeout: Self.busyPongTimeout)
            startHeartbeat()
        case .recording:
            stopOnRelease = true
        case .off, .unavailable, .loading:
            // While the model loads, the app shows how it is going; tapping opens it, as when it is off.
            channel.send(.wake)
            controller?.openContainerApp(Self.startURL)
        case .transcribing:
            // If the app died while busy, the ping times out and the keyboard shows it as off instead of spinning.
            pingApp(timeout: Self.busyPongTimeout)
        }
    }

    func micReleased() {
        defer { pressBegan = nil }
        guard status == .recording else { return }
        let held = pressBegan.map { Date().timeIntervalSince($0) >= Self.holdThreshold } ?? false
        if stopOnRelease || held { stopRecording() }
    }

    /// While recording, a regular ping tells the app this keyboard is still alive; if it dies, the app discards the audio.
    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = .onCommonModes(after: VoiceChannel.heartbeatInterval, repeats: true) { [weak self] timer in
            guard let self, self.status == .recording else { return timer.invalidate() }
            self.channel.send(.ping)
        }
    }

    /// The X that replaces delete while recording: stops without transcribing.
    func cancelRecording() {
        guard status == .recording else { return }
        haptics.impactOccurred()
        cancelIfRecording()
    }

    /// When the keyboard goes away mid-recording (the phone locks, another keyboard is chosen), what was said is
    /// transcribed; that result, or one still being transcribed, is typed if the keyboard comes back in time, and kept
    /// in History either way.
    func disappear() {
        isVisible = false
        heartbeat?.invalidate()
        if status == .recording {
            stopOnRelease = false
            status = .transcribing
            channel.send(.stop)
            Self.awayRecordingID = recordingID
        } else if awaitingResult {
            Self.awayRecordingID = recordingID
        }
        awaitingResult = false
    }

    func cancelIfRecording() {
        heartbeat?.invalidate()
        guard status == .recording else { return }
        status = .ready
        channel.send(.cancel)
    }

    /// Types a key's text as is, such as a punctuation mark, a space or a line break.
    func insertText(_ text: String) { controller?.textDocumentProxy.insertText(text) }
    func deleteBackward() { controller?.textDocumentProxy.deleteBackward() }

    /// Deletes the previous word and the spaces after it, like holding delete on Apple's keyboard.
    func deleteWordBackward() {
        guard let proxy = controller?.textDocumentProxy, let before = proxy.documentContextBeforeInput,
              !before.isEmpty else { return deleteBackward() }
        let trailingSpaces = before.reversed().prefix { $0.isWhitespace }.count
        let word = before.dropLast(trailingSpaces).reversed().prefix { !$0.isWhitespace }.count
        for _ in 0..<max(1, trailingSpaces + word) { proxy.deleteBackward() }
    }

    private func stopRecording() {
        stopOnRelease = false
        awaitingResult = true
        status = .transcribing
        haptics.impactOccurred()
        channel.send(.stop)
        pingApp(timeout: Self.busyPongTimeout)
    }

    /// Asks the app for a sign of life; without one the keyboard shows the app as off instead of waiting forever.
    /// A late answer only shows the app as off; a result still on its way is kept and typed when it arrives.
    private func pingApp(timeout seconds: TimeInterval = pongTimeout) {
        pongTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.status = .off }
        pongTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timeout)
        channel.send(.ping)
    }

    private func handlePong() {
        pongTimeout?.cancel()
        pongTimeout = nil
        applySharedState()
    }

    private func applySharedState() {
        guard let state = VoiceChannel.readState() else { return }
        // The app may stop a long recording on its own; this keyboard still wants that result.
        if status == .recording && state.status == .transcribing { awaitingResult = true }
        status = state.status
        errorMessage = state.errorMessage
        if let away = Self.awayRecordingID, isVisible, state.recordingID == away {
            Self.awayRecordingID = nil
            lastResultID = max(lastResultID, state.resultID)
            return insert(state.resultText)
        }
        guard state.resultID > lastResultID else { return }
        lastResultID = state.resultID
        if awaitingResult {
            awaitingResult = false
            // Only this keyboard's own recording: one the app was still transcribing for another app is never typed here.
            if state.recordingID == recordingID { insert(state.resultText) }
        }
    }

    private func insert(_ text: String) {
        guard let proxy = controller?.textDocumentProxy, !text.isEmpty else { return }
        proxy.insertText(TextSpacing.padded(text, before: proxy.documentContextBeforeInput,
                                            after: proxy.documentContextAfterInput))
    }
}

extension Timer {
    /// On the common run loop modes, so it keeps firing while a finger is still on the screen.
    static func onCommonModes(after interval: TimeInterval, repeats: Bool,
                              block: @escaping (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
