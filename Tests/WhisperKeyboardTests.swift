import AVFoundation
import XCTest
@testable import WhisperKeyboard

final class TextSpacingTests: XCTestCase {
    func testEmptyFieldGetsNoSpaces() {
        XCTAssertEqual(TextSpacing.padded("Oi.", before: nil, after: nil), "Oi.")
        XCTAssertEqual(TextSpacing.padded("Oi.", before: "", after: ""), "Oi.")
    }

    func testSpaceBeforeWhenAfterAWord() {
        XCTAssertEqual(TextSpacing.padded("Tudo bem?", before: "Oi.", after: nil), " Tudo bem?")
    }

    func testNoSpaceBeforeWhenAfterASpace() {
        XCTAssertEqual(TextSpacing.padded("Tudo bem?", before: "Oi. ", after: nil), "Tudo bem?")
    }

    func testSpaceAfterWhenInsertedBeforeAWord() {
        XCTAssertEqual(TextSpacing.padded("Oi.", before: nil, after: "Tudo bem?"), "Oi. ")
    }

    func testNoSpaceInsideOpeningMarks() {
        XCTAssertEqual(TextSpacing.padded("texto", before: "Veja (", after: nil), "texto")
        XCTAssertEqual(TextSpacing.padded("Qué tal", before: "Hola ¿", after: "?"), "Qué tal")
    }

    func testSpaceBeforeOpeningMarks() {
        XCTAssertEqual(TextSpacing.padded("Hola", before: nil, after: "¿Qué?"), "Hola ")
        XCTAssertEqual(TextSpacing.padded("Veja", before: nil, after: "(isso)"), "Veja ")
    }

    func testNoSpaceAfterBeforeASpaceOrPunctuation() {
        XCTAssertEqual(TextSpacing.padded("Oi", before: nil, after: " tudo"), "Oi")
        XCTAssertEqual(TextSpacing.padded("Oi", before: nil, after: ", tudo"), "Oi")
    }
}

final class VoiceChannelTests: XCTestCase {
    func testCommandIsFreshOnlyForAShortTime() {
        let now = Date()
        let command = VoiceCommand(id: UUID(), action: .start, date: now)
        XCTAssertTrue(command.isFresh(at: now))
        XCTAssertFalse(command.isFresh(at: now.addingTimeInterval(VoiceChannel.commandLifetime + 1)))
        XCTAssertFalse(command.isFresh(at: now.addingTimeInterval(-(VoiceChannel.commandLifetime + 1))))
    }

    func testCommandAndStateSurviveTheSharedFiles() throws {
        let command = VoiceCommand(id: UUID(), action: .stop, date: Date(timeIntervalSince1970: 1_000))
        let decodedCommand = try JSONDecoder().decode(VoiceCommand.self, from: JSONEncoder().encode(command))
        XCTAssertEqual(decodedCommand.id, command.id)
        XCTAssertEqual(decodedCommand.action, .stop)
        XCTAssertEqual(decodedCommand.date, command.date)

        var state = VoiceState()
        state.status = .transcribing
        state.resultID = 7
        state.resultText = "Oi"
        state.recordingID = command.id
        let decodedState = try JSONDecoder().decode(VoiceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decodedState.status, .transcribing)
        XCTAssertEqual(decodedState.resultID, 7)
        XCTAssertEqual(decodedState.resultText, "Oi")
        XCTAssertEqual(decodedState.recordingID, command.id)

        // A state written before results carried their recording still reads.
        let older = try JSONDecoder().decode(VoiceState.self, from: Data(#"{"status":"ready","resultID":3,"resultText":""}"#.utf8))
        XCTAssertNil(older.recordingID)
    }

    func testHeartbeatTimeoutAllowsMissedPings() {
        XCTAssertGreaterThan(VoiceChannel.heartbeatTimeout, VoiceChannel.heartbeatInterval * 2)
    }
}

final class ModelCatalogTests: XCTestCase {
    private let today = [
        "openai_whisper-small", "openai_whisper-small.en_217MB", "openai_whisper-small_216MB",
        "openai_whisper-large-v2_949MB", "openai_whisper-large-v2_turbo_955MB",
        "openai_whisper-large-v3", "openai_whisper-large-v3_947MB", "openai_whisper-large-v3_turbo_954MB",
        "openai_whisper-large-v3-v20240930_547MB", "openai_whisper-large-v3-v20240930_626MB",
        "openai_whisper-large-v3-v20240930_turbo", "openai_whisper-large-v3-v20240930_turbo_632MB",
        "distil-whisper_distil-large-v3_594MB",
    ]

    private func newest(_ names: [String]) -> [String?] {
        ModelManager.tiers.map { ModelManager.newest(in: names, matching: $0.pattern, preferring: $0.initialID) }
    }

    func testTodayEachTierKeepsItsModel() {
        XCTAssertEqual(newest(today), ModelManager.tiers.map(\.initialID))
    }

    func testNewerVersionsAreFoundWithinTheirTier() {
        let future = today + [
            "openai_whisper-small-v20260101_220MB",
            "openai_whisper-large-v3-v20260301_turbo_640MB",
            "openai_whisper-large-v4_1100MB",
            "openai_whisper-large-v4-v20260601_turbo_700MB",
        ]
        XCTAssertEqual(newest(future), [
            "openai_whisper-small-v20260101_220MB",
            "openai_whisper-large-v4-v20260601_turbo_700MB",
            "openai_whisper-large-v4_1100MB",
        ])
    }

    func testTierOfAModelName() {
        XCTAssertEqual(ModelManager.tier(of: "openai_whisper-small_216MB"), 0)
        XCTAssertEqual(ModelManager.tier(of: "openai_whisper-large-v3-v20240930_turbo_632MB"), 1)
        XCTAssertEqual(ModelManager.tier(of: "openai_whisper-large-v3_947MB"), 2)
        XCTAssertNil(ModelManager.tier(of: "openai_whisper-tiny"))
    }
}

final class ModelDownloadTests: XCTestCase {
    private struct NetworkLost: Error {}
    private let light = ModelManager.tiers[0].initialID
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testFailedDownloadKeepsItsFilesForTheRetry() throws {
        let done = modelFile(light, "AudioEncoder.mlmodelc/weights.bin")
        let incomplete = cacheFile(light, "TextDecoder.bin.etag.incomplete")
        var foundOnRetry = false
        let manager = ModelManager(base: base) { _, _, _ in
            if self.exists(incomplete) { foundOnRetry = self.exists(done) }
            try self.write(Data("part".utf8), to: done, incomplete)
            throw NetworkLost()
        }

        for _ in 0..<2 {
            let failed = expectation(description: "download failed")
            manager.download(light) { folder in
                XCTAssertNil(folder)
                failed.fulfill()
            }
            wait(for: [failed], timeout: 5)
        }

        XCTAssertEqual(manager.phase, .failed)
        XCTAssertTrue(foundOnRetry)
        XCTAssertTrue(exists(done))
        XCTAssertTrue(exists(incomplete))
    }

    func testDownloadCutOffByClosingTheAppIsKeptOnTheNextLaunch() throws {
        let done = modelFile(light, "AudioEncoder.mlmodelc/weights/weight.bin")
        let incomplete = cacheFile(light, "TextDecoder.bin.etag.incomplete")
        let started = expectation(description: "download started")
        let manager = ModelManager(base: base) { _, _, _ in
            try self.write(Data("part".utf8), to: done, incomplete)
            started.fulfill()
            // The app is closed before the download ends.
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw CancellationError()
        }
        manager.download(light) { _ in }
        wait(for: [started], timeout: 5)

        let relaunched = offlineManager()

        XCTAssertEqual(relaunched.partialID, light)
        XCTAssertTrue(exists(done))
        XCTAssertTrue(exists(incomplete))
    }

    func testDiscardedPendingModelDoesNotLoadOnTheNextLaunch() throws {
        let id = ModelManager.tiers[2].initialID
        let file = modelFile(id, "AudioEncoder.mlmodelc/model.mil")
        try write(Data("model".utf8), to: file)
        try id.write(to: base.appendingPathComponent("pending-model"), atomically: true, encoding: .utf8)

        let manager = offlineManager()
        XCTAssertEqual(manager.pendingID, id)
        manager.discardPending()

        XCTAssertNil(offlineManager().pendingID)
        XCTAssertFalse(exists(file))
    }

    func testProgressCountsFinishedAndPartialBytes() throws {
        let id = "openai_whisper-small_4MB"
        let manager = offlineManager()
        let done = modelFile(id, "AudioEncoder.mlmodelc/weights/weight.bin")
        let partial = cacheFile(id, "TextDecoder.mlmodelc/weights/weight.bin.etag.incomplete")
        let metadata = cacheFile(id, "config.json.metadata")
        try write(Data(count: 1_048_576), to: done, partial, metadata)
        XCTAssertEqual(manager.downloadedFraction(of: id), 0.5, accuracy: 0.001)

        try Data(count: 4 * 1_048_576).write(to: done)
        XCTAssertEqual(manager.downloadedFraction(of: id), 0.99, accuracy: 0.001)
    }

    /// A file inside a model's folder.
    private func modelFile(_ id: String, _ path: String) -> URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(id)/\(path)")
    }

    /// A file in WhisperKit's download cache for a model.
    private func cacheFile(_ id: String, _ path: String) -> URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/\(id)/\(path)")
    }

    private func write(_ data: Data, to files: URL...) throws {
        for file in files {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
    }

    private func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    /// A manager whose downloads always fail, as on a launch without internet.
    private func offlineManager() -> ModelManager {
        ModelManager(base: base) { _, _, _ in throw NetworkLost() }
    }
}

final class CoreMLCacheTests: XCTestCase {
    func testDeletingAModelDeletesOnlyItsPreparedCopies() throws {
        let root = try XCTUnwrap(CoreMLCache.root)
        let build = "test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(at: root.appendingPathComponent(build)) }
        let before = CoreMLCache.entries()
        for entry in ["light", "best"] {
            let folder = root.appendingPathComponent(build).appendingPathComponent(entry)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("compiled".utf8).write(to: folder.appendingPathComponent("model.bundle"))
        }
        let added = CoreMLCache.entries().subtracting(before)
        XCTAssertEqual(added, [build + "/light", build + "/best"])

        CoreMLCache.record([build + "/light"], for: "test-light")
        CoreMLCache.record([build + "/best"], for: "test-best")
        CoreMLCache.remove(for: "test-light")
        CoreMLCache.remove(for: "test-best-unused")

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(build + "/light").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(build + "/best").path))
        CoreMLCache.remove(for: "test-best")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(build + "/best").path))
    }
}

final class MicrophoneMessageTests: XCTestCase {
    func testSystemAudioErrorsBecomeTheAppsOwnMessages() {
        // What iOS returns when a call holds the microphone; its description is English only.
        let call = NSError(domain: NSOSStatusErrorDomain, code: AVAudioSession.ErrorCode.insufficientPriority.rawValue,
                           userInfo: [NSLocalizedDescriptionKey: "Session activation failed"])
        XCTAssertEqual(VoiceSession.microphoneMessage(for: call),
                       String(localized: "Microphone in use"))

        let other = NSError(domain: NSOSStatusErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown"])
        XCTAssertEqual(VoiceSession.microphoneMessage(for: other), String(localized: "Session activation failed"))
    }
}

final class SilenceTests: XCTestCase {
    func testSilenceAndRoomNoiseAreNotSound() {
        let second = Int(AudioRecorder.sampleRate)
        XCTAssertFalse(WhisperTranscriber.hasSound([Float](repeating: 0, count: 3 * second)))
        // Room noise, a little louder than an iPhone's microphone picks up in a quiet room.
        let noise = (0..<3 * second).map { _ in Float.random(in: -0.008...0.008) }
        XCTAssertFalse(WhisperTranscriber.hasSound(noise))
    }

    func testSoftSpeechIsSound() {
        let second = Int(AudioRecorder.sampleRate)
        // Half a second of a soft voice-like tone in the middle of silence.
        var samples = [Float](repeating: 0, count: 2 * second)
        for index in second..<(second + second / 2) {
            samples[index] = 0.05 * sin(Float(index) * 2 * .pi * 220 / Float(second))
        }
        XCTAssertTrue(WhisperTranscriber.hasSound(samples))
    }
}
