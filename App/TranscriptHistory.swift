import Foundation

/// Keeps only the most recent transcriptions, on this device, and never the audio.
final class TranscriptHistory: ObservableObject {
    static let limit = 100

    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        let text: String
        let date: Date
    }

    @Published private(set) var entries: [Entry] = []

    private let fileURL: URL?
    /// Set when the saved file exists but could not be read (for example, the device was locked at launch);
    /// the next save merges it first instead of overwriting it.
    private var needsReload = false

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        fileURL = support?.appendingPathComponent("history.json")
        if let saved = readSaved() {
            entries = Array(saved.prefix(Self.limit))
        } else {
            needsReload = true
        }
    }

    /// The saved entries, an empty list when there is no file, or nil when the file cannot be read now.
    private func readSaved() -> [Entry]? {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    func add(_ text: String) {
        entries.insert(Entry(id: UUID(), text: text, date: Date()), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        save()
    }

    func removeAll() {
        entries.removeAll()
        needsReload = false
        save()
    }

    private func save() {
        if needsReload {
            guard let saved = readSaved() else { return }
            let known = Set(entries.map(\.id))
            entries = Array((entries + saved.filter { !known.contains($0.id) }).prefix(Self.limit))
            needsReload = false
        }
        guard var fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        fileURL.writeProtected(data)
    }
}
