import Foundation

/// Status of the voice session that runs inside the app.
enum VoiceStatus: String, Codable {
    case off
    case loading
    case ready
    case recording
    case transcribing
    /// The app is running but cannot transcribe (no model, or it failed to load); `errorMessage` says why.
    case unavailable
}

/// Snapshot the app shares with the keyboard through the App Group container.
struct VoiceState: Codable, Equatable {
    var status: VoiceStatus = .off
    var resultID: Int = 0
    var resultText: String = ""
    /// The keyboard command that started the recording `resultText` came from.
    var recordingID: UUID?
    var errorMessage: String?
}

/// What the keyboard asks the app to do.
enum VoiceAction: String, Codable {
    case start
    case stop
    case cancel
    /// Written right before the keyboard opens the app, so the app knows the URL came from the keyboard.
    case wake
}

/// A keyboard request, written to the App Group container so only this app's own processes can issue it.
struct VoiceCommand: Codable {
    let id: UUID
    let action: VoiceAction
    let date: Date

    /// Only a recent command counts, so an old file cannot be replayed.
    func isFresh(at now: Date = Date()) -> Bool {
        abs(date.timeIntervalSince(now)) < VoiceChannel.commandLifetime
    }
}

/// Cross-process wake-ups between the keyboard and the app (Darwin notifications carry no data).
enum VoiceSignal: String, CaseIterable {
    case command
    case ping
    case pong
    case stateChanged

    /// Based on the App Group, so a copy built with another bundle prefix never talks to this one.
    var notificationName: String { "\(VoiceChannel.appGroupID).\(rawValue)" }
}

/// Darwin notifications plus the shared files in the App Group container.
final class VoiceChannel {
    /// Commands older than this are ignored, so a stale file cannot be replayed.
    static let commandLifetime: TimeInterval = 3
    /// While recording, the keyboard pings this often; the app discards the recording after `heartbeatTimeout` without one.
    static let heartbeatInterval: TimeInterval = 2
    static let heartbeatTimeout: TimeInterval = 5

    private var handlers: [String: () -> Void] = [:]

    static var appGroupID: String {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? ""
    }

    private static func sharedFile(_ name: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(name)
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    func send(_ signal: VoiceSignal) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(signal.notificationName as CFString),
            nil, nil, true
        )
    }

    /// Writes the command where only the app group can write, then wakes the app.
    @discardableResult
    func send(_ action: VoiceAction) -> UUID {
        let command = VoiceCommand(id: UUID(), action: action, date: Date())
        Self.write(command, to: "command.json")
        send(.command)
        return command.id
    }

    /// Calls `handler` on the main queue whenever `signal` is posted.
    func observe(_ signal: VoiceSignal, handler: @escaping () -> Void) {
        handlers[signal.notificationName] = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let channel = Unmanaged<VoiceChannel>.fromOpaque(observer).takeUnretainedValue()
                let key = name.rawValue as String
                DispatchQueue.main.async { channel.handlers[key]?() }
            },
            signal.notificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    static func readCommand() -> VoiceCommand? {
        read(VoiceCommand.self, from: "command.json")
    }

    static func readState() -> VoiceState? {
        read(VoiceState.self, from: "state.json")
    }

    static func writeState(_ state: VoiceState) {
        write(state, to: "state.json")
    }

    private static func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let url = sharedFile(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to name: String) {
        guard var url = sharedFile(name), let data = try? JSONEncoder().encode(value) else { return }
        url.writeProtected(data)
    }
}
