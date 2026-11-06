import Foundation

/// The few user choices the app offers, saved on this device.
final class AppSettings: ObservableObject {
    /// Seconds in the background without use before the mic turns off; 0 means never.
    static let idleChoices = [15, 30, 60, 120, 300, 900, 0]

    private let defaults = UserDefaults.standard

    private enum Key {
        static let language = "language"
        static let idleSeconds = "idleSeconds"
        static let keepsHistory = "keepsHistory"
        static let vocabulary = "vocabulary"
    }

    @Published var language: String {
        didSet { defaults.set(language, forKey: Key.language) }
    }

    @Published var idleSeconds: Int {
        didSet { defaults.set(idleSeconds, forKey: Key.idleSeconds) }
    }

    @Published var keepsHistory: Bool {
        didSet { defaults.set(keepsHistory, forKey: Key.keepsHistory) }
    }

    /// Names and terms the user wants written their way; they guide Whisper's spelling.
    @Published var vocabulary: [String] {
        didSet { defaults.set(vocabulary, forKey: Key.vocabulary) }
    }

    init() {
        language = defaults.string(forKey: Key.language) ?? "auto"
        idleSeconds = defaults.object(forKey: Key.idleSeconds) as? Int ?? 60
        keepsHistory = defaults.object(forKey: Key.keepsHistory) as? Bool ?? true
        vocabulary = defaults.stringArray(forKey: Key.vocabulary) ?? []
    }
}
