import Foundation
import SwiftData
import SQLite3

@Model
public final class TrackModel {
    @Attribute(.unique) public var id: String
    public var title: String
    public var originalURL: URL
    public var dateAdded: Date
    
    public var vocalStemURL: URL
    public var bassStemURL: URL
    public var drumStemURL: URL
    public var otherStemURL: URL
    
    public init(id: String, title: String, originalURL: URL, dateAdded: Date = Date(), vocalStemURL: URL, bassStemURL: URL, drumStemURL: URL, otherStemURL: URL) {
        self.id = id
        self.title = title
        self.originalURL = originalURL
        self.dateAdded = dateAdded
        self.vocalStemURL = vocalStemURL
        self.bassStemURL = bassStemURL
        self.drumStemURL = drumStemURL
        self.otherStemURL = otherStemURL
    }
}

// MARK: - Library store

/// Opens the on-disk library. Builds up to 1.2 used SwiftData's default
/// configuration, which for this unsandboxed app is the shared
/// ~/Library/Application Support/default.store that other apps also open and
/// migrate, dropping each other's tables. The library now has its own file.
@MainActor
enum LibraryStore {
    static var storeURL: URL { URL.applicationSupportDirectory.appending(path: "Isolate/Library.store") }
    static var legacyStoreURL: URL { URL.applicationSupportDirectory.appending(path: "default.store") }
    static let legacyImportKey = "didImportLegacyLibraryStore"

    enum LegacyImport: Equatable {
        case noLegacyLibrary
        case imported(Int)
        case failed(String)
    }

    struct Opened {
        let container: ModelContainer
        let notice: String?
    }

    private static var startupNotice: String?

    /// A message about library recovery for the main window to show once.
    static func takeStartupNotice() -> String? {
        defer { startupNotice = nil }
        return startupNotice
    }

    static func makeContainer() -> ModelContainer {
        guard !AppPreferences.isTesting else { return inMemoryContainer() }
        let opened = open(at: storeURL)
        startupNotice = opened.notice
        let isPersistent = opened.container.configurations.contains { !$0.isStoredInMemoryOnly }
        if isPersistent, !AppPreferences.defaults.bool(forKey: legacyImportKey) {
            do {
                let result = try importLegacyLibrary(from: legacyStoreURL, into: opened.container.mainContext)
                if case .failed(let message) = result {
                    startupNotice = [startupNotice, message].compactMap { $0 }.joined(separator: " ")
                }
                AppPreferences.defaults.set(true, forKey: legacyImportKey)
            } catch {
                // Copying failed (for example, no disk space); try again next launch.
                NSLog("Isolate: could not read the previous library: \(error)")
            }
        }
        return opened.container
    }

    /// Opens the store at `url`. A store that cannot be opened is moved, never
    /// deleted, into a timestamped backup folder before starting a new one; if
    /// even that fails the session runs in memory and says so.
    static func open(at url: URL, now: Date = .now) -> Opened {
        do {
            return Opened(container: try persistentContainer(at: url), notice: nil)
        } catch {
            NSLog("Isolate: could not open the library at \(url.path): \(error)")
        }
        do {
            let backup = try moveStoreAside(at: url, now: now)
            let container = try persistentContainer(at: url)
            let kept = backup.map { " The previous library was moved to \($0.path)." } ?? ""
            return Opened(container: container, notice: "Isolate could not open its library and started a new one.\(kept)")
        } catch {
            NSLog("Isolate: could not start a new library at \(url.path): \(error)")
            return Opened(container: inMemoryContainer(),
                          notice: "Isolate could not open its library at \(url.path). Changes made in this session will not be saved.")
        }
    }

    private static func persistentContainer(at url: URL) throws -> ModelContainer {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try ModelContainer(for: TrackModel.self, configurations: ModelConfiguration(url: url))
    }

    private static func inMemoryContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: TrackModel.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } catch {
            fatalError("Could not create an in-memory library: \(error)")
        }
    }

    private static func sidecars(of url: URL) -> [URL] {
        ["", "-wal", "-shm"].map { URL(fileURLWithPath: url.path + $0) }
    }

    /// Moves the store and its SQLite sidecars together; a leftover -wal next to
    /// a new store could be replayed into it, so this throws unless all moved.
    static func moveStoreAside(at url: URL, now: Date) throws -> URL? {
        let fm = FileManager.default
        let files = sidecars(of: url).filter { fm.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let backup = url.deletingLastPathComponent()
            .appending(path: "Library Backups/\(formatter.string(from: now))", directoryHint: .isDirectory)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for file in files.reversed() {
            try fm.moveItem(at: file, to: backup.appending(path: file.lastPathComponent))
        }
        guard !sidecars(of: url).contains(where: { fm.fileExists(atPath: $0.path) }) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return backup
    }

    /// Adds tracks from a library kept in the shared default.store. That store is
    /// never opened in place: SwiftData would migrate it to this schema and drop
    /// other apps' tables. Its files are copied, SQLite confirms the copy holds
    /// Isolate's table, and only then is the copy read. Throws only when copying
    /// fails, so the caller can retry on a later launch.
    static func importLegacyLibrary(from legacyURL: URL, into context: ModelContext,
                                    scratchDirectory: URL = FileManager.default.temporaryDirectory) throws -> LegacyImport {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyURL.path) else { return .noLegacyLibrary }
        let scratch = scratchDirectory.appending(path: "Isolate-Legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let copy = scratch.appending(path: "Legacy.store")
        for (source, destination) in zip(sidecars(of: legacyURL), sidecars(of: copy)) where fm.fileExists(atPath: source.path) {
            try fm.copyItem(at: source, to: destination)
        }
        guard containsTrackTable(copy) else { return .noLegacyLibrary }
        do {
            let added = try copyTracks(from: copy, into: context)
            return .imported(added)
        } catch {
            NSLog("Isolate: could not import the previous library: \(error)")
            return .failed("Isolate could not import its previous library; it was left unchanged at \(legacyURL.path).")
        }
    }

    private static func copyTracks(from store: URL, into context: ModelContext) throws -> Int {
        let legacy = try ModelContainer(for: TrackModel.self, configurations: ModelConfiguration(url: store))
        let rows = try ModelContext(legacy).fetch(FetchDescriptor<TrackModel>())
        var known = Set(try context.fetch(FetchDescriptor<TrackModel>()).map(\.id))
        var added = 0
        for row in rows where !known.contains(row.id) {
            context.insert(TrackModel(id: row.id, title: row.title, originalURL: row.originalURL, dateAdded: row.dateAdded,
                                      vocalStemURL: row.vocalStemURL, bassStemURL: row.bassStemURL,
                                      drumStemURL: row.drumStemURL, otherStemURL: row.otherStemURL))
            known.insert(row.id)
            added += 1
        }
        if added > 0 {
            do { try context.save() }
            catch { context.rollback(); throw error }
        }
        return added
    }

    /// True when the SQLite file has a TrackModel table with every stored field.
    static func containsTrackTable(_ url: URL) -> Bool {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(ZTRACKMODEL)", -1, &statement, nil) == SQLITE_OK else { return false }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { columns.insert(String(cString: name)) }
        }
        return ["ZID", "ZTITLE", "ZORIGINALURL", "ZDATEADDED", "ZVOCALSTEMURL",
                "ZBASSSTEMURL", "ZDRUMSTEMURL", "ZOTHERSTEMURL"].allSatisfy(columns.contains)
    }
}
