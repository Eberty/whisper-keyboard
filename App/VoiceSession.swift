import AVFoundation
import Combine
import Foundation
import Network
import UIKit

/// Owns the microphone and the model, and answers the keyboard's commands.
final class VoiceSession: ObservableObject {
    /// A recording longer than this is stopped and transcribed, so a forgotten mic does not keep buffering.
    private static let maxRecordingSeconds: TimeInterval = 10 * 60
    /// How long the last result stays in the shared container for the keyboard to pick up.
    private static let resultLifetime: TimeInterval = 10
    /// How long the keyboard's wake request stays valid while iOS opens the app.
    private static let wakeLifetime: TimeInterval = 10

    @Published private(set) var state = VoiceState()
    @Published private(set) var microphoneDenied = false
    /// The model being loaded, if any; the current one stays usable meanwhile.
    @Published private(set) var loadingModelID: String?
    /// The model in use failed to load and nothing else works, so its row offers to try again.
    @Published private(set) var installedLoadFailed = false
    /// Increases with each load; a load whose number is no longer the latest was replaced, and its result is dropped.
    private var loadGeneration = 0
    /// Core ML loads one model at a time (memory, and so its prepared copies belong to one model); a load asked for
    /// meanwhile waits here, and only the latest one asked for is kept.
    private var isCoreMLLoading = false
    private var waitingLoad: (folder: URL, id: String?)?
    var isLoadingModel: Bool { loadingModelID != nil }
    let history = TranscriptHistory()
    let settings = AppSettings()
    let models = ModelManager()
    /// Tells Wi-Fi from cellular and Low Data Mode, so a newer version of the model in use downloads on its own only then.
    private let network = NWPathMonitor()

    private let channel = VoiceChannel()
    private let recorder = AudioRecorder()
    private var transcriber: WhisperTranscriber?

    /// Whether the vocabulary still fits in what Whisper reads; the Vocabulary screen stops adding words when it does not.
    func vocabularyFits(_ words: [String]) -> Bool {
        transcriber?.vocabularyFits(words) ?? WhisperTranscriber.estimatedFit(words)
    }
    /// Shown instead of the model message while set, since the mic is needed first.
    private var microphoneError: String?
    private var modelMessage: String?
    private var isRecording = false
    private var isTranscribing = false
    private var lastCommandID: UUID?
    /// The keyboard command that started the current recording; its result carries it.
    private var recordingID: UUID?
    private var lastWakeID: UUID?
    private var idleTimer: DispatchWorkItem?
    private var recordingLimit: DispatchWorkItem?
    private var lastPing = Date.distantPast
    private var keyboardWatch: Timer?
    private var subscriptions = Set<AnyCancellable>()

    init() {
        network.start(queue: .main)
        state.resultID = VoiceChannel.readState()?.resultID ?? 0
        // When the app is closed, the keyboard shows the microphone off at once instead of after its ping times out.
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            guard let self else { return }
            self.state.status = .off
            self.state.resultText = ""
            self.broadcast()
        }
        recorder.onRunningChanged = { [weak self] in self?.handleRecorderChange() }
        // A call or another app stopping the recording keeps what was said so far.
        recorder.onInterrupted = { [weak self] in self?.finishRecording() }
        channel.observe(.command) { [weak self] in self?.handleCommand() }
        channel.observe(.ping) { [weak self] in
            self?.lastPing = Date()
            self?.channel.send(.pong)
        }
        settings.$idleSeconds.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.scheduleIdleStop() }
        }.store(in: &subscriptions)
        settings.$keepsHistory.dropFirst().sink { [weak self] keeps in
            if !keeps { self?.clearHistory() }
        }.store(in: &subscriptions)
        models.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        publish()
        // Unit tests run inside the app; they must not download a model or ask for the microphone.
        guard !Self.isTesting else { return }
        WhisperTranscriber.clearStaleDeviceCache()
        loadModel()
        // The mic turns on when the app becomes active, unless a link from elsewhere opened it.
    }

    private static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    // MARK: - Microphone

    func startMicrophone() {
        guard !Self.isTesting else { return }
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                self.microphoneDenied = !granted
                guard granted else {
                    self.microphoneError = String(localized: "Allow microphone access in Settings")
                    self.publish()
                    return
                }
                do {
                    if !self.recorder.isRunning { try self.recorder.start() }
                    self.microphoneError = nil
                } catch {
                    self.microphoneError = Self.microphoneMessage(for: error)
                }
                self.scheduleIdleStop()
                self.publish()
            }
        }
    }

    /// The system's audio errors come only in English, so the user sees one of these instead.
    static func microphoneMessage(for error: Error) -> String {
        if let recorderError = error as? AudioRecorder.RecorderError { return recorderError.localizedDescription }
        let busy: [AVAudioSession.ErrorCode] = [.insufficientPriority, .cannotInterruptOthers, .isBusy]
        if let code = AVAudioSession.ErrorCode(rawValue: (error as NSError).code), busy.contains(code) {
            return String(localized: "Microphone in use")
        }
        return String(localized: "Session activation failed")
    }

    func stopMicrophone() {
        isRecording = false
        recordingLimit?.cancel()
        idleTimer?.cancel()
        recorder.stop()
        // The app may be suspended right after this, so the last result is cleared now instead of on its timer.
        state.resultText = ""
        publish()
    }

    /// Restarts the idle countdown, so only time in the background counts.
    func didEnterBackground() {
        scheduleIdleStop()
    }

    /// Handles whisperkeyboard://start; returns true when the keyboard asked for it, so the app shows how to go back.
    func handleWakeURL() -> Bool {
        guard let command = VoiceChannel.readCommand(), command.action == .wake, command.id != lastWakeID,
              abs(command.date.timeIntervalSinceNow) < Self.wakeLifetime else { return false }
        lastWakeID = command.id
        startMicrophone()
        return true
    }

    /// Turns the mic off after the chosen time without use; the next use goes through the app again.
    private func scheduleIdleStop() {
        idleTimer?.cancel()
        guard settings.idleSeconds > 0, recorder.isRunning else { return }
        let stop = DispatchWorkItem { [weak self] in
            guard let self, !self.isRecording, !self.isTranscribing else { return }
            // Only time spent in the background counts; with the app on screen the mic stays on. While a model
            // downloads or loads it also stays on: the running mic keeps the app awake, and without it iOS would
            // suspend the app and stop the download.
            guard UIApplication.shared.applicationState == .background, !self.models.isDownloading,
                  !self.isLoadingModel else {
                self.scheduleIdleStop()
                return
            }
            self.stopMicrophone()
        }
        idleTimer = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(settings.idleSeconds), execute: stop)
    }

    // MARK: - Model

    /// Loads a downloaded model that has not loaded yet, else the installed one, else downloads the default.
    private func loadModel() {
        if let pending = models.pendingID {
            load(folder: models.folder(for: pending), replacing: pending)
        } else if let folder = models.installedFolder {
            load(folder: folder)
        } else {
            downloadModel(models.defaultID)
        }
    }

    /// Looks for newer models. A newer version of the model in use downloads right away on Wi-Fi; on cellular or in Low
    /// Data Mode it waits for the user, like any other update.
    func checkForUpdates() {
        models.checkForUpdates { [weak self] in
            guard let self, let installed = self.models.installedID, let tier = ModelManager.tier(of: installed),
                  let update = self.models.updates[tier], update != self.models.pendingID, !self.models.isDownloading
            else { return }
            let path = self.network.currentPath
            guard path.status == .satisfied, !path.isExpensive, !path.isConstrained else { return }
            self.downloadModel(update)
        }
    }

    /// Downloads another model; it replaces the current one only after it loads.
    /// Another model can be downloaded while one loads; when it is ready it replaces that load (see `load`).
    func downloadModel(_ id: String) {
        showIfNoModel(String(localized: "Downloading model..."))
        models.download(id) { [weak self] folder in
            guard let self else { return }
            if let folder {
                self.load(folder: folder, replacing: id)
            } else if self.transcriber == nil {
                self.modelMessage = String(localized: "Could not download the model. Check the internet and try again.")
                self.publish()
            }
        }
    }

    /// Loads again a downloaded model whose first load failed (for example, no internet for its tokenizer).
    func retryPendingModel() {
        guard let pending = models.pendingID else { return }
        useDownloadedModel(pending)
    }

    /// Switches to a model that is already on the device (pending or previous), without downloading it.
    func useDownloadedModel(_ id: String) {
        guard !models.isDownloading else { return }
        load(folder: models.folder(for: id), replacing: id)
    }

    func cancelDownload() {
        models.cancelDownload()
        showIfNoModel(String(localized: "Choose a model to download"))
    }

    /// Keeps the model in use: a load running for another one is dropped, and one waiting never starts.
    func keepCurrentModel() {
        guard isLoadingModel, transcriber != nil else { return }
        let dropped = loadingModelID
        loadGeneration += 1
        waitingLoad = nil
        loadingModelID = nil
        models.endLoad(failed: nil)
        // A downloaded model left waiting would load on the next launch and replace the one the user kept.
        if let dropped, dropped == models.pendingID { models.discardPending() }
        publish()
    }

    /// Loads the model in use again after it failed to load.
    func retryInstalledModel() {
        guard transcriber == nil, !isLoadingModel, let folder = models.installedFolder else { return }
        load(folder: folder)
    }

    /// Loads a model. Asking for another while one loads cancels that one for the app: the old one, which Core ML
    /// cannot stop midway, finishes on its own and is dropped, and the new one starts right after it.
    private func load(folder: URL, replacing id: String? = nil) {
        loadGeneration += 1
        loadingModelID = id ?? models.installedID
        installedLoadFailed = false
        models.beginLoad(loadingModelID)
        if transcriber == nil { modelMessage = nil }
        publish()
        if isCoreMLLoading {
            waitingLoad = (folder, id)
        } else {
            startLoad(folder: folder, id: id, generation: loadGeneration)
        }
    }

    private func startLoad(folder: URL, id: String?, generation: Int) {
        isCoreMLLoading = true
        let modelID = id ?? models.installedID
        let tokenizerFolder = models.base
        Task {
            let before = CoreMLCache.entries()
            let loaded = try? await WhisperTranscriber.load(modelFolder: folder, tokenizerFolder: tokenizerFolder)
            let prepared = CoreMLCache.entries().subtracting(before)
            #if DEBUG
            if let loaded, ProcessInfo.processInfo.arguments.contains("-benchmark") {
                await Self.runBenchmark(with: loaded)
            }
            #endif
            await MainActor.run {
                self.isCoreMLLoading = false
                if let modelID {
                    CoreMLCache.record(prepared, for: modelID)
                    // A model deleted while it loaded takes its new copies with it.
                    if !FileManager.default.fileExists(atPath: folder.path) { CoreMLCache.remove(for: modelID) }
                }
                if let waiting = self.waitingLoad {
                    self.waitingLoad = nil
                    self.startLoad(folder: waiting.folder, id: waiting.id, generation: self.loadGeneration)
                }
                guard generation == self.loadGeneration else { return }
                self.loadingModelID = nil
                self.models.endLoad(failed: loaded == nil ? id : nil)
                if let loaded {
                    self.transcriber = loaded
                    self.modelMessage = nil
                    if let id { self.models.commit(id) }
                }
                if loaded == nil && self.transcriber == nil {
                    // The downloaded files stay, so the model can be loaded again without downloading.
                    self.modelMessage = String(localized: "Could not load the model")
                    if id != nil, let installed = self.models.installedFolder {
                        self.load(folder: installed)
                        return
                    }
                    self.installedLoadFailed = id == nil
                }
                self.publish()
            }
        }
    }

    // MARK: - Keyboard commands

    /// Runs a keyboard command once, and only while it is fresh, read from the App Group container.
    private func handleCommand() {
        guard let command = VoiceChannel.readCommand(),
              command.id != lastCommandID,
              command.isFresh() else { return }
        lastCommandID = command.id
        switch command.action {
        case .start: beginRecording(id: command.id)
        case .stop: finishRecording()
        case .cancel: cancelRecording()
        case .wake: break
        }
    }

    private func beginRecording(id: UUID) {
        guard recorder.isRunning, transcriber != nil, !isRecording, !isTranscribing else {
            publish()
            return
        }
        idleTimer?.cancel()
        recorder.beginCapture()
        isRecording = true
        recordingID = id
        state.resultText = ""
        let limit = DispatchWorkItem { [weak self] in self?.finishRecording() }
        recordingLimit = limit
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxRecordingSeconds, execute: limit)
        // A keyboard that dies mid-recording stops pinging; its audio is discarded, never transcribed.
        lastPing = Date()
        keyboardWatch?.invalidate()
        keyboardWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, self.isRecording else { return timer.invalidate() }
            if Date().timeIntervalSince(self.lastPing) > VoiceChannel.heartbeatTimeout { self.cancelRecording() }
        }
        publish()
    }

    private func finishRecording() {
        recordingLimit?.cancel()
        guard isRecording, let transcriber else {
            publish()
            return
        }
        isRecording = false
        var samples = recorder.endCapture()
        #if DEBUG
        if let injected = Self.injectedSamples() { samples = injected }
        #endif
        isTranscribing = true
        publish()
        let language = settings.language == "auto" ? nil : settings.language
        let vocabulary = settings.vocabulary
        let recordingID = recordingID
        Task {
            let transcription = await transcriber.transcribe(samples, fixedLanguage: language, vocabulary: vocabulary)
            await MainActor.run { self.deliver(transcription, recordingID: recordingID) }
        }
    }

    private func deliver(_ transcription: WhisperTranscriber.Transcription, recordingID: UUID?) {
        isTranscribing = false
        if !transcription.text.isEmpty, settings.keepsHistory { history.add(transcription.text) }
        // Tagged even with no text, so a keyboard waiting for this recording stops waiting; an older text never goes
        // out under this recording.
        state.recordingID = recordingID
        state.resultText = ""
        // With the microphone turned off meanwhile, the text goes only to History, not back to the shared file.
        if !transcription.text.isEmpty, recorder.isOn {
            state.resultID += 1
            state.resultText = transcription.text
            let resultID = state.resultID
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.resultLifetime) { [weak self] in
                guard let self, self.state.resultID == resultID, !self.state.resultText.isEmpty else { return }
                self.state.resultText = ""
                self.publish()
            }
        }
        scheduleIdleStop()
        publish()
    }

    private func cancelRecording() {
        recordingLimit?.cancel()
        guard isRecording else {
            publish()
            return
        }
        isRecording = false
        _ = recorder.endCapture()
        scheduleIdleStop()
        publish()
    }

    // MARK: - History

    /// Deletes the history and the last result still waiting in the shared container.
    func clearHistory() {
        history.removeAll()
        state.resultText = ""
        publish()
    }

    // MARK: - State

    private func handleRecorderChange() {
        // The recorder could not restart (a route or configuration change): what was said so far is transcribed.
        if !recorder.isRunning, isRecording { finishRecording() }
        // After an interruption the recorder restarts on its own; the mic must still turn off when unused.
        if !isRecording, !isTranscribing { scheduleIdleStop() }
        publish()
    }

    /// Mirrors the session into the shared state file and tells the keyboard about it.
    private func publish() {
        state.status = currentStatus()
        state.errorMessage = microphoneError ?? modelMessage
        broadcast()
    }

    /// Writes the state for the keyboard and wakes it.
    private func broadcast() {
        VoiceChannel.writeState(state)
        channel.send(.stateChanged)
    }

    /// Without a model to use, the status says what is happening instead.
    private func showIfNoModel(_ message: String) {
        guard transcriber == nil else { return }
        modelMessage = message
        publish()
    }

    /// A recording or transcription in progress wins over a model loading in the background, which keeps the old one usable.
    private func currentStatus() -> VoiceStatus {
        if !recorder.isRunning { return .off }
        if isRecording { return .recording }
        if isTranscribing { return .transcribing }
        if transcriber == nil { return isLoadingModel ? .loading : .unavailable }
        return .ready
    }

    #if DEBUG
    /// Test hook: with the -benchmark launch argument, transcribes every Documents/benchmark/*.wav into Documents/benchmark.txt.
    private static func runBenchmark(with transcriber: WhisperTranscriber) async {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let files = try? FileManager.default.contentsOfDirectory(
                at: documents.appendingPathComponent("benchmark"), includingPropertiesForKeys: nil) else { return }
        var report = ""
        for file in files.filter({ $0.pathExtension == "wav" }).sorted(by: { $0.path < $1.path }) {
            guard let samples = try? AudioRecorder.loadSamples(from: file) else { continue }
            for language in [nil, "pt"] as [String?] {
                let result = await transcriber.transcribe(samples, fixedLanguage: language)
                report += String(format: "%@\t%@\t%.1fs audio\t%.1fs\t%@\t%@\n", file.lastPathComponent,
                                 language ?? "auto", result.audioSeconds, result.elapsedSeconds,
                                 result.language, result.text)
            }
        }
        try? report.write(to: documents.appendingPathComponent("benchmark.txt"), atomically: true, encoding: .utf8)
    }

    /// Test hook: when Documents/inject.wav exists, it replaces the microphone audio.
    private static func injectedSamples() -> [Float]? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = documents.appendingPathComponent("inject.wav")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? AudioRecorder.loadSamples(from: url)
    }
    #endif
}
