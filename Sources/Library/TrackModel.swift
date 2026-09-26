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

// MARK: - Library order and search

extension Array where Element == TrackModel {
    /// Sidebar grouping: source folders in path order, each keeping the input
    /// (newest-first) order. Next/Previous walk this same order.
    func libraryFolderGroups() -> [(folder: URL, tracks: [TrackModel])] {
        let groups = Dictionary(grouping: self) { $0.originalURL.deletingLastPathComponent() }
        return groups.keys.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { (folder: $0, tracks: groups[$0] ?? []) }
    }

    func libraryPlaybackOrder() -> [TrackModel] {
        libraryFolderGroups().flatMap(\.tracks)
    }

    /// Matches only what identifies a track to the user: its title, source file
    /// name and the folders below the path every track shares, so artist and
    /// album folders match (as group headers show them) but /Users/<name>/Music
    /// does not. Stem file names and shared path words are in every track, so
    /// matching them made common words return the whole library.
    func matchingLibrarySearch(_ text: String) -> [TrackModel] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return self }
        let tokens = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let folders: [[String]] = map { $0.originalURL.deletingLastPathComponent().pathComponents }
        var shared = folders.first?.count ?? 0
        for folder in folders.dropFirst() {
            shared = Swift.min(shared, zip(folders[0], folder).prefix { $0 == $1 }.count)
        }
        return zip(self, folders).filter { track, folder in
            // Always keep the track's own folder, even when it is the shared one.
            let names = folder.dropFirst(Swift.max(0, Swift.min(shared, folder.count - 1)))
            let searchable = ([track.title, track.originalURL.lastPathComponent] + names)
                .joined(separator: " ").lowercased()
            return searchable.contains(query) || (!tokens.isEmpty && tokens.allSatisfy { searchable.contains($0) })
        }.map { $0.0 }
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
        /// Where an unreadable library was moved, so later launches can still say so.
        var backup: URL? = nil
    }

    private static var startupNotice: String?
    /// True when no library file could be opened or created: nothing added in
    /// this session survives quitting.
    static private(set) var isInMemory = false
    static let inMemoryWarning = "Isolate could not save its library, so tracks added in this session will be gone after you quit."
    /// Backup folder of a library that was moved aside. Its notice is shown at
    /// every launch until the user closes it.
    static let recoveryBackupKey = "libraryRecoveryBackupPath"
    static let legacyImportAttemptsKey = "legacyImportAttempts"
    /// A legacy import that fails at this many launches is not tried again.
    static let maxLegacyImportAttempts = 3

    /// A message about library recovery for the main window to show once.
    static func takeStartupNotice() -> String? {
        defer { startupNotice = nil }
        return startupNotice
    }

    static func makeContainer() -> ModelContainer {
        guard !AppPreferences.isTesting else { return inMemoryContainer() }
        let defaults = AppPreferences.defaults
        let opened = open(at: storeURL)
        if let backup = opened.backup { defaults.set(backup.path, forKey: recoveryBackupKey) }
        startupNotice = opened.notice ?? pendingRecoveryNotice(defaults: defaults)
        isInMemory = !opened.container.configurations.contains { !$0.isStoredInMemoryOnly }
        if !isInMemory, let message = importLegacyLibraryIfNeeded(from: legacyStoreURL, into: opened.container.mainContext,
                                                                   defaults: defaults) {
            startupNotice = [startupNotice, message].compactMap { $0 }.joined(separator: " ")
        }
        return opened.container
    }

    /// Opens the store at `url`. Only a file SQLite itself finds damaged is
    /// retired: it is moved, never deleted, into a timestamped backup folder and
    /// a new library is started. Any other failure (no space, permissions, a
    /// lock, a newer schema) may pass at a later launch, so the file stays in
    /// place and the session runs in memory and says so.
    static func open(at url: URL, now: Date = .now,
                     create: (URL) throws -> ModelContainer = persistentContainer(at:)) -> Opened {
        do {
            return Opened(container: try create(url), notice: nil)
        } catch {
            NSLog("Isolate: could not open the library at \(url.path): \(error)")
        }
        let unsaved = "Isolate could not open its library at \(url.path). Changes made in this session will not be saved."
        guard isDamagedDatabase(url) else {
            let kept = FileManager.default.fileExists(atPath: url.path)
                ? " The library file was left unchanged; Isolate will try to open it again next launch." : ""
            return Opened(container: inMemoryContainer(), notice: unsaved + kept)
        }
        var backup: URL?
        do {
            backup = try moveStoreAside(at: url, now: now)
            let container = try create(url)
            let kept = backup.map { " The previous library was moved to \($0.path)." } ?? ""
            return Opened(container: container, notice: "Isolate could not open its library and started a new one.\(kept)",
                          backup: backup)
        } catch {
            NSLog("Isolate: could not start a new library at \(url.path): \(error)")
        }
        // Put the library back so the next launch tries it again instead of
        // quietly starting an empty one.
        guard let moved = backup, !restoreStore(from: moved, to: url) else {
            return Opened(container: inMemoryContainer(), notice: unsaved)
        }
        return Opened(container: inMemoryContainer(),
                      notice: unsaved + " The previous library was moved to \(moved.path).", backup: moved)
    }

    nonisolated static func persistentContainer(at url: URL) throws -> ModelContainer {
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

    /// True only when SQLite reports the file damaged or not a database at all.
    /// Opens it read-only; a missing or unreadable file is not damaged.
    nonisolated static func isDamagedDatabase(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        var code = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
        if code == SQLITE_OK { code = sqlite3_prepare_v2(db, "PRAGMA quick_check(1)", -1, &statement, nil) }
        if code == SQLITE_OK {
            code = sqlite3_step(statement)
            if code == SQLITE_ROW, let result = sqlite3_column_text(statement, 0) { return String(cString: result) != "ok" }
        }
        return code & 0xFF == SQLITE_CORRUPT || code & 0xFF == SQLITE_NOTADB
    }

    /// Moves every file or none: if one move fails, the files already moved go
    /// back, so a store is never separated from its -wal.
    private static func moveTogether(_ moves: [(from: URL, to: URL)]) throws {
        let fm = FileManager.default
        var done: [(from: URL, to: URL)] = []
        do {
            for move in moves {
                try fm.moveItem(at: move.from, to: move.to)
                done.append(move)
            }
        } catch {
            for move in done.reversed() { try? fm.moveItem(at: move.to, to: move.from) }
            throw error
        }
    }

    private static func removeIfEmpty(_ directory: URL) {
        if (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: directory)
        }
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
        do {
            try moveTogether(files.reversed().map { (from: $0, to: backup.appending(path: $0.lastPathComponent)) })
        } catch {
            removeIfEmpty(backup)
            throw error
        }
        guard !sidecars(of: url).contains(where: { fm.fileExists(atPath: $0.path) }) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return backup
    }

    /// Moves a library that was set aside back to `url`, replacing what a failed
    /// attempt to start a new one left there. True when it is back in place.
    static func restoreStore(from backup: URL, to url: URL) -> Bool {
        let fm = FileManager.default
        // Every original file is in `backup`; anything at `url` is new and empty.
        for file in sidecars(of: url) where fm.fileExists(atPath: file.path) {
            try? fm.removeItem(at: file)
        }
        let moves = sidecars(of: url).reversed()
            .map { (from: backup.appending(path: $0.lastPathComponent), to: $0) }
            .filter { fm.fileExists(atPath: $0.from.path) }
        do {
            try moveTogether(moves)
        } catch {
            NSLog("Isolate: could not put the library back from \(backup.path): \(error)")
            return false
        }
        removeIfEmpty(backup)
        removeIfEmpty(backup.deletingLastPathComponent())
        return true
    }

    /// The notice for a library moved aside at an earlier launch. It is shown
    /// at every launch until the user closes it or the backup folder is gone.
    static func pendingRecoveryNotice(defaults: UserDefaults) -> String? {
        guard let path = defaults.string(forKey: recoveryBackupKey) else { return nil }
        guard FileManager.default.fileExists(atPath: path) else {
            defaults.removeObject(forKey: recoveryBackupKey)
            return nil
        }
        return "Isolate could not open its library and started a new one. The previous library was moved to \(path)."
    }

    /// Closing the recovery notice is the acknowledgement that stops it. In an
    /// in-memory session the new, empty library only starts next launch, so the
    /// notice must still be shown then.
    static func noticeDismissed(_ message: String, defaults: UserDefaults = AppPreferences.defaults) {
        guard !isInMemory else { return }
        if let path = defaults.string(forKey: recoveryBackupKey), message.contains(path) {
            defaults.removeObject(forKey: recoveryBackupKey)
        }
    }

    /// Imports the pre-1.3 library once. A failure is reported and tried again
    /// at the next launches, up to `maxLegacyImportAttempts`, since a full disk
    /// or an unreadable file may be fixed by then.
    static func importLegacyLibraryIfNeeded(from legacyURL: URL, into context: ModelContext, defaults: UserDefaults,
                                            scratchDirectory: URL = FileManager.default.temporaryDirectory) -> String? {
        guard !defaults.bool(forKey: legacyImportKey) else { return nil }
        let result: LegacyImport
        do {
            result = try importLegacyLibrary(from: legacyURL, into: context, scratchDirectory: scratchDirectory)
        } catch {
            NSLog("Isolate: could not read the previous library: \(error)")
            result = .failed("Isolate could not read its previous library; it was left unchanged at \(legacyURL.path).")
        }
        guard case .failed(let message) = result else {
            defaults.set(true, forKey: legacyImportKey)
            defaults.removeObject(forKey: legacyImportAttemptsKey)
            return nil
        }
        let attempts = defaults.integer(forKey: legacyImportAttemptsKey) + 1
        guard attempts < maxLegacyImportAttempts else {
            defaults.set(true, forKey: legacyImportKey)
            defaults.removeObject(forKey: legacyImportAttemptsKey)
            return message
        }
        defaults.set(attempts, forKey: legacyImportAttemptsKey)
        return message + " Isolate will try again next launch."
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
