import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@MainActor
@Observable
final class ImportCoordinator {
    private(set) var isImporting = false
    private var task: Task<Void, Never>?
    private var openPanel: NSOpenPanel?
    static let extensions: Set<String> = ["mp3", "wav", "flac", "m4a", "aac", "aiff", "aif", "caf", "alac"]

    func chooseFiles(context: ModelContext, engine: AudioEngineManager) {
        guard !isImporting, !engine.isSplitting, openPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
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
        let audio = urls.filter { $0.isFileURL && Self.extensions.contains($0.pathExtension.lowercased()) }
        guard !audio.isEmpty else {
            engine.showError("Choose an MP3, WAV, FLAC, M4A, AAC, AIFF or CAF audio file.")
            return
        }
        isImporting = true
        task = Task {
            defer { isImporting = false; task = nil }
            var count = 0
            var lastTitle = ""
            for url in audio {
                guard !Task.isCancelled else { break }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let path = url.path
                do {
                    let descriptor = FetchDescriptor<TrackModel>(predicate: #Predicate { $0.id == path })
                    if let track = try context.fetch(descriptor).first {
                        // Reimport must inspect current bytes even when the source path is unchanged.
                        if let data = await engine.loadAndSplitAudio(url: url) {
                            track.vocalStemURL = data.vocalStemURL
                            track.drumStemURL = data.drumStemURL
                            track.bassStemURL = data.bassStemURL
                            track.otherStemURL = data.otherStemURL
                            do { try context.save() }
                            catch { context.rollback(); throw error }
                            engine.updateTrackTitle(id: track.id, newTitle: track.title)
                        }
                    } else if let data = await engine.loadAndSplitAudio(url: url) {
                        let track = TrackModel(id: data.id, title: data.title, originalURL: data.originalURL,
                            vocalStemURL: data.vocalStemURL, bassStemURL: data.bassStemURL,
                            drumStemURL: data.drumStemURL, otherStemURL: data.otherStemURL)
                        context.insert(track)
                        do { try context.save() }
                        catch { context.rollback(); throw error }
                        count += 1
                        lastTitle = track.title
                    }
                    if engine.lastImportCancelled { break }
                } catch {
                    engine.showError("Could not save the library: \(error.localizedDescription)")
                    break
                }
            }
            if count > 0, !NSApp.isActive {
                MenuBarManager.shared.sendBatchCompletionNotification(count: count, lastTitle: lastTitle)
            }
        }
    }

    func acceptDrop(_ providers: [NSItemProvider], context: ModelContext, engine: AudioEngineManager) -> Bool {
        guard !isImporting else { return false }
        Task {
            // Sequential collection preserves Finder order and avoids a shared-array data race.
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let data = item as? Data {
                            continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                        } else { continuation.resume(returning: item as? URL) }
                    }
                }
                if let url { urls.append(url) }
            }
            importFiles(urls, context: context, engine: engine)
        }
        return true
    }
}
