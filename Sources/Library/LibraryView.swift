import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit
import AVFoundation

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AudioEngineManager.self) private var engineManager
    @Query(sort: \TrackModel.dateAdded, order: .reverse) private var tracks: [TrackModel]
    
    @Binding var activeMenuTrackID: String?
    var onRenameTrack: ((TrackModel) -> Void)? = nil
    var onDeleteTrack: ((TrackModel) -> Void)? = nil
    var onImport: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    
    @State private var isSettingsHovered = false
    @FocusState private var isSearchFocused: Bool
    
    // Custom Nothing Scrollbar State
    @State private var containerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var isScrolling = false
    @State private var isScrollbarHovered = false
    @State private var isDraggingScrollbar = false
    @State private var scrollFadeTimer: Timer? = nil
    
    // Telemetry Duration State
    @State private var totalDurationSeconds: Double = 0.0
    
    public init(
        activeMenuTrackID: Binding<String?> = .constant(nil),
        onRenameTrack: ((TrackModel) -> Void)? = nil,
        onDeleteTrack: ((TrackModel) -> Void)? = nil,
        onImport: (() -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self._activeMenuTrackID = activeMenuTrackID
        self.onRenameTrack = onRenameTrack
        self.onDeleteTrack = onDeleteTrack
        self.onImport = onImport
        self.onOpenSettings = onOpenSettings
    }
    
    @State private var totalOriginalBytes: Int64 = 0
    @State private var statisticsTask: Task<Void, Never>?

    var formattedTotalSize: String {
        let bytes = totalOriginalBytes
        let mb = Double(bytes) / 1_000_000.0
        if mb >= 1000.0 {
            let gb = Double(bytes) / 1_000_000_000.0
            return String(format: "%.2f GB", gb)
        } else {
            return String(format: "%.1f MB", mb)
        }
    }
    
    var formattedTotalDuration: String {
        let totalMins = Int(round(totalDurationSeconds / 60.0))
        if totalMins < 60 {
            return "\(max(1, totalMins)) MIN"
        } else {
            let hours = totalMins / 60
            let mins = totalMins % 60
            return "\(hours)H \(mins)M"
        }
    }
    
    private func triggerScrollActivity() {
        isScrolling = true
        scrollFadeTimer?.invalidate()
        scrollFadeTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { _ in
            Task { @MainActor in
                isScrolling = false
            }
        }
    }
    
    private func recalculateTotalDuration() {
        let urlPairs: [(vocal: URL, original: URL)] = tracks.map { ($0.vocalStemURL, $0.originalURL) }
        statisticsTask?.cancel()
        guard !urlPairs.isEmpty else {
            totalDurationSeconds = 0
            totalOriginalBytes = 0
            return
        }
        statisticsTask = Task {
            let calculation = Task.detached(priority: .utility) {
                var totalBytes: Int64 = 0
                var totalSecs: Double = 0.0
                for pair in urlPairs {
                    guard !Task.isCancelled else { break }
                    totalBytes += (try? FileManager.default.attributesOfItem(atPath: pair.original.path)[.size] as? Int64) ?? 0
                    if let file = try? AVAudioFile(forReading: pair.vocal) {
                        totalSecs += Double(file.length) / file.processingFormat.sampleRate
                    } else if let file = try? AVAudioFile(forReading: pair.original) {
                        totalSecs += Double(file.length) / file.processingFormat.sampleRate
                    }
                }
                return (totalSecs, totalBytes)
            }
            let statistics = await withTaskCancellationHandler {
                await calculation.value
            } onCancel: {
                calculation.cancel()
            }
            guard !Task.isCancelled else { return }
            totalDurationSeconds = statistics.0
            totalOriginalBytes = statistics.1
        }
    }
    
    @State private var theme = ThemeManager.shared
    @State private var searchText = ""
    
    /// Group headers: the folder name, extended with parent folders only where
    /// two different folders share a name (e.g. ARTIST A / GREATEST HITS).
    /// Built from every track so headers stay stable while searching.
    /// One pass per depth: each suffix is counted in a dictionary rather than compared
    /// against every other folder, so a large library stays linear in its folders.
    static func folderLabels(for folders: [URL]) -> [URL: String] {
        let unique = Array(Set(folders))
        let components = unique.map(\.pathComponents)
        var labels: [URL: String] = [:]
        var pending = Array(unique.indices)
        var count = 1
        while !pending.isEmpty {
            let keys = components.map { $0.suffix(count).joined(separator: " / ").lowercased() }
            var tally: [String: Int] = [:]
            for key in keys { tally[key, default: 0] += 1 }
            var colliding: [Int] = []
            for index in pending {
                if count < components[index].count, tally[keys[index], default: 0] > 1 {
                    colliding.append(index)
                } else {
                    labels[unique[index]] = components[index].suffix(count).joined(separator: " / ")
                }
            }
            pending = colliding
            count += 1
        }
        return labels
    }

    /// Folder labels from the last body update, rebuilt only when the library's set of
    /// folders changes rather than on every search keystroke or hover.
    @State private var folderLabelCache = FolderLabelCache()

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                headerView
                
                if !tracks.isEmpty {
                    searchBar
                }
                
                Divider()
                    .background(theme.hairline)
                
                trackListView
                
                Divider()
                    .background(theme.hairline)
                
                footerView
            }
            .background(theme.surface)
        }
        .onAppear { recalculateTotalDuration() }
        .onDisappear { statisticsTask?.cancel() }
        .onChange(of: tracks.map(\.id)) { _, _ in
            recalculateTotalDuration()
        }
        // A search can hide the row whose inline menu is open; close it rather
        // than leave its invisible click catcher over the player.
        .onChange(of: searchText) { _, _ in
            activeMenuTrackID = nil
        }
    }
    
    private var headerView: some View {
        HStack {
            Text("LIBRARY")
                .font(.custom("DotGothic16-Regular", size: 14))
                .foregroundColor(theme.textSecondary)
            
            Spacer()
            
            Button(action: {
                Haptics.playClick()
                isSearchFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
                importTrack()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle")
                    Text("IMPORT TRACK")
                }
                .font(.custom("DotGothic16-Regular", size: 14))
                .foregroundColor(theme.textPrimary)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(engineManager.isSplitting)
        }
        .padding(.horizontal, 16)
        .padding(.top, 50)
        .padding(.bottom, 6)
    }
    
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(isSearchFocused ? theme.textPrimary : theme.textSecondary)
            
            TextField("SEARCH LIBRARY...", text: $searchText)
                .accessibilityLabel("Search library")
                .textFieldStyle(.plain)
                .font(.custom("DotGothic16-Regular", size: 11.5))
                .foregroundColor(theme.textPrimary)
                .focused($isSearchFocused)
                .onSubmit {
                    isSearchFocused = false
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
                .onExitCommand {
                    if !searchText.isEmpty {
                        searchText = ""
                    } else {
                        isSearchFocused = false
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                }
            
            if !searchText.isEmpty {
                Button(action: {
                    Haptics.playClick()
                    searchText = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear library search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSearchFocused ? theme.surfaceHover : theme.surfaceSecondary)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(isSearchFocused ? theme.textPrimary : theme.cardBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            activeMenuTrackID = nil
            isSearchFocused = true
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
    
    @ViewBuilder
    private var trackListView: some View {
        // Filter once per update; rows reuse the result instead of re-filtering.
        let filtered = tracks.matchingLibrarySearch(searchText)
        if tracks.isEmpty {
            emptyStateView
        } else if filtered.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text("NO MATCHING TRACKS")
                    .font(.custom("DotGothic16-Regular", size: 12))
                    .foregroundColor(theme.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            tracksScrollView(filtered)
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 32))
                .foregroundColor(theme.textMuted)
            Text("NO TRACKS IMPORTED")
                .font(.custom("DotGothic16-Regular", size: 13))
                .foregroundColor(theme.textSecondary)
            Text("Drag & drop audio files here")
                .font(.custom("DotGothic16-Regular", size: 11))
                .foregroundColor(theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
    
    private func tracksScrollView(_ filtered: [TrackModel]) -> some View {
        let total = filtered.count
        let labels = folderLabelCache.labels(for: tracks.map { $0.originalURL.deletingLastPathComponent() })
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(filtered.libraryFolderGroups(), id: \.folder) { group in
                    Text((labels[group.folder] ?? group.folder.lastPathComponent).uppercased())
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .padding(.top, 12)
                        .padding(.horizontal, 8)
                        .help(group.folder.path)
                ForEach(Array(group.tracks.enumerated()), id: \.element.id) { index, track in
                    let isCurrentMenuOpen = activeMenuTrackID == track.id
                    let zIndexValue: Double = isCurrentMenuOpen ? 1000.0 : Double(total - index)
                    TrackRowView(
                        track: track,
                        isActive: engineManager.currentTrackID == track.id,
                        isMenuOpen: isCurrentMenuOpen,
                        onToggleMenu: {
                            if activeMenuTrackID == track.id {
                                activeMenuTrackID = nil
                            } else {
                                activeMenuTrackID = track.id
                            }
                        },
                        onSelect: {
                            isSearchFocused = false
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            activeMenuTrackID = nil
                            guard !engineManager.isSplitting else { return }
                            Task {
                                await engineManager.loadTrack(track)
                            }
                        },
                        onRename: {
                            isSearchFocused = false
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            activeMenuTrackID = nil
                            onRenameTrack?(track)
                        },
                        onDelete: {
                            isSearchFocused = false
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            activeMenuTrackID = nil
                            onDeleteTrack?(track)
                        }
                    )
                    .zIndex(zIndexValue)
                }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(CustomScrollerModifier())
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isSearchFocused = false
            NSApp.keyWindow?.makeFirstResponder(nil)
            if activeMenuTrackID != nil {
                activeMenuTrackID = nil
            }
        }
    }
    
    private var footerView: some View {
        HStack(spacing: 4) {
            telemetryView
            
            Spacer(minLength: 4)
            
            settingsButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.surface)
    }
    
    private var librarySummary: String {
        var parts = ["\(tracks.count) \(tracks.count == 1 ? "track" : "tracks")"]
        if totalOriginalBytes > 0 { parts.append(formattedTotalSize) }
        if totalDurationSeconds > 0 { parts.append(formattedTotalDuration) }
        return parts.joined(separator: ", ")
    }

    private var telemetryView: some View {
        HStack(spacing: 4) {
            Text("\(tracks.count) \(tracks.count == 1 ? "TRACK" : "TRACKS")")
                .font(.custom("DotGothic16-Regular", size: 10.5))
                .foregroundColor(theme.textSecondary)
            
            if totalOriginalBytes > 0 {
                Text("•")
                    .font(.custom("DotGothic16-Regular", size: 9))
                    .foregroundColor(theme.textMuted)
                
                Text(formattedTotalSize)
                    .font(.custom("DotGothic16-Regular", size: 10.5))
                    .foregroundColor(theme.textSecondary)
            }
            
            if totalDurationSeconds > 0 {
                Text("•")
                    .font(.custom("DotGothic16-Regular", size: 9))
                    .foregroundColor(theme.textMuted)
                
                Text(formattedTotalDuration)
                    .font(.custom("DotGothic16-Regular", size: 10.5))
                    .foregroundColor(theme.textSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("library-summary")
        .accessibilityLabel(librarySummary)
    }
    
    private var settingsButton: some View {
        Button(action: {
            Haptics.playClick()
            onOpenSettings?()
        }) {
            HStack(spacing: 4) {
                Image(systemName: "gearshape")
                    .font(.system(size: 10, weight: .bold))
                Text("SETTINGS")
                    .font(.custom("DotGothic16-Regular", size: 11))
                    .fontWeight(.bold)
            }
            .foregroundColor(isSettingsHovered ? theme.textPrimary : theme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(isSettingsHovered ? theme.surfaceHover : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isSettingsHovered ? theme.textPrimary : theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering && !isSettingsHovered { Haptics.playClick() }
            isSettingsHovered = hovering
        }
    }
    
    private func importTrack() {
        onImport?()
    }

}

/// Remembers `LibraryView.folderLabels` for the last set of folders. It is not
/// observable, so reading it never invalidates the view.
@MainActor
final class FolderLabelCache {
    private var folders: Set<URL>?
    private var labels: [URL: String] = [:]
    private(set) var buildCount = 0

    func labels(for folders: [URL]) -> [URL: String] {
        let current = Set(folders)
        if current != self.folders {
            self.folders = current
            labels = LibraryView.folderLabels(for: Array(current))
            buildCount += 1
        }
        return labels
    }
}

struct TrackRowView: View {
    let track: TrackModel
    let isActive: Bool
    let isMenuOpen: Bool
    let onToggleMenu: () -> Void
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    
    @State private var theme = ThemeManager.shared
    @State private var isHovered = false
    @State private var isRenameHovered = false
    @State private var isDeleteHovered = false
    
    private var dotColor: Color {
        if isMenuOpen || isHovered {
            return theme.textPrimary
        } else {
            return theme.textSecondary
        }
    }
    
    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                trackButton
                dotsMenuButton
            }
            .opacity(isMenuOpen ? 0.0 : 1.0)
            .allowsHitTesting(!isMenuOpen)
            .accessibilityHidden(isMenuOpen)
            
            if isMenuOpen {
                inlineActionsView
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            isMenuOpen || isActive
                ? theme.surfaceSecondary
                : (isHovered ? theme.surfaceHover : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(
                    isMenuOpen || isActive
                        ? theme.border
                        : (isHovered ? theme.cardBorder : Color.clear),
                    lineWidth: 1
                )
        )
        // The loaded track's indicator bar is the row's only red.
        .overlay(alignment: .leading) {
            if isActive && !isMenuOpen {
                Rectangle()
                    .fill(theme.accentRed)
                    .frame(width: 3)
                    .padding(.vertical, 4)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if !isMenuOpen {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button("Rename Track") {
                Haptics.playClick()
                onRename()
            }
            Button("Delete Track", role: .destructive) {
                Haptics.playClick()
                onDelete()
            }
        }
    }
    
    private var trackButton: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.custom("DotGothic16-Regular", size: 15))
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(1)
                
                Text(track.dateAdded, style: .date)
                    .font(.custom("DotGothic16-Regular", size: 11))
                    .foregroundColor(theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Load \(track.title)")
        .accessibilityValue(isActive ? "Selected" : "")
    }
    
    private var dotsMenuButton: some View {
        Button(action: {
            Haptics.playClick()
            onToggleMenu()
        }) {
            HStack(spacing: 2.5) {
                Circle().fill(dotColor).frame(width: 3, height: 3)
                Circle().fill(dotColor).frame(width: 3, height: 3)
                Circle().fill(dotColor).frame(width: 3, height: 3)
            }
            .frame(width: 24, height: 24)
            .background(isMenuOpen || isHovered ? theme.surfaceHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isMenuOpen ? theme.textPrimary : (isHovered ? theme.border : Color.clear), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Actions for \(track.title)")
    }
    
    private var inlineActionsView: some View {
        HStack(spacing: 6) {
            Button(action: {
                Haptics.playClick()
                onRename()
            }) {
                HStack(spacing: 4) {
                    Text("[ RENAME ]")
                        .font(.custom("DotGothic16-Regular", size: 12))
                        .fontWeight(.bold)
                }
                .foregroundColor(isRenameHovered ? theme.surface : theme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(isRenameHovered ? theme.textPrimary : theme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering && !isRenameHovered { Haptics.playClick() }
                isRenameHovered = hovering
            }
            
            Button(action: {
                Haptics.playClick()
                onDelete()
            }) {
                HStack(spacing: 4) {
                    Text("[ DELETE ]")
                        .font(.custom("DotGothic16-Regular", size: 12))
                        .fontWeight(.bold)
                }
                .foregroundColor(isDeleteHovered ? theme.onAccent : theme.accentRed)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(isDeleteHovered ? theme.accentRed : theme.accentRed.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering && !isDeleteHovered { Haptics.playClick() }
                isDeleteHovered = hovering
            }
            
            Spacer()
            
            Button(action: {
                Haptics.playClick()
                onToggleMenu()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(theme.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close track actions")
        }
    }
}

// MARK: - Native AppKit Nothing OS Hardware Scroller
public final class NothingScroller: NSScroller {
    public override class var isCompatibleWithOverlayScrollers: Bool {
        return true
    }
    
    public override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        return 10.0
    }
    
    public override func drawKnobSlot(in rect: NSRect, highlight flag: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        
        let trackWidth: CGFloat = 2.0
        let trackRect = CGRect(
            x: rect.midX - (trackWidth / 2.0),
            y: rect.minY + 4.0,
            width: trackWidth,
            height: max(0, rect.height - 8.0)
        )
        
        context.addRect(trackRect)
        let isDark = ThemeManager.shared.isDark
        context.setFillColor(isDark ? CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.08) : CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.08))
        context.fillPath()
        
        context.restoreGState()
    }
    
    public override func drawKnob() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        
        let knobRect = rect(for: .knob)
        guard knobRect.height > 0 else {
            context.restoreGState()
            return
        }
        
        let thumbWidth: CGFloat = 3.5
        let thumbHeight = max(24.0, knobRect.height - 4.0)
        let thumbY = knobRect.minY + 2.0
        let thumbRect = CGRect(
            x: knobRect.midX - (thumbWidth / 2.0),
            y: thumbY,
            width: thumbWidth,
            height: thumbHeight
        )
        
        // Crisp rectangular thumb (0px corner radius); neutral, since scrolling
        // is not an interrupt state.
        context.addRect(thumbRect)
        let isDark = ThemeManager.shared.isDark
        context.setFillColor(isDark ? CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.55) : CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.45))
        context.fillPath()
        
        context.restoreGState()
    }
}

// MARK: - Enclosing NSScrollView Swapper
struct CustomScrollerModifier: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            setupScroller(for: view)
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            setupScroller(for: nsView)
        }
    }
    
    private func setupScroller(for view: NSView) {
        guard let scrollView = view.enclosingScrollView else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true
        if !(scrollView.verticalScroller is NothingScroller) {
            let customScroller = NothingScroller()
            scrollView.verticalScroller = customScroller
        }
    }
}
