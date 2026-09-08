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
        onOpenSettings: (() -> Void)? = nil
    ) {
        self._activeMenuTrackID = activeMenuTrackID
        self.onRenameTrack = onRenameTrack
        self.onDeleteTrack = onDeleteTrack
        self.onOpenSettings = onOpenSettings
    }
    
    var totalOriginalBytes: Int64 {
        tracks.reduce(0) { total, track in
            let size = (try? FileManager.default.attributesOfItem(atPath: track.originalURL.path)[.size] as? Int64) ?? 0
            return total + size
        }
    }
    
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
        Task.detached(priority: .userInitiated) {
            var totalSecs: Double = 0.0
            for pair in urlPairs {
                if let file = try? AVAudioFile(forReading: pair.vocal) {
                    totalSecs += Double(file.length) / file.processingFormat.sampleRate
                } else if let file = try? AVAudioFile(forReading: pair.original) {
                    totalSecs += Double(file.length) / file.processingFormat.sampleRate
                }
            }
            let finalSecs = totalSecs
            await MainActor.run {
                self.totalDurationSeconds = finalSecs
            }
        }
    }
    
    @State private var theme = ThemeManager.shared
    @State private var searchText = ""
    
    private var filteredTracks: [TrackModel] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return tracks }
        
        // If searching generic stem terms, all tracks have 4 isolated stems
        if trimmed == "stem" || trimmed == "stems" || trimmed == "all" {
            return tracks
        }
        
        let queryTokens = trimmed
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        
        guard !queryTokens.isEmpty else { return tracks }
        
        return tracks.filter { track in
            let titleLower = track.title.lowercased()
            let filenameLower = track.originalURL.lastPathComponent.lowercased()
            let pathLower = track.originalURL.path.lowercased()
            let extLower = track.originalURL.pathExtension.lowercased()
            let vocalLower = track.vocalStemURL.lastPathComponent.lowercased()
            let drumLower = track.drumStemURL.lastPathComponent.lowercased()
            let bassLower = track.bassStemURL.lastPathComponent.lowercased()
            let otherLower = track.otherStemURL.lastPathComponent.lowercased()
            
            let combined = "\(titleLower) \(filenameLower) \(pathLower) \(extLower) \(vocalLower) \(drumLower) \(bassLower) \(otherLower)"
            
            // Direct substring match
            if combined.contains(trimmed) { return true }
            
            // Multi-token match across words/delimiters
            return queryTokens.allSatisfy { token in
                combined.contains(token)
            }
        }
    }
    
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
                .foregroundColor(.red)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 50)
        .padding(.bottom, 6)
    }
    
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(isSearchFocused ? .red : theme.textSecondary)
            
            TextField("SEARCH STEMS...", text: $searchText)
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
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSearchFocused ? theme.surfaceHover : theme.surfaceSecondary)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(isSearchFocused ? Color.red.opacity(0.8) : theme.cardBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            isSearchFocused = true
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
    
    @ViewBuilder
    private var trackListView: some View {
        if tracks.isEmpty {
            emptyStateView
        } else if filteredTracks.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text("NO MATCHING TRACKS")
                    .font(.custom("DotGothic16-Regular", size: 12))
                    .foregroundColor(.gray)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            tracksScrollView
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 32))
                .foregroundColor(.gray.opacity(0.5))
            Text("NO TRACKS IMPORTED")
                .font(.custom("DotGothic16-Regular", size: 13))
                .foregroundColor(.gray)
            Text("Drag & drop audio files here")
                .font(.custom("DotGothic16-Regular", size: 11))
                .foregroundColor(.gray.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
    
    private var tracksScrollView: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(Array(filteredTracks.enumerated()), id: \.element.id) { index, track in
                    let isCurrentMenuOpen = activeMenuTrackID == track.id
                    let zIndexValue: Double = isCurrentMenuOpen ? 1000.0 : Double(filteredTracks.count - index)
                    TrackRowView(
                        track: track,
                        isActive: engineManager.currentTrackID == track.id || engineManager.currentTrackName == track.title.uppercased(),
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
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(CustomScrollerModifier())
        }
        .onAppear {
            recalculateTotalDuration()
        }
        .onChange(of: tracks.count) { _, _ in
            recalculateTotalDuration()
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
    
    private var telemetryView: some View {
        HStack(spacing: 4) {
            Text("\(tracks.count) \(tracks.count == 1 ? "TRACK" : "TRACKS")")
                .font(.custom("DotGothic16-Regular", size: 10.5))
                .foregroundColor(theme.textSecondary)
            
            if totalOriginalBytes > 0 {
                Text("•")
                    .font(.custom("DotGothic16-Regular", size: 9))
                    .foregroundColor(.red)
                
                Text(formattedTotalSize)
                    .font(.custom("DotGothic16-Regular", size: 10.5))
                    .foregroundColor(theme.textSecondary)
            }
            
            if totalDurationSeconds > 0 {
                Text("•")
                    .font(.custom("DotGothic16-Regular", size: 9))
                    .foregroundColor(.red)
                
                Text(formattedTotalDuration)
                    .font(.custom("DotGothic16-Regular", size: 10.5))
                    .foregroundColor(theme.textSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
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
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .audio,
            .mp3,
            .mpeg4Audio,
            .wav,
            .aiff,
            UTType(filenameExtension: "flac") ?? .audio,
            UTType(filenameExtension: "alac") ?? .audio,
            UTType(filenameExtension: "aac") ?? .audio,
            UTType(filenameExtension: "caf") ?? .audio
        ]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        
        if panel.runModal() == .OK {
            let selectedURLs = panel.urls
            guard !selectedURLs.isEmpty else { return }
            
            Task {
                for url in selectedURLs {
                    let isSecScoped = url.startAccessingSecurityScopedResource()
                    defer {
                        if isSecScoped {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    
                    let path = url.path
                    let descriptor = FetchDescriptor<TrackModel>(predicate: #Predicate { $0.id == path })
                    if let existing = try? modelContext.fetch(descriptor).first {
                        await engineManager.loadTrack(existing)
                    } else {
                        if let data = await engineManager.loadAndSplitAudio(url: url) {
                            await MainActor.run {
                                let newTrack = TrackModel(
                                    id: data.id,
                                    title: data.title,
                                    originalURL: data.originalURL,
                                    vocalStemURL: data.vocalStemURL,
                                    bassStemURL: data.bassStemURL,
                                    drumStemURL: data.drumStemURL,
                                    otherStemURL: data.otherStemURL
                                )
                                modelContext.insert(newTrack)
                                try? modelContext.save()
                            }
                        }
                    }
                }
            }
        }
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
        if isMenuOpen {
            return Color.red
        } else if isHovered {
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
            
            if isMenuOpen {
                inlineActionsView
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            isMenuOpen
                ? theme.surfaceSecondary
                : (isActive ? Color.red.opacity(0.12) : (isHovered ? theme.surfaceHover : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(
                    isMenuOpen || isActive
                        ? Color.red.opacity(0.8)
                        : (isHovered ? theme.cardBorder : Color.clear),
                    lineWidth: 1
                )
        )
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
                    .foregroundColor(isActive ? .red : theme.textPrimary)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    Text(track.dateAdded, style: .date)
                        .font(.custom("DotGothic16-Regular", size: 11))
                        .foregroundColor(theme.textSecondary)
                    
                    if isActive {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 4, height: 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            .background(isMenuOpen ? Color.red.opacity(0.18) : (isHovered ? theme.surfaceHover : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isMenuOpen ? Color.red : (isHovered ? theme.border : Color.clear), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                .foregroundColor(isDeleteHovered ? .black : .red)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(isDeleteHovered ? Color.red : Color.red.opacity(0.18))
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
        }
    }
}

// MARK: - Native AppKit Nothing OS Hardware Red LED Scroller
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
        
        // Crisp rectangular Nothing Hardware Red LED (0px corner radius)
        context.addRect(thumbRect)
        context.setFillColor(CGColor(red: 1.0, green: 0.15, blue: 0.15, alpha: 0.95))
        context.setShadow(offset: .zero, blur: 4.0, color: CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.6))
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
