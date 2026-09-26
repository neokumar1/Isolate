import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@MainActor
@Observable
final class ImportCoordinator {
    private(set) var isImporting = false
    /// The file being separated and its 1-based position in the batch; nil between batches.
    private(set) var currentFileName: String?
    private(set) var batchIndex = 0
    private(set) var batchCount = 0
    private var task: Task<Void, Never>?
    private var openPanel: NSOpenPanel?
    nonisolated static let extensions: Set<String> = ["mp3", "wav", "flac", "m4a", "aac", "aiff", "aif", "aifc", "caf"]

    func chooseFiles(context: ModelContext, engine: AudioEngineManager) {
        guard !isImporting, !engine.isSplitting, openPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        openPanel = panel
        // Avoid a nested run loop inside SwiftUI's onChange transaction.
        panel.begin { [weak self] response in
            Task { @MainActor in
                self?.openPanel = nil
                if response == .OK { self?.importFiles(panel.urls, context: context, engine: engine) }
            }
        }
    }

    func importFiles(_ urls: [URL], context: ModelContext, engine: AudioEngineManager) {
        guard !isImporting, !engine.isSplitting else { return }
        isImporting = true
        task = Task {
            defer {
                isImporting = false
                task = nil
                currentFileName = nil
                batchIndex = 0
                batchCount = 0
            }
            // Listing a large dropped folder must not block the main actor.
            let audio = await Task.detached {
                let files = Self.audioFiles(in: urls)
                // Let iCloud Drive fetch queued files while earlier ones separate.
                for url in files where StreamingAudio.isCloudPlaceholder(url) {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                }
                return files
            }.value
            guard !audio.isEmpty else {
                engine.showError("Choose MP3, WAV, FLAC, M4A, AAC, AIFF or CAF audio files, or a folder that contains them.")
                return
            }
            batchCount = audio.count
            var count = 0
            var lastTitle = ""
            var failures: [(name: String, reason: String)] = []
            var notImported = 0
            var saveError: Error?
            for (index, url) in audio.enumerated() {
                guard !Task.isCancelled else { break }
                batchIndex = index + 1
                currentFileName = Self.title(for: url)
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let path = url.path
                // Each failure is collected for one summary instead of replacing the last toast.
                engine.dismissError()
                do {
                    let descriptor = FetchDescriptor<TrackModel>(predicate: #Predicate { $0.id == path })
                    let imported: Bool
                    if let track = try context.fetch(descriptor).first {
                        let previousStems = track.vocalStemURL.deletingLastPathComponent()
                        // Reimport must inspect current bytes even when the source path is unchanged.
                        if let data = await engine.loadAndSplitAudio(url: url) {
                            track.vocalStemURL = data.vocalStemURL
                            track.drumStemURL = data.drumStemURL
                            track.bassStemURL = data.bassStemURL
                            track.otherStemURL = data.otherStemURL
                            do { try context.save() }
                            catch { context.rollback(); throw error }
                            engine.updateTrackTitle(id: track.id, newTitle: track.title)
                            if !engine.isExporting { Self.removeReplacedCache(previousStems, context: context) }
                            imported = true
                        } else { imported = false }
                    } else if let data = await engine.loadAndSplitAudio(url: url) {
                        let track = TrackModel(id: data.id, title: Self.title(for: url), originalURL: data.originalURL,
                            vocalStemURL: data.vocalStemURL, bassStemURL: data.bassStemURL,
                            drumStemURL: data.drumStemURL, otherStemURL: data.otherStemURL)
                        context.insert(track)
                        do { try context.save() }
                        catch { context.rollback(); throw error }
                        // Keep Now Playing on the library title rather than switching to tag metadata.
                        engine.updateTrackTitle(id: track.id, newTitle: track.title)
                        count += 1
                        lastTitle = track.title
                        imported = true
                    } else { imported = false }
                    if engine.lastImportCancelled {
                        notImported = audio.count - index - 1
                        break
                    }
                    if !imported {
                        failures.append((url.lastPathComponent, Self.reason(from: engine.errorMessage)))
                    }
                } catch {
                    saveError = error
                    break
                }
            }
            if count > 0, !NSApp.isActive {
                MenuBarManager.shared.sendBatchCompletionNotification(count: count, lastTitle: lastTitle)
            }
            if let saveError {
                engine.showError("Could not save the library: \(saveError.localizedDescription)")
            } else if let summary = Self.summary(failures: failures, total: audio.count, notImported: notImported) {
                engine.showError(summary)
            }
        }
    }

    func acceptDrop(_ providers: [NSItemProvider], context: ModelContext, engine: AudioEngineManager) -> Bool {
        guard !isImporting, !engine.isSplitting, openPanel == nil else { return false }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        // Reserve the import slot before loading asynchronous item providers.
        // Otherwise a second drop is accepted and discarded once the first starts.
        isImporting = true
        Task {
            // Sequential collection preserves Finder order and avoids a shared-array data race.
            var urls: [URL] = []
            for provider in fileProviders {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let data = item as? Data {
                            continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                        } else { continuation.resume(returning: item as? URL) }
                    }
                }
                if let url { urls.append(url) }
            }
            isImporting = false
            importFiles(urls, context: context, engine: engine)
        }
        return true
    }

    /// Supported audio files in the given order; folders contribute their audio
    /// files recursively in Finder name order. A file listed twice is imported once.
    nonisolated static func audioFiles(in urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var files: [URL] = []
        func add(_ url: URL) {
            if extensions.contains(url.pathExtension.lowercased()), seen.insert(url.standardizedFileURL.path).inserted {
                files.append(url)
            }
        }
        for url in urls where url.isFileURL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values?.isDirectory == true, values?.isPackage != true else {
                add(url)
                continue
            }
            let contents = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])
            let found = (contents?.allObjects.compactMap { $0 as? URL } ?? [])
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            found.forEach(add)
        }
        return files
    }

    /// Finder's name without the extension, so "AC/DC" is not shown as "AC:DC".
    nonisolated static func title(for url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        // Finder omits the extension from displayName only when it is hidden.
        let suffix = "." + url.pathExtension
        guard !url.pathExtension.isEmpty, name.lowercased().hasSuffix(suffix.lowercased()) else { return name }
        return String(name.dropLast(suffix.count))
    }

    /// Deletes a stem folder that a reimport replaced, unless a track still uses it.
    static func removeReplacedCache(_ directory: URL, context: ModelContext) {
        let path = directory.standardizedFileURL.path
        guard StemCache.owns(directory), FileManager.default.fileExists(atPath: path),
              let tracks = try? context.fetch(FetchDescriptor<TrackModel>()),
              !tracks.contains(where: { $0.vocalStemURL.deletingLastPathComponent().standardizedFileURL.path == path })
        else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func reason(from message: String?) -> String {
        guard let message, !message.isEmpty else { return "The import did not finish." }
        let prefix = "Import failed: "
        return message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message
    }

    /// One message naming every failed file, so earlier failures are not lost.
    static func summary(failures: [(name: String, reason: String)], total: Int, notImported: Int) -> String? {
        var parts: [String] = []
        if total == 1, let failure = failures.first {
            parts.append("Could not import '\(failure.name)': \(failure.reason)")
        } else if !failures.isEmpty {
            let listed = failures.prefix(3).map { "'\($0.name)': \($0.reason)" }
            let more = failures.count > 3 ? " (+\(failures.count - 3) more)" : ""
            parts.append("\(failures.count) of \(total) files could not be imported. " + listed.joined(separator: " ") + more)
        }
        if notImported > 0 {
            parts.append("Import cancelled; \(notImported) remaining \(notImported == 1 ? "file was" : "files were") not imported.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
