import CoreML
import Foundation
import WhisperKit

/// Transcribes 16 kHz mono samples with WhisperKit, entirely on device.
final class WhisperTranscriber {
    struct Transcription {
        let text: String
        let language: String
        let audioSeconds: Double
        let elapsedSeconds: Double
    }

    /// Languages the speaker mixes; detection picks the most likely of these.
    static let languages = ["pt", "en", "es"]

    /// Style hints that steer punctuation and keep technical terms as spoken.
    private static let prompts = [
        "pt": "Olá, tudo bem? Vou revisar o pull request e fazer o deploy amanhã.",
        "en": "Hello, how are you? I'll review the pull request and deploy it tomorrow.",
        "es": "Hola, ¿qué tal? Mañana reviso el pull request y hago el deploy.",
    ]
    /// In automatic mode the language is detected during decoding, after the prompt is chosen, so one hint covers all.
    private static let automaticPrompt = "Olá, tudo bem? Hello, how are you? Hola, ¿qué tal? Vou revisar o pull request e fazer o deploy."
    /// WhisperKit keeps at most 111 prompt tokens, and the prompt shares a 224-token budget with the text of each
    /// 30 s window, so the prompt stays short to leave room for fast speech.
    static let maxPromptTokens = 80

    private static let minimumSeconds = 0.3
    /// The loudest 30 ms of a recording below this is silence or room noise; even soft speech goes well above it.
    static let silenceLevel: Float = 0.015

    /// Whether any 30 ms of the recording is louder than silence or room noise.
    static func hasSound(_ samples: [Float]) -> Bool {
        let frame = Int(AudioRecorder.sampleRate * 0.03)
        var start = 0
        while start < samples.count {
            let chunk = samples[start..<min(start + frame, samples.count)]
            let energy = chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(chunk.count)
            if energy.squareRoot() >= silenceLevel { return true }
            start += frame
        }
        return false
    }

    private let pipe: WhisperKit

    private init(pipe: WhisperKit) {
        self.pipe = pipe
    }

    /// Core ML keeps the model prepared for this device's chip in the app's caches, tied to the installed app: after an
    /// install or update it prepares the model again and never uses the old copy, which would pile up. Each install
    /// has its own bundle path, so a new path means the cache can go.
    static func clearStaleDeviceCache() {
        let defaults = UserDefaults.standard
        // An iOS update prepares the model again too, in a folder of its own, while the app's path stays the same.
        let install = Bundle.main.bundleURL.path + "|" + ProcessInfo.processInfo.operatingSystemVersionString
        guard defaults.string(forKey: CoreMLCache.installKey) != install else { return }
        defaults.set(install, forKey: CoreMLCache.installKey)
        CoreMLCache.recorded = [:]
        guard let root = CoreMLCache.root else { return }
        try? FileManager.default.removeItem(at: root)
    }

    /// Loads a downloaded model. The GPU is never used, because iOS denies it to apps in the background.
    static func load(modelFolder: URL, tokenizerFolder: URL) async throws -> WhisperTranscriber {
        let compute = ModelComputeOptions(
            melCompute: .cpuOnly,
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine
        )
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            tokenizerFolder: tokenizerFolder,
            computeOptions: compute,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        let pipe = try await WhisperKit(config)
        // Language detection then happens inside the transcription, among `languages` only, with no extra encoder pass.
        if let tokenizer = pipe.tokenizer {
            let limited = LanguageLimitedTokenizer(base: tokenizer, languages: languages)
            if limited.allLanguageTokens.count == languages.count { pipe.tokenizer = limited }
        }
        return WhisperTranscriber(pipe: pipe)
    }

    /// Transcribes in `fixedLanguage`, or detects it among `languages` while decoding when nil.
    /// `vocabulary` lists words to spell as given.
    func transcribe(_ samples: [Float], fixedLanguage: String? = nil, vocabulary: [String] = []) async -> Transcription {
        let started = Date()
        let audioSeconds = Double(samples.count) / AudioRecorder.sampleRate
        // On silence or room noise Whisper invents short phrases, so they never reach it.
        guard audioSeconds >= Self.minimumSeconds, Self.hasSound(samples) else {
            return Transcription(text: "", language: "", audioSeconds: audioSeconds, elapsedSeconds: 0)
        }

        let prompt = fixedLanguage.flatMap { Self.prompts[$0] } ?? Self.automaticPrompt
        let options = DecodingOptions(
            task: .transcribe,
            language: fixedLanguage,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: fixedLanguage == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens(prompt, vocabulary: vocabulary)
        )
        let results = (try? await pipe.transcribe(audioArray: samples, decodeOptions: options)) ?? []
        let text = results.map(\.text).joined(separator: " ")
        return Transcription(
            text: Self.clean(text),
            language: fixedLanguage ?? results.first?.language ?? "",
            audioSeconds: audioSeconds,
            elapsedSeconds: Date().timeIntervalSince(started)
        )
    }

    /// The style hint, always whole, then as many whole vocabulary words as fit in `maxPromptTokens`.
    private func promptTokens(_ prompt: String, vocabulary: [String]) -> [Int]? {
        guard let tokenizer = pipe.tokenizer else { return nil }
        var tokens = Self.encode(prompt, words: [], with: tokenizer)
        var words: [String] = []
        for word in vocabulary {
            let candidate = Self.encode(prompt, words: words + [word], with: tokenizer)
            guard candidate.count <= Self.maxPromptTokens else { break }
            words.append(word)
            tokens = candidate
        }
        return tokens
    }

    /// Whether every word fits with the longest style hint, measured with this model's tokenizer.
    func vocabularyFits(_ vocabulary: [String]) -> Bool {
        guard let tokenizer = pipe.tokenizer else { return Self.estimatedFit(vocabulary) }
        return Self.encode(Self.automaticPrompt, words: vocabulary, with: tokenizer).count <= Self.maxPromptTokens
    }

    /// The prompt followed by the words as a list, without special tokens.
    private static func encode(_ prompt: String, words: [String], with tokenizer: WhisperTokenizer) -> [Int] {
        let list = words.isEmpty ? "" : " " + words.joined(separator: ", ") + "."
        return tokenizer.encode(text: " " + prompt + list).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    }

    /// Without a model: one token for every two characters, since acronyms and numbers take more than words.
    static func estimatedFit(_ vocabulary: [String]) -> Bool {
        let characters = automaticPrompt.count + vocabulary.reduce(0) { $0 + $1.count + 2 }
        return (characters + 1) / 2 <= maxPromptTokens
    }

    private static func clean(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let isOnlyNoise = collapsed.allSatisfy { !$0.isLetter && !$0.isNumber }
        return isOnlyNoise ? "" : collapsed
    }
}

/// Passes everything to WhisperKit's tokenizer but lists only some languages, which is all language detection
/// considers, so detection picks among them.
private final class LanguageLimitedTokenizer: WhisperTokenizer {
    private let base: WhisperTokenizer
    let allLanguageTokens: Set<Int>

    init(base: WhisperTokenizer, languages: [String]) {
        self.base = base
        allLanguageTokens = Set(languages.compactMap { base.convertTokenToId("<|\($0)|>") })
    }

    var specialTokens: SpecialTokens { base.specialTokens }
    func encode(text: String) -> [Int] { base.encode(text: text) }
    func decode(tokens: [Int]) -> String { base.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        base.splitToWordTokens(tokenIds: tokenIds)
    }
}

/// The copies Core ML prepares in the app's caches when a model loads, recorded per model, so a deleted model's copy
/// goes with it instead of staying until the next app update.
enum CoreMLCache {
    static let installKey = "coreMLCacheInstall"
    private static let entriesKey = "coreMLCacheEntries"

    /// The copies recorded for each model.
    fileprivate(set) static var recorded: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: entriesKey) as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: entriesKey) }
    }

    static var root: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return caches.appendingPathComponent(bundleID).appendingPathComponent("com.apple.e5rt.e5bundlecache")
    }

    /// Prepared copies, as paths inside the cache two levels deep (a build, then one copy).
    static func entries() -> Set<String> {
        guard let root else { return [] }
        let fileManager = FileManager.default
        var found = Set<String>()
        for build in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] {
            for entry in (try? fileManager.contentsOfDirectory(atPath: root.appendingPathComponent(build).path)) ?? [] {
                found.insert(build + "/" + entry)
            }
        }
        return found
    }

    /// Adds the copies that appeared while `id` loaded. Core ML loads one model at a time here, so they are its own.
    static func record(_ added: Set<String>, for id: String) {
        guard !added.isEmpty else { return }
        recorded[id] = Array(Set(recorded[id] ?? []).union(added)).sorted()
    }

    /// Deletes the copies recorded for a model that is being deleted.
    static func remove(for id: String) {
        guard let entries = recorded[id] else { return }
        recorded[id] = nil
        guard let root else { return }
        for entry in entries { try? FileManager.default.removeItem(at: root.appendingPathComponent(entry)) }
    }
}
