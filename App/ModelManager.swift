import Foundation
import WhisperKit

/// Downloads the chosen WhisperKit model once; only that one stays, plus the previous one for a short while.
/// Unchecked Sendable: its state only changes on the main queue.
final class ModelManager: ObservableObject, @unchecked Sendable {
    struct Option: Identifiable {
        let id: String
        let title: String.LocalizationValue
        /// What the level is good for, shown before downloading it.
        let summary: String.LocalizationValue
        let systemImage: String
        /// Index in `tiers`.
        let tier: Int

        /// The same level with another model name, such as its newer version.
        func with(id: String) -> Option {
            Option(id: id, title: title, summary: summary, systemImage: systemImage, tier: tier)
        }

        /// Size as published in the model name, e.g. "632 MB".
        var size: String {
            id.split(separator: "_").last.map { $0.replacingOccurrences(of: "MB", with: " MB") } ?? ""
        }
    }

    /// A level of quality. Model names change as new versions come out, so each level is a name pattern;
    /// the newest name matching it in the repository is used. Groups before the last one (the size) order versions.
    struct Tier {
        let title: String.LocalizationValue
        let summary: String.LocalizationValue
        let systemImage: String
        let pattern: String
        let initialID: String
    }

    static let tiers = [
        Tier(title: "Light", summary: "Fast. Good for short messages.", systemImage: "hare",
             pattern: #"^openai_whisper-small(?:-v(\d{8}))?_(\d+)MB$"#,
             initialID: "openai_whisper-small_216MB"),
        Tier(title: "Balanced", summary: "More accurate. Ideal for technical terms.", systemImage: "gauge.with.dots.needle.50percent",
             pattern: #"^openai_whisper-large-v(\d+)-v(\d{8})_turbo_(\d+)MB$"#,
             initialID: "openai_whisper-large-v3-v20240930_turbo_632MB"),
        Tier(title: "Best", summary: "The most accurate, but much slower and heavier.", systemImage: "star",
             pattern: #"^openai_whisper-large-v(\d+)_(\d+)MB$"#,
             initialID: "openai_whisper-large-v3_947MB"),
    ]
    private static let defaultTier = 1
    private static let catalogKey = "modelCatalog"
    /// Lists the folders of WhisperKit's public model repository; only used when the user checks for updates.
    private static let repositoryTree = URL(string: "https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/tree/main")!

    /// How long the previous model is kept after a switch, so switching back needs no download.
    static let previousModelLifetime: TimeInterval = 15 * 60

    enum Phase: Equatable {
        case idle
        case downloading(id: String, progress: Double)
        case failed
    }

    /// The model that last loaded successfully.
    @Published private(set) var installedID: String?
    /// A model that finished downloading but has not loaded yet; kept so a failed or interrupted load can be retried.
    @Published private(set) var pendingID: String?
    /// The model in use before the last switch; deleted after `previousModelLifetime`.
    @Published private(set) var previousID: String?
    @Published private(set) var phase: Phase = .idle
    /// The model name used for each tier.
    @Published private(set) var catalog: [String]
    /// Newer versions found for tiers whose current model is on the device; they download only when the user asks.
    @Published private(set) var updates: [Int: String] = [:]
    @Published private(set) var isChecking = false
    @Published private(set) var checkFailed = false
    /// A downloaded model whose last load failed, so its row can say so.
    @Published private(set) var failedID: String?
    /// The model being loaded now; while it loads or a download runs, the previous model is not deleted.
    private(set) var loadingID: String?
    /// A download that has not finished (running, failed, or cut off when the app closed); its files stay, also across
    /// launches (`partial-model`), until a download of another model starts, so trying again resumes.
    private(set) var partialID: String?

    /// Root that WhisperKit downloads into; the tokenizer is fetched here too on the first load.
    let base: URL
    private let installedMarker: URL
    private let pendingMarker: URL
    private let previousMarker: URL
    private let partialMarker: URL
    private var downloadTask: Task<Void, Never>?
    /// Identifies the running download, so a late result from a cancelled one is ignored.
    private var downloadToken: UUID?
    private var previousExpiry: DispatchWorkItem?
    private var previousUntil: Date?
    /// Fetches a model into `base`, reporting progress; replaced in tests.
    private let fetch: (String, URL, @escaping @Sendable (Progress) -> Void) async throws -> URL

    init(
        base: URL? = nil,
        fetch: @escaping (String, URL, @escaping @Sendable (Progress) -> Void) async throws -> URL = ModelManager.downloadModel
    ) {
        self.fetch = fetch
        // WhisperKit's network monitor can stay stuck offline after the connection returns; set once, before any thread reads it.
        setenv("CI_DISABLE_NETWORK_MONITOR", "1", 1)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var base = base ?? support.appendingPathComponent("WhisperModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        base.excludeFromBackup()
        self.base = base
        installedMarker = base.appendingPathComponent("installed-model")
        pendingMarker = base.appendingPathComponent("pending-model")
        previousMarker = base.appendingPathComponent("previous-model")
        partialMarker = base.appendingPathComponent("partial-model")
        let saved = UserDefaults.standard.stringArray(forKey: Self.catalogKey) ?? []
        catalog = saved.count == Self.tiers.count ? saved : Self.tiers.map(\.initialID)

        installedID = readMarker(installedMarker)
        pendingID = readMarker(pendingMarker)
        if pendingID == installedID { pendingID = nil }
        // Models on the device always have a row: the installed one in its tier, a pending one as that tier's update.
        if let installedID, !catalog.contains(installedID), let tier = Self.tier(of: installedID) {
            catalog[tier] = installedID
        }
        if let pendingID, !catalog.contains(pendingID), let tier = Self.tier(of: pendingID) {
            updates[tier] = pendingID
        }
        restorePrevious()
        if let partial = try? String(contentsOf: partialMarker, encoding: .utf8), !keptIDs.contains(partial) {
            partialID = partial
        }
        removeAll(except: keptIDs)
    }

    private var keptIDs: Set<String> {
        Set([installedID, pendingID, previousID].compactMap { $0 })
    }

    var options: [Option] {
        Self.tiers.indices.map { index in
            let tier = Self.tiers[index]
            return Option(id: catalog[index], title: tier.title, summary: tier.summary, systemImage: tier.systemImage, tier: index)
        }
    }

    var defaultID: String { catalog[Self.defaultTier] }

    /// Looks for newer model names in the repository. A tier whose model is not on the device just switches to the new
    /// name; one whose model is on the device gets an update the user can download.
    func checkForUpdates(completion: @escaping () -> Void = {}) {
        guard !isChecking else { return }
        isChecking = true
        checkFailed = false
        Task {
            let names = try? await Self.repositoryModels()
            await MainActor.run {
                self.isChecking = false
                guard let names else {
                    self.checkFailed = true
                    return
                }
                for (index, tier) in Self.tiers.enumerated() {
                    // A downloaded model still waiting to load keeps its row and retry button.
                    guard self.updates[index] == nil || self.updates[index] != self.pendingID,
                          let newest = Self.newest(in: names, matching: tier.pattern, preferring: self.catalog[index]),
                          newest != self.catalog[index] else { continue }
                    if self.keptIDs.contains(self.catalog[index]) || self.busyIDs.contains(self.catalog[index]) {
                        self.updates[index] = newest
                    } else {
                        self.catalog[index] = newest
                    }
                }
                UserDefaults.standard.set(self.catalog, forKey: Self.catalogKey)
                completion()
            }
        }
    }

    /// Models a download or load is using right now.
    private var busyIDs: Set<String> {
        var ids = Set([loadingID, partialID].compactMap { $0 })
        if case let .downloading(id, _) = phase { ids.insert(id) }
        return ids
    }

    /// The tier whose pattern a model name matches.
    static func tier(of id: String) -> Int? {
        tiers.firstIndex { id.range(of: $0.pattern, options: .regularExpression) != nil }
    }

    private static func repositoryModels() async throws -> [String] {
        struct Entry: Decodable {
            let type: String
            let path: String
        }
        let (data, response) = try await URLSession.shared.data(from: repositoryTree)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode([Entry].self, from: data).filter { $0.type == "directory" }.map(\.path)
    }

    /// The name with the highest version among those matching the pattern; on a tie, the current one.
    static func newest(in names: [String], matching pattern: String, preferring current: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        func version(of name: String) -> [Int]? {
            guard let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { return nil }
            return (1..<max(1, match.numberOfRanges - 1)).map { group in
                Range(match.range(at: group), in: name).flatMap { Int(name[$0]) } ?? 0
            }
        }
        let candidates = names.compactMap { name in version(of: name).map { (name, $0) } }
        guard let best = candidates.map(\.1).max(by: { $0.lexicographicallyPrecedes($1) }) else { return nil }
        let newest = candidates.filter { $0.1 == best }.map(\.0)
        return newest.contains(current) ? current : newest.sorted().first
    }

    var installedFolder: URL? {
        installedID.map(folder(for:))
    }

    var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    func folder(for id: String) -> URL {
        repository.appendingPathComponent(id)
    }

    /// Downloads a model and records it as pending; the current one stays in use until `commit` runs after it loads.
    func download(_ id: String, completion: @escaping (URL?) -> Void) {
        guard !isDownloading else { return }
        if let partialID, partialID != id { delete(partialID) }
        setPartial(id)
        let token = UUID()
        downloadToken = token
        phase = .downloading(id: id, progress: 0)
        failedID = nil
        // WhisperKit counts progress by file, and one file holds most of a model, so progress comes from the bytes on disk.
        Task.detached { [weak self] in
            while let self, await MainActor.run(body: { self.downloadToken == token }) {
                let fraction = self.downloadedFraction(of: id)
                await MainActor.run {
                    guard self.downloadToken == token, case let .downloading(_, current) = self.phase, fraction > current else { return }
                    self.phase = .downloading(id: id, progress: fraction)
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        downloadTask = Task {
            do {
                let folder = try await self.fetch(id, self.base) { _ in }
                try Task.checkCancellation()
                await MainActor.run {
                    // A cancel that landed after the last byte already deleted the files.
                    guard self.downloadToken == token else { return }
                    self.downloadToken = nil
                    self.phase = .idle
                    self.setPartial(nil)
                    if let previous = self.pendingID, previous != id, previous != self.loadingID { self.delete(previous) }
                    self.setPending(id)
                    completion(folder)
                    self.checkPreviousExpiry()
                }
            } catch {
                await MainActor.run {
                    guard self.downloadToken == token else { return }
                    self.downloadToken = nil
                    self.phase = .failed
                    // Keeps what was downloaded, so trying again resumes instead of starting over.
                    if self.keptIDs.contains(id) {
                        self.setPartial(nil)
                        self.discard(id)
                    }
                    completion(nil)
                    self.checkPreviousExpiry()
                }
            }
        }
    }

    private struct IncompleteDownload: Error {}

    /// The bytes of a model on disk, finished and partial files, as a fraction of the size in its name; below 1 until done.
    func downloadedFraction(of id: String) -> Double {
        guard let size = id.split(separator: "_").last, size.hasSuffix("MB"),
              let megabytes = Double(size.dropLast(2)), megabytes > 0 else { return 0 }
        let partial = downloadCache.appendingPathComponent("huggingface/download/\(id)")
        let bytes = Self.bytes(in: folder(for: id)) + Self.bytes(in: partial, suffix: ".incomplete")
        return min(Double(bytes) / (megabytes * 1_048_576), 0.99)
    }

    private static func bytes(in folder: URL, suffix: String? = nil) -> Int {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let file as URL in files where suffix.map(file.lastPathComponent.hasSuffix) ?? true {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    /// Downloads a model and checks that every file the repository lists is on disk: when its network monitor
    /// wrongly reports no connection, WhisperKit returns a partially downloaded model as complete.
    private static func downloadModel(_ id: String, base: URL, progress: @escaping @Sendable (Progress) -> Void) async throws -> URL {
        let folder = try await WhisperKit.download(variant: id, downloadBase: base, progressCallback: progress)
        let hub = HubApiWrapper(downloadBase: base)
        let repo = HubApiWrapper.Repo(id: "argmaxinc/whisperkit-coreml", type: .models)
        let root = hub.localRepoLocation(repo)
        let files = try await hub.getFilenames(from: repo, matching: ["\(id)/*"])
        guard !files.isEmpty,
              files.allSatisfy({ FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }) else {
            throw IncompleteDownload()
        }
        return folder
    }

    /// Deletes a downloaded model that was not kept, so it does not load on the next launch.
    func discardPending() {
        guard let pendingID, pendingID != installedID else { return }
        delete(pendingID)
    }

    /// Stops the download in progress and deletes what was already downloaded.
    func cancelDownload() {
        guard case let .downloading(id, _) = phase else { return }
        phase = .idle
        downloadToken = nil
        downloadTask?.cancel()
        downloadTask = nil
        setPartial(nil)
        discard(id)
        checkPreviousExpiry()
    }

    private func setPartial(_ id: String?) {
        partialID = id
        Self.writeMarker(id, to: partialMarker)
    }

    private func setPending(_ id: String?) {
        pendingID = id
        Self.writeMarker(id, to: pendingMarker)
    }

    /// Saves a marker file, or deletes it when there is nothing to save.
    private static func writeMarker(_ value: String?, to url: URL) {
        if let value {
            try? value.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Marks a model as loading, which also clears earlier failure messages.
    func beginLoad(_ id: String?) {
        loadingID = id
        failedID = nil
        if phase == .failed { phase = .idle }
    }

    /// Ends a load; a failed one is shown on the model's row.
    func endLoad(failed id: String?) {
        loadingID = nil
        failedID = id
        checkPreviousExpiry()
    }

    /// Records the model that loaded, keeps the one it replaced for a while, and deletes everything else.
    func commit(_ id: String) {
        for (index, update) in updates where update == id {
            catalog[index] = id
            updates[index] = nil
        }
        if !catalog.contains(id), let tier = Self.tier(of: id) { catalog[tier] = id }
        UserDefaults.standard.set(catalog, forKey: Self.catalogKey)
        let replaced = installedID
        Self.writeMarker(id, to: installedMarker)
        installedID = id
        setPending(nil)
        if let replaced, replaced != id {
            setPrevious(replaced, until: Date().addingTimeInterval(Self.previousModelLifetime))
        } else if previousID == id {
            clearPrevious()
        }
        removeAll(except: keptIDs)
    }

    /// Deletes a download that failed or was cancelled, unless it is in use, waiting to load or kept as previous.
    func discard(_ id: String) {
        guard id != installedID, id != pendingID, id != previousID else {
            try? FileManager.default.removeItem(at: downloadCache)
            return
        }
        delete(id)
    }

    private func delete(_ id: String) {
        try? FileManager.default.removeItem(at: folder(for: id))
        CoreMLCache.remove(for: id)
        try? FileManager.default.removeItem(at: downloadCache)
        if pendingID == id { setPending(nil) }
    }

    private func setPrevious(_ id: String, until expiry: Date) {
        previousID = id
        previousUntil = expiry
        Self.writeMarker("\(id)\n\(expiry.timeIntervalSince1970)", to: previousMarker)
        previousExpiry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.expirePrevious() }
        previousExpiry = work
        // Wall clock, so time spent suspended or asleep counts.
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, expiry.timeIntervalSinceNow), execute: work)
    }

    private func restorePrevious() {
        guard let contents = try? String(contentsOf: previousMarker, encoding: .utf8) else { return }
        let parts = contents.split(separator: "\n").map(String.init)
        guard parts.count == 2, let seconds = TimeInterval(parts[1]),
              parts[0] != installedID, FileManager.default.fileExists(atPath: folder(for: parts[0]).path) else {
            Self.writeMarker(nil, to: previousMarker)
            return
        }
        let expiry = Date(timeIntervalSince1970: seconds)
        if expiry > Date() {
            setPrevious(parts[0], until: expiry)
        } else {
            Self.writeMarker(nil, to: previousMarker)
        }
    }

    private func clearPrevious() {
        previousExpiry?.cancel()
        previousExpiry = nil
        previousID = nil
        previousUntil = nil
        Self.writeMarker(nil, to: previousMarker)
    }

    /// Runs after a download or load ends, for an expiry that came while it was running.
    /// Async, so a load's commit, which may replace the previous model, happens first.
    private func checkPreviousExpiry() {
        DispatchQueue.main.async {
            guard let until = self.previousUntil, until <= Date() else { return }
            self.expirePrevious()
        }
    }

    private func expirePrevious() {
        // Cleanup would delete files a download or load is using; it runs again when that ends.
        guard !isDownloading, loadingID == nil else { return }
        clearPrevious()
        removeAll(except: keptIDs)
    }

    private func readMarker(_ url: URL) -> String? {
        guard let id = try? String(contentsOf: url, encoding: .utf8),
              FileManager.default.fileExists(atPath: folder(for: id).path) else { return nil }
        return id
    }

    private func removeAll(except kept: Set<String>) {
        let fileManager = FileManager.default
        // Never what a download or load is using right now.
        let ids = kept.union(busyIDs)
        for folder in (try? fileManager.contentsOfDirectory(at: repository, includingPropertiesForKeys: nil)) ?? []
        where !ids.contains(folder.lastPathComponent) && folder.lastPathComponent != ".cache" {
            try? fileManager.removeItem(at: folder)
            CoreMLCache.remove(for: folder.lastPathComponent)
        }
        if !isDownloading && partialID == nil {
            try? fileManager.removeItem(at: downloadCache)
        }
        // Tokenizers are small and WhisperKit picks theirs by vocabulary, not by model name, so they all stay;
        // only their download caches go.
        let tokenizers = base.appendingPathComponent("models/openai")
        for folder in (try? fileManager.contentsOfDirectory(at: tokenizers, includingPropertiesForKeys: nil)) ?? [] {
            try? fileManager.removeItem(at: folder.appendingPathComponent(".cache"))
        }
    }

    /// WhisperKit's local copy of the model repository, one folder per model.
    private var repository: URL { base.appendingPathComponent("models/argmaxinc/whisperkit-coreml") }

    /// Where WhisperKit keeps partial files and metadata while it downloads.
    private var downloadCache: URL { repository.appendingPathComponent(".cache") }
}
