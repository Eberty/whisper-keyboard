import SwiftUI
import UIKit

struct ContentView: View {
    private static let setupID = "setup"

    @EnvironmentObject private var session: VoiceSession
    @State private var testText = ""
    @State private var historyUnlocked = false
    @Environment(\.scenePhase) private var scenePhase
    /// Set after the first launch has scrolled to Setup, so it only happens once.
    @AppStorage("hasShownSetup") private var hasShownSetup = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section {
                    HeaderView()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section {
                    StatusRow(status: session.state.status, downloading: session.models.isDownloading)
                    if let error = session.state.errorMessage, !session.models.isDownloading {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    if session.state.status == .off {
                        Button("Turn on microphone", systemImage: "mic.fill") { session.startMicrophone() }
                    } else {
                        Button(role: .destructive) {
                            session.stopMicrophone()
                        } label: {
                            Label("Turn off microphone", systemImage: "mic.slash")
                        }
                        .foregroundStyle(.red)
                    }
                    if session.microphoneDenied {
                        Button("Open Settings", systemImage: "gear", action: openSettings)
                    }
                }

                Section {
                    TextField("Tap here and switch to Whisper Keyboard", text: $testText, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Label("Try it here", systemImage: "keyboard")
                }

                Section {
                    NavigationLink {
                        LockedHistoryView(history: session.history, onClear: session.clearHistory,
                                          isUnlocked: $historyUnlocked)
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                }

                SettingsSection(settings: session.settings, vocabularyFits: session.vocabularyFits)

                ModelSection(models: session.models, loadingID: session.loadingModelID,
                             onDownload: session.downloadModel, onCancel: session.cancelDownload,
                             onRetry: session.retryPendingModel, onUse: session.useDownloadedModel,
                             onKeep: session.keepCurrentModel, onCheck: session.checkForUpdates,
                             installedFailed: session.installedLoadFailed,
                             onRetryInstalled: session.retryInstalledModel)

                Section {
                    StepRow(number: 1, text: "Open Settings, Apps, Whisper, Keyboards.")
                    StepRow(number: 2, text: "Turn on Whisper Keyboard and Allow Full Access.")
                    StepRow(number: 3, text: "In any text field, tap the globe and choose Whisper Keyboard.")
                    StepRow(number: 4, text: "Keep this app open, even in the background.")
                    Button("Open Settings", systemImage: "arrow.up.forward.app", action: openSettings)
                } header: {
                    Label("Setup", systemImage: "list.number")
                }
                .id(Self.setupID)

                Section {
                    InfoRow("Developer", systemImage: "person.crop.circle", value: AppInfo.developer)
                    NavigationLink {
                        LicenseView()
                    } label: {
                        InfoRow("License", systemImage: "doc.text", value: AppInfo.license)
                    }
                    InfoRow("Version", systemImage: "number", value: AppInfo.version)
                    if AppInfo.showsRepositoryLink {
                        Link(destination: AppInfo.repositoryURL) {
                            Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                    }
                } header: {
                    Label("About", systemImage: "info.circle")
                } footer: {
                    Label("Everything stays on this device. Audio is never saved; text is kept only in History, if you want.", systemImage: "lock.fill")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { historyUnlocked = false }
            }
            .background(TapOutsideDismissesKeyboard())
            .toolbar(.hidden, for: .navigationBar)
            // With the navigation bar hidden, content scrolled up would run into the clock; a blurred band behind the
            // status bar keeps it readable, like the system's own bars.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear
                    .frame(height: 0)
                    .background(.bar)
            }
            .task {
                // On the first launch, bring the activation steps into view.
                guard !hasShownSetup else { return }
                try? await Task.sleep(for: .milliseconds(400))
                withAnimation { proxy.scrollTo(Self.setupID, anchor: .top) }
                hasShownSetup = true
            }
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

enum AppInfo {
    static let developer = "Eberty Alves"
    static let license = "MIT"
    static let repositoryURL = URL(string: "https://github.com/Eberty/whisper-keyboard")!
    /// Shows the source code link in About; hidden for now.
    static let showsRepositoryLink = false
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

private struct HeaderView: View {
    var body: some View {
        HStack(spacing: 16) {
            Image("Logo")
                .resizable()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Whisper Keyboard")
                    .font(.title2.bold())
                // Two lines at most; it shrinks a little if a language needs more room.
                Text("Speak your way. Whisper writes with punctuation, without sending anything to the internet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct StatusRow: View {
    let status: VoiceStatus
    let downloading: Bool

    private var showsDownload: Bool { downloading && status == .unavailable }

    var body: some View {
        // A Label puts the icon in the same column as the other rows' icons, so icons and text line up.
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if status == .loading {
                    Text("The first time can take a few minutes")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: icon)
                .font(.footnote.weight(.bold))
                .circleBadge(color, size: 28)
        }
        .padding(.vertical, 2)
    }

    private var title: LocalizedStringKey {
        if showsDownload { return "Downloading model" }
        switch status {
        case .off: return "Microphone off"
        case .loading: return "Loading model"
        case .ready: return "Ready"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .unavailable: return "Unavailable"
        }
    }

    private var icon: String {
        if showsDownload { return "arrow.down" }
        switch status {
        case .off: return "mic.slash.fill"
        case .loading: return "hourglass"
        case .ready: return "checkmark"
        case .recording: return "waveform"
        case .transcribing: return "text.bubble.fill"
        case .unavailable: return "exclamationmark"
        }
    }

    private var color: Color {
        if showsDownload { return .orange }
        switch status {
        case .off: return .gray
        case .loading, .transcribing: return .orange
        case .ready: return .green
        case .recording, .unavailable: return .red
        }
    }
}

/// A row with a fixed value on the right, such as the version.
private struct InfoRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let value: String

    init(_ title: LocalizedStringKey, systemImage: String, value: String) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
    }

    var body: some View {
        LabeledContent {
            Text(verbatim: value)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

private struct StepRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Text(verbatim: "\(number)")
                .font(.footnote.bold())
                .circleBadge(.accentColor, size: 22)
        }
    }
}

private struct ModelSection: View {
    @ObservedObject var models: ModelManager
    /// The model loading now, if any; its row shows an hourglass and ignores taps.
    let loadingID: String?
    let onDownload: (String) -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onUse: (String) -> Void
    let onKeep: () -> Void
    let onCheck: () -> Void
    /// The model in use failed to load; its alert offers to try again instead of only OK.
    let installedFailed: Bool
    let onRetryInstalled: () -> Void
    @State private var pending: ModelManager.Option?
    /// The alert only says what the model is good for: it is loading, or a download or the update check runs.
    @State private var infoOnly = false

    private var isBusy: Bool { loadingID != nil || models.isDownloading || models.isChecking }
    /// Another model can be picked while one loads; only a download or the update check locks the list.
    private var isLocked: Bool { models.isDownloading || models.isChecking }

    /// The model a row stands for and, when there is one, its newer version.
    private func ids(of option: ModelManager.Option) -> [String] {
        [option.id, models.updates[option.tier]].compactMap { $0 }
    }

    private func isLoading(_ option: ModelManager.Option) -> Bool {
        loadingID.map(ids(of: option).contains) ?? false
    }

    private func downloadProgress(for option: ModelManager.Option) -> Double? {
        guard case let .downloading(id, progress) = models.phase, ids(of: option).contains(id) else { return nil }
        return progress
    }

    var body: some View {
        Section {
            ForEach(models.options) { option in
                Button {
                    let inUse = models.installedID == option.id && models.updates[option.tier] == nil
                    // The model in use, picked while another loads, stays, and that load is dropped.
                    if inUse, loadingID != nil, !isLoading(option) { return onKeep() }
                    // While it loads, or a download or the update check runs, a row only says what its model is good for.
                    infoOnly = isLoading(option) || isLocked
                    // Every other choice asks first, showing what the model is good for.
                    pending = models.updates[option.tier].map { option.with(id: $0) } ?? option
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: option.systemImage)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: option.title))
                                .foregroundStyle(.primary)
                            Text(verbatim: option.size)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        trailing(for: option)
                    }
                }
                // Looks locked but stays tappable, so it can always say what the model is good for.
                .opacity(isDimmed(option) ? 0.4 : 1)
            }
            if (models.pendingID != nil || models.failedID != nil) && !isBusy {
                ErrorNote("Could not load the model", systemImage: "exclamationmark.triangle.fill")
            }
            if models.phase == .failed {
                ErrorNote("Could not download the model. Check the internet and try again.", systemImage: "wifi.exclamationmark")
            }
            if models.checkFailed {
                ErrorNote("Could not check for updates. Check the internet and try again.", systemImage: "wifi.exclamationmark")
            }
        } header: {
            HStack {
                Label("Model", systemImage: "cpu")
                Spacer()
                // Asks the model repository for newer versions; the only network use besides downloading a model.
                Button(action: onCheck) {
                    if models.isChecking {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isBusy || models.isChecking)
                .accessibilityLabel(Text("Check for updates"))
            }
        }
        // An alert, so the confirmation always shows in the middle of the screen.
        .alert(Text(String(localized: pending?.title ?? "")),
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { option in
            if infoOnly || (option.id == models.installedID && !installedFailed) {
                Button("OK") {}
            } else {
                if option.id == models.installedID {
                    Button("Try again") { onRetryInstalled() }
                } else if option.id == models.pendingID {
                    Button("Use") { onRetry() }
                } else if option.id == models.previousID {
                    Button("Use") { onUse(option.id) }
                } else {
                    Button("Download \(option.size)") { onDownload(option.id) }
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: { option in
            if !infoOnly && models.updates.values.contains(option.id) && option.id != models.pendingID {
                Text("Downloads the newest version of this model.")
            } else {
                Text(String(localized: option.summary))
            }
        }
    }

    /// While the list is checked every row is locked; while a model downloads, all but that one and the one in use.
    private func isDimmed(_ option: ModelManager.Option) -> Bool {
        models.isChecking || (models.isDownloading && models.installedID != option.id && !isDownloading(option))
    }

    private func isDownloading(_ option: ModelManager.Option) -> Bool {
        downloadProgress(for: option) != nil
    }

    @ViewBuilder
    private func trailing(for option: ModelManager.Option) -> some View {
        if let progress = downloadProgress(for: option) {
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 60)
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Cancel download"))
            }
        } else if isLoading(option) {
            // The hourglass marks the model loading (a ProgressView vanishes in list rows).
            Image(systemName: "hourglass")
                .foregroundStyle(.orange)
                .symbolEffect(.pulse)
                .accessibilityLabel(Text("Loading model"))
        } else if let update = models.updates[option.tier], models.pendingID == update {
            accentIcon("arrow.clockwise.circle", label: "Try again")
        } else if models.updates[option.tier] != nil {
            accentIcon("arrow.up.circle.fill", label: "Update available")
        } else if models.installedID == option.id {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if models.pendingID == option.id {
            accentIcon("arrow.clockwise.circle", label: "Try again")
        } else if models.previousID == option.id {
            accentIcon("arrow.uturn.backward.circle", label: "Switch back")
        } else {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(Color.accentColor)
        }
    }
}

private extension ModelSection {
    func accentIcon(_ systemName: String, label: LocalizedStringKey) -> some View {
        Image(systemName: systemName)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel(Text(label))
    }
}

/// A short red note under a list, for something that failed.
private struct ErrorNote: View {
    let text: LocalizedStringKey
    let systemImage: String

    init(_ text: LocalizedStringKey, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(.red)
    }
}

private struct SettingsSection: View {
    @ObservedObject var settings: AppSettings
    let vocabularyFits: ([String]) -> Bool

    var body: some View {
        Section {
            Picker(selection: $settings.language) {
                Text("Automatic").tag("auto")
                Text(verbatim: "Português").tag("pt")
                Text(verbatim: "English").tag("en")
                Text(verbatim: "Español").tag("es")
            } label: {
                Label("Input language", systemImage: "globe")
            }
            NavigationLink {
                VocabularyView(settings: settings, fits: vocabularyFits)
            } label: {
                LabeledContent {
                    if !settings.vocabulary.isEmpty {
                        Text(settings.vocabulary.count, format: .number)
                    }
                } label: {
                    Label("Vocabulary", systemImage: "character.book.closed")
                }
            }
            Picker(selection: $settings.idleSeconds) {
                ForEach(AppSettings.idleChoices, id: \.self) { seconds in
                    if seconds == 0 {
                        Text("Never").tag(seconds)
                    } else if seconds < 60 {
                        Text("\(seconds) s").tag(seconds)
                    } else {
                        Text("\(seconds / 60) min").tag(seconds)
                    }
                }
            } label: {
                Label("Turn off mic after", systemImage: "timer")
            }
            Toggle(isOn: $settings.keepsHistory) {
                Label("Keep history", systemImage: "clock.arrow.circlepath")
            }
        } header: {
            Label("Options", systemImage: "slider.horizontal.3")
        }
    }
}

/// Closes the keyboard on a tap outside a text field, without taking the tap from buttons and rows.
private struct TapOutsideDismissesKeyboard: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { InstallerView() }
    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class InstallerView: UIView, UIGestureRecognizerDelegate {
        private lazy var recognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }

        @objc private func tapped() {
            window?.endEditing(true)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextView || current is UITextField { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

private extension View {
    /// White content on a colored circle, like the status icon and the step numbers.
    func circleBadge(_ color: Color, size: CGFloat) -> some View {
        foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: Circle())
    }
}
