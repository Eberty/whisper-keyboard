import AVFoundation

/// Keeps the microphone open and collects 16 kHz mono samples between `beginCapture` and `endCapture`.
final class AudioRecorder {
    static let sampleRate: Double = 16_000
    private static let preRollSeconds: Double = 0.4

    /// Called on the main queue when the engine stops or restarts on its own.
    var onRunningChanged: (() -> Void)?
    /// Called when a call or another app takes the microphone, before the captured audio is dropped.
    var onInterrupted: (() -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var preRoll: [Float] = []
    private var capturing = false
    private var wantsRunning = false

    init() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleInterruption(_:)),
                           name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(handleReset),
                           name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        center.addObserver(self, selector: #selector(handleReset),
                           name: .AVAudioEngineConfigurationChange, object: engine)
    }

    var isRunning: Bool { engine.isRunning }
    /// Turned on and not turned off since, even while a call or another app holds the microphone.
    var isOn: Bool { wantsRunning }

    func start() throws {
        wantsRunning = true
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true)

        let input = engine.inputNode
        // The tap goes first, so the audio thread never sees the converter being replaced.
        input.removeTap(onBus: 0)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInput
        }
        let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat)
        lock.withLock { converter = newConverter }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        wantsRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        _ = endCapture()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func beginCapture() {
        lock.withLock {
            samples = preRoll
            // Starts over, so a quick new recording never repeats audio from before the previous one.
            preRoll = []
            capturing = true
        }
    }

    func endCapture() -> [Float] {
        lock.withLock {
            capturing = false
            let captured = samples
            samples = []
            return captured
        }
    }

    /// Reads an audio file as 16 kHz mono samples.
    static func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: input)
        let recorder = AudioRecorder()
        recorder.converter = AVAudioConverter(from: file.processingFormat, to: recorder.outputFormat)
        return recorder.convert(input)
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        let chunk = convert(buffer)
        guard !chunk.isEmpty else { return }
        lock.withLock {
            if capturing {
                samples.append(contentsOf: chunk)
            } else {
                preRoll.append(contentsOf: chunk)
                let limit = Int(Self.sampleRate * Self.preRollSeconds)
                if preRoll.count > limit { preRoll.removeFirst(preRoll.count - limit) }
            }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converter = lock.withLock({ self.converter }) else { return [] }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    // Audio notifications can arrive on internal queues; state changes happen on main, like start() and stop().
    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if type == .began {
                self.onInterrupted?()
                _ = self.endCapture()
            } else {
                self.restartIfWanted()
            }
            self.onRunningChanged?()
        }
    }

    @objc private func handleReset() {
        DispatchQueue.main.async { [weak self] in
            self?.restartIfWanted()
            self?.onRunningChanged?()
        }
    }

    private func restartIfWanted() {
        guard wantsRunning else { return }
        engine.stop()
        try? start()
    }

    enum RecorderError: LocalizedError {
        case noInput
        var errorDescription: String? { String(localized: "No microphone available") }
    }
}
