import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@main
struct IsolateApp: App {
    @State private var engineManager = AudioEngineManager()
    @State private var theme = ThemeManager.shared
    @State private var isTargeted = false
    @State private var isShowingAboutModal = false
    @State private var isShowingSettingsModal = false
    @Environment(\.modelContext) private var modelContext
    
    init() {
        // Pre-warm CoreML Demucs Neural Engine pipeline in the background on startup
        Task.detached(priority: .userInitiated) {
            await DemucsEngine.shared.prewarmModel()
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(
                isShowingAboutModal: $isShowingAboutModal,
                isShowingSettingsModal: $isShowingSettingsModal
            )
            .ignoresSafeArea()
            .overlay {
                if engineManager.isSplitting {
                    SplittingProgressModal()
                        .environment(engineManager)
                } else if isTargeted {
                    // Drag & Drop Target Overlay
                    ZStack {
                        theme.modalBackdrop
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.red, style: StrokeStyle(lineWidth: 4, dash: [10]))
                            .padding(24)
                        VStack(spacing: 20) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 64))
                            .foregroundColor(.red)
                            Text("DROP AUDIO TO ISOLATE STEMS")
                                .font(.custom("DotGothic16-Regular", size: 32))
                                .foregroundColor(.red)
                        }
                    }
                    .ignoresSafeArea()
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                var droppedURLs: [URL] = []
                let dispatchGroup = DispatchGroup()
                for provider in providers {
                    dispatchGroup.enter()
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        defer { dispatchGroup.leave() }
                        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                            droppedURLs.append(url)
                        } else if let url = item as? URL {
                            droppedURLs.append(url)
                        }
                    }
                }
                dispatchGroup.notify(queue: .main) {
                    if !droppedURLs.isEmpty {
                        handleDroppedFiles(urls: droppedURLs)
                    }
                }
                return true
            }
            .preferredColorScheme(theme.preferredColorScheme)
            .frame(minWidth: 960, minHeight: 580)
            .background(WindowAccessor())
            .navigationTitle("")
            .environment(engineManager)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Isolate") {
                    isShowingAboutModal = true
                }
            }
            CommandGroup(after: .appSettings) {
                Button("Settings...") {
                    isShowingSettingsModal = true
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
        .modelContainer(for: TrackModel.self)
        .environment(engineManager)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
    
    private func handleDroppedFiles(urls: [URL]) {
        let validAudioExtensions = ["mp3", "wav", "flac", "m4a", "aac", "aiff", "aif", "caf"]
        let audioURLs = urls.filter { validAudioExtensions.contains($0.pathExtension.lowercased()) }
        guard !audioURLs.isEmpty else { return }
        
        Task {
            var processedCount = 0
            var lastTitle = ""
            for url in audioURLs {
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
                    processedCount += 1
                    lastTitle = existing.title
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
                        processedCount += 1
                        lastTitle = data.title
                    }
                }
            }
            if processedCount > 0 {
                await MainActor.run {
                    MenuBarManager.shared.sendBatchCompletionNotification(count: processedCount, lastTitle: lastTitle)
                }
            }
        }
    }
}

// MARK: - Splitting Progress Modal with Cancel Import Action
struct SplittingProgressModal: View {
    @Environment(AudioEngineManager.self) private var engineManager
    @State private var theme = ThemeManager.shared
    @State private var isCancelHovered = false
    @State private var currentHeadlineIndex = 0
    @State private var currentFooterIndex = 0
    @State private var isBlinking = false
    @State private var rotationTimer: Timer? = nil
    @State private var blinkTimer: Timer? = nil
    
    private var dynamicHeadline: String {
        let progress = engineManager.splitProgress
        if progress <= 0.005 {
            return "INITIALIZING NEURAL ENGINE..."
        } else if progress >= 0.98 {
            return "RECOMBINING STEM MATRIX..."
        } else if progress < 0.35 {
            let earlyPool = [
                "HUNTING DOWN THE 808 SUB BASS...",
                "DE-BLEEDING DRUM TRANSIENTS...",
                "SEPARATING SINE WAVES FROM SOUL...",
                "ISOLATING THE GHOST IN THE MACHINE..."
            ]
            return earlyPool[currentHeadlineIndex % earlyPool.count]
        } else if progress < 0.75 {
            let midPool = [
                "SURGICALLY EXTRACTING VOCALS...",
                "UNTANGLING HARMONIC RESONANCE...",
                "CONSULTING THE NEURAL ENGINE ORACLE...",
                "PURGING BACKGROUND BLEED..."
            ]
            return midPool[currentHeadlineIndex % midPool.count]
        } else {
            let latePool = [
                "POLISHING ISOLATED ARTIFACTS...",
                "FILTERING RESIDUAL PHANTOM FREQUENCIES...",
                "ALMOST AT 100% PURITY..."
            ]
            return latePool[currentHeadlineIndex % latePool.count]
        }
    }
    
    private var dynamicFooter: String {
        let telemetryPool = [
            "APPLE SILICON NEURAL ENGINE ACCELERATED",
            "DEMUCS V4 COREML • FP16 QUANTIZED",
            "44.1KHZ 16-BIT STEREO PRECISION MATRIX",
            "HYBRID TRANSFORMER LATENCY 0.38X REALTIME",
            "4-STEM ISOLATION • DUAL-CHANNEL DSP"
        ]
        return telemetryPool[currentFooterIndex % telemetryPool.count]
    }
    
    var body: some View {
        ZStack {
            theme.modalBackdrop
            
            VStack(spacing: 24) {
                // Header Status: Rotating Nothing-Themed Quirky Headlines (0ms Snap)
                Text(dynamicHeadline)
                    .font(.custom("DotGothic16-Regular", size: 22))
                    .foregroundColor(theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 32)
                
                // Discrete LED Hardware Progress Bar
                ModalDotMatrixProgressBar(progress: engineManager.splitProgress)
                    .frame(width: 480, height: 10)
                
                // Metrics Readout
                HStack(spacing: 48) {
                    VStack(alignment: .center, spacing: 4) {
                        Text("PROGRESS")
                            .font(.custom("DotGothic16-Regular", size: 12))
                            .foregroundColor(theme.textSecondary)
                        Text("\(Int(engineManager.splitProgress * 100))%")
                            .font(.custom("DotGothic16-Regular", size: 22))
                            .foregroundColor(.red)
                    }
                    
                    if engineManager.totalChunkCount > 0 {
                        VStack(alignment: .center, spacing: 4) {
                            Text("CHUNKS")
                                .font(.custom("DotGothic16-Regular", size: 12))
                                .foregroundColor(theme.textSecondary)
                            Text("\(engineManager.currentChunkNumber)/\(engineManager.totalChunkCount)")
                                .font(.custom("DotGothic16-Regular", size: 22))
                                .foregroundColor(theme.textPrimary)
                        }
                    }
                    
                    VStack(alignment: .center, spacing: 4) {
                        Text("ESTIMATED TIME")
                            .font(.custom("DotGothic16-Regular", size: 12))
                            .foregroundColor(theme.textSecondary)
                        Text(engineManager.etaRemainingString)
                            .font(.custom("DotGothic16-Regular", size: 22))
                            .foregroundColor(theme.textPrimary)
                    }
                }
                
                // Footer Status: Dynamic Hardware Telemetry with Pulsing REC LED
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                        .opacity(isBlinking ? 1.0 : 0.2)
                    
                    Text(engineManager.currentChunkNumber > 0 ? engineManager.liveSpeedSubtitle : dynamicFooter)
                        .font(.custom("DotGothic16-Regular", size: 12))
                        .foregroundColor(theme.textSecondary)
                        .lineLimit(1)
                }
                .frame(minHeight: 20)
                
                // Prominent Bottom Nothing-Style Cancel Action Button
                Button(action: {
                    Haptics.playClick()
                    engineManager.cancelSplitAudio()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                        Text(engineManager.splitStatusMessage.contains("CANCEL") ? "CANCELLING..." : "CANCEL IMPORT")
                            .font(.custom("DotGothic16-Regular", size: 13))
                            .fontWeight(.bold)
                    }
                    .foregroundColor(isCancelHovered ? .black : .red)
                    .frame(width: 170, height: 36)
                    .background(isCancelHovered ? Color.red : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(isCancelHovered ? Color.red : Color.red.opacity(0.8), lineWidth: 1)
                    )
                    .contentShape(Rectangle()) // Entire 170x36 area clickable!
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .onHover { hovering in
                    if hovering && !isCancelHovered { Haptics.playClick() }
                    isCancelHovered = hovering
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 36)
            .frame(width: 580)
            .background(theme.modalBackground)
            .border(theme.cardBorder, width: 1)
            .overlay(CornerBrackets())
        }
        .ignoresSafeArea()
        .onAppear {
            rotationTimer?.invalidate()
            rotationTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                Haptics.playAlignment()
                currentHeadlineIndex += 1
                currentFooterIndex += 1
            }
            
            blinkTimer?.invalidate()
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
                isBlinking.toggle()
            }
        }
        .onDisappear {
            rotationTimer?.invalidate()
            rotationTimer = nil
            blinkTimer?.invalidate()
            blinkTimer = nil
        }
    }
}

struct ModalDotMatrixProgressBar: View {
    let progress: Double
    @State private var theme = ThemeManager.shared
    
    var body: some View {
        GeometryReader { geo in
            let blockWidth: CGFloat = 8.0
            let blockSpacing: CGFloat = 4.0
            let totalUnitWidth = blockWidth + blockSpacing
            let blockCount = max(1, Int(geo.size.width / totalUnitWidth))
            let activeCount = Int(round(Double(blockCount) * max(0, min(1, progress))))
            
            HStack(spacing: blockSpacing) {
                ForEach(0..<blockCount, id: \.self) { i in
                    Rectangle()
                        .fill(i < activeCount ? Color.red : theme.knobArcTrack)
                        .frame(width: blockWidth, height: 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

struct ContentView: View {
    @Binding var isShowingAboutModal: Bool
    @Binding var isShowingSettingsModal: Bool
    @State private var theme = ThemeManager.shared
    @State private var isSidebarVisible = true
    @State private var trackToRename: TrackModel? = nil
    @State private var trackToDelete: TrackModel? = nil
    @State private var isShowingRenameModal = false
    @State private var isShowingDeleteModal = false
    @State private var renameText = ""
    @State private var activeMenuTrackID: String? = nil
    @Environment(\.modelContext) private var modelContext
    @Environment(AudioEngineManager.self) private var engineManager
    @Query(sort: \TrackModel.dateAdded, order: .reverse) private var tracks: [TrackModel]
    
    var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                LibraryView(
                    activeMenuTrackID: $activeMenuTrackID,
                    onRenameTrack: { track in
                        activeMenuTrackID = nil
                        trackToRename = track
                        renameText = track.title
                        isShowingRenameModal = true
                    },
                    onDeleteTrack: { track in
                        activeMenuTrackID = nil
                        trackToDelete = track
                        isShowingDeleteModal = true
                    },
                    onOpenSettings: {
                        activeMenuTrackID = nil
                        isShowingSettingsModal = true
                    }
                )
                .frame(width: 270)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .transition(.identity) // 0ms Instant Nothing Hardware Snap
                
                Divider()
                    .background(theme.hairline)
            }
            
            PlayerView(isSidebarVisible: $isSidebarVisible)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    // Tap anywhere in PlayerView to dismiss active 3-dots library menu
                    if activeMenuTrackID != nil {
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                activeMenuTrackID = nil
                            }
                    }
                }
        }
        .background(theme.background)
        .background {
            // Global ⌘, Keyboard Shortcut for Settings
            Button("") {
                isShowingSettingsModal.toggle()
            }
            .keyboardShortcut(",", modifiers: [.command])
            .hidden()
            
            // Global ⌘B Keyboard Shortcut for Sidebar Toggle
            Button("") {
                Haptics.playClick()
                withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                    isSidebarVisible.toggle()
                }
            }
            .keyboardShortcut("b", modifiers: [.command])
            .hidden()
        }
        .overlay {
            // MARK: - Window-Centered Nothing-Style Rename Modal
            if isShowingRenameModal, let track = trackToRename {
                ZStack {
                    theme.modalBackdrop
                        .ignoresSafeArea()
                        .onTapGesture {
                            isShowingRenameModal = false
                        }
                    
                    RenameModalCard(
                        trackTitle: track.title,
                        renameText: $renameText,
                        onCancel: {
                            isShowingRenameModal = false
                        },
                        onSave: { newTitle in
                            let oldTitle = track.title
                            let trackID = track.id
                            track.title = newTitle
                            try? modelContext.save()
                            if engineManager.currentTrackID == trackID ||
                               engineManager.currentTrackName == oldTitle.uppercased() ||
                               engineManager.currentTrackName == newTitle.uppercased() ||
                               engineManager.currentTrackName.contains(oldTitle.uppercased()) {
                                engineManager.currentTrackName = newTitle.uppercased()
                            }
                            engineManager.updateTrackTitle(id: trackID, newTitle: newTitle)
                            isShowingRenameModal = false
                        }
                    )
                }
            } else if isShowingDeleteModal, let track = trackToDelete {
                // MARK: - Window-Centered Nothing-Style Delete Confirmation Modal
                ZStack {
                    theme.modalBackdrop
                        .ignoresSafeArea()
                        .onTapGesture {
                            isShowingDeleteModal = false
                        }
                    
                    DeleteModalCard(
                        trackTitle: track.title,
                        onCancel: {
                            isShowingDeleteModal = false
                        },
                        onDelete: {
                            let trackID = track.id
                            let wasActive = (engineManager.currentTrackID == trackID)
                            
                            let stemDir = track.vocalStemURL.deletingLastPathComponent()
                            try? FileManager.default.removeItem(at: stemDir)
                            try? FileManager.default.removeItem(at: track.vocalStemURL)
                            try? FileManager.default.removeItem(at: track.drumStemURL)
                            try? FileManager.default.removeItem(at: track.bassStemURL)
                            try? FileManager.default.removeItem(at: track.otherStemURL)
                            
                            modelContext.delete(track)
                            try? modelContext.save()
                            
                            if wasActive {
                                engineManager.unloadTrack()
                            }
                            isShowingDeleteModal = false
                        }
                    )
                }
            } else if isShowingSettingsModal {
                // MARK: - Window-Centered Nothing Hardware Settings & Shortcuts Modal
                ZStack {
                    theme.modalBackdrop
                        .ignoresSafeArea()
                        .onTapGesture {
                            isShowingSettingsModal = false
                        }
                    
                    SettingsModalCard(
                        onDismiss: {
                            isShowingSettingsModal = false
                        }
                    )
                }
            } else if isShowingAboutModal {
                // MARK: - Window-Centered Nothing Hardware About Modal
                ZStack {
                    theme.modalBackdrop
                        .ignoresSafeArea()
                        .onTapGesture {
                            isShowingAboutModal = false
                        }
                    
                    AboutModalCard(
                        onDismiss: {
                            isShowingAboutModal = false
                        }
                    )
                }
            } else if AppMoveHelper.shared.shouldShowMoveModal && !engineManager.isSplitting {
                // MARK: - Window-Centered Move to Applications Prompt
                ZStack {
                    theme.modalBackdrop
                        .ignoresSafeArea()
                        .onTapGesture {
                            UserDefaults.standard.set(true, forKey: "hasDeclinedMoveToApplications")
                            AppMoveHelper.shared.shouldShowMoveModal = false
                        }
                    
                    MoveToApplicationsModalCard(
                        appMoveHelper: AppMoveHelper.shared,
                        onDismiss: {
                            UserDefaults.standard.set(true, forKey: "hasDeclinedMoveToApplications")
                            AppMoveHelper.shared.shouldShowMoveModal = false
                        }
                    )
                }
            }
            
            // MARK: - Floating Nothing Hardware Error Toast
            if let errorMsg = engineManager.errorMessage {
                VStack {
                    ErrorToastCard(
                        message: errorMsg,
                        onDismiss: {
                            engineManager.dismissError()
                        }
                    )
                    .padding(.top, 16)
                    .allowsHitTesting(true)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
                .zIndex(9999)
            }
        }
        .onAppear {
            AppMoveHelper.shared.checkLocationOnStartup()
            NowPlayingManager.shared.configure(
                engineManager: engineManager,
                playlistProvider: { tracks },
                trackSelectHandler: { track in
                    Task {
                        await engineManager.loadTrack(track)
                        if !engineManager.isPlaying {
                            engineManager.togglePlayback()
                        }
                    }
                }
            )
            MenuBarManager.shared.configure(
                engineManager: engineManager,
                playlistProvider: { tracks },
                trackSelectHandler: { track in
                    Task {
                        await engineManager.loadTrack(track)
                        if !engineManager.isPlaying {
                            engineManager.togglePlayback()
                        }
                    }
                }
            )
        }
        .onChange(of: tracks) { _, newTracks in
            NowPlayingManager.shared.configure(
                engineManager: engineManager,
                playlistProvider: { newTracks },
                trackSelectHandler: { track in
                    Task {
                        await engineManager.loadTrack(track)
                        if !engineManager.isPlaying {
                            engineManager.togglePlayback()
                        }
                    }
                }
            )
            MenuBarManager.shared.configure(
                engineManager: engineManager,
                playlistProvider: { newTracks },
                trackSelectHandler: { track in
                    Task {
                        await engineManager.loadTrack(track)
                        if !engineManager.isPlaying {
                            engineManager.togglePlayback()
                        }
                    }
                }
            )
        }
    }
}

// MARK: - Nothing Hardware About Isolate Modal Card
struct AboutModalCard: View {
    let onDismiss: () -> Void
    @State private var theme = ThemeManager.shared
    @State private var isCloseHovered = false
    @State private var isGitHubHovered = false
    
    var body: some View {
        VStack(spacing: 18) {
            // Nothing Dot-Matrix App Icon Graphic
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(theme.knobFace)
                    .frame(width: 84, height: 84)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )
                
                // Stacked Square Pixel Stem Bars (White/Charcoal, Red, Red, White/Charcoal)
                HStack(alignment: .bottom, spacing: 5) {
                    VStack(spacing: 2) {
                        ForEach(0..<5, id: \.self) { _ in
                            Rectangle().fill(theme.spectrumBarDefault).frame(width: 6, height: 4)
                        }
                    }
                    VStack(spacing: 2) {
                        ForEach(0..<8, id: \.self) { _ in
                            Rectangle().fill(Color.red).frame(width: 6, height: 4)
                        }
                    }
                    VStack(spacing: 2) {
                        ForEach(0..<10, id: \.self) { _ in
                            Rectangle().fill(Color.red).frame(width: 6, height: 4)
                        }
                    }
                    VStack(spacing: 2) {
                        ForEach(0..<6, id: \.self) { _ in
                            Rectangle().fill(theme.spectrumBarDefault).frame(width: 6, height: 4)
                        }
                    }
                }
                .padding(.bottom, 16)
                .frame(width: 84, height: 84, alignment: .bottom)
                
                // Top-right Red Glowing Status Dot
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .padding(8)
            }
            .shadow(color: Color.red.opacity(0.25), radius: 12)
            
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text("ISOLATE")
                        .font(.custom("DotGothic16-Regular", size: 24))
                        .fontWeight(.bold)
                        .foregroundColor(theme.textPrimary)
                    
                    Text("v1.0.0")
                        .font(.custom("DotGothic16-Regular", size: 13))
                        .foregroundColor(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.red.opacity(0.4), lineWidth: 1)
                        )
                }
                
                Text("4-STEM DEMUCS NEURAL ENGINE ACCELERATOR")
                    .font(.custom("DotGothic16-Regular", size: 11))
                    .foregroundColor(theme.textSecondary)
                    .tracking(0.5)
            }
            
            Divider()
                .background(theme.hairline)
                .padding(.horizontal, 8)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 5, height: 5)
                    Text("APPLE SILICON NEURAL ENGINE (ANE) ACCELERATION")
                        .font(.custom("DotGothic16-Regular", size: 11))
                        .foregroundColor(theme.textPrimary.opacity(0.85))
                }
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 5, height: 5)
                    Text("60 FPS METAL & ACCELERATE DSP TELEMETRY")
                        .font(.custom("DotGothic16-Regular", size: 11))
                        .foregroundColor(theme.textPrimary.opacity(0.85))
                }
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 5, height: 5)
                    Text("100% PRIVATE & OFFLINE AUDIO PROCESSING")
                        .font(.custom("DotGothic16-Regular", size: 11))
                        .foregroundColor(theme.textPrimary.opacity(0.85))
                }
            }
            .padding(.horizontal, 12)
            
            HStack(spacing: 12) {
                // GitHub Repository Link
                Button(action: {
                    Haptics.playClick()
                    if let url = URL(string: "https://github.com/neokumar1/Isolate") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 11, weight: .bold))
                        Text("GITHUB")
                            .font(.custom("DotGothic16-Regular", size: 13))
                            .fontWeight(.bold)
                    }
                    .foregroundColor(isGitHubHovered ? theme.textPrimary : theme.textSecondary)
                    .frame(width: 140, height: 36)
                    .background(isGitHubHovered ? theme.surfaceHover : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(isGitHubHovered ? theme.textPrimary : theme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering && !isGitHubHovered { Haptics.playClick() }
                    isGitHubHovered = hovering
                }
                
                // Close Button
                Button(action: {
                    Haptics.playClick()
                    onDismiss()
                }) {
                    Text("CLOSE")
                        .font(.custom("DotGothic16-Regular", size: 13))
                        .fontWeight(.bold)
                        .foregroundColor(.black)
                        .frame(width: 120, height: 36)
                        .background(isCloseHovered ? Color.white : Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering && !isCloseHovered { Haptics.playClick() }
                    isCloseHovered = hovering
                }
            }
            .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 440)
        .background(theme.modalBackground)
        .compositingGroup()
        .border(theme.cardBorder, width: 1)
        .overlay(CornerBrackets())
        .shadow(color: Color.black.opacity(theme.isDark ? 0.9 : 0.2), radius: 24, x: 0, y: 8)
    }
}

// MARK: - Move to Applications Modal Card
struct MoveToApplicationsModalCard: View {
    @ObservedObject var appMoveHelper: AppMoveHelper
    let onDismiss: () -> Void
    @State private var theme = ThemeManager.shared
    
    @State private var isInstallHovered = false
    @State private var isSkipHovered = false
    
    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.app")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.red)
                Text("MOVE TO APPLICATIONS?")
                    .font(.custom("DotGothic16-Regular", size: 20))
                    .foregroundColor(theme.textPrimary)
            }
            
            Text("Isolate works best when installed in your Applications folder.\nWould you like to move it now and eject the installer?")
                .font(.custom("DotGothic16-Regular", size: 13))
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            
            if let error = appMoveHelper.moveErrorMessage {
                Text(error)
                    .font(.custom("DotGothic16-Regular", size: 11))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
            
            HStack(spacing: 16) {
                // Skip Button
                Button(action: {
                    Haptics.playClick()
                    onDismiss()
                }) {
                    Text("NOT NOW")
                        .font(.custom("DotGothic16-Regular", size: 13))
                        .fontWeight(.bold)
                        .foregroundColor(isSkipHovered ? theme.textPrimary : theme.textSecondary)
                        .frame(width: 120, height: 36)
                        .background(isSkipHovered ? theme.surfaceHover : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(isSkipHovered ? theme.textPrimary : theme.border, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .onHover { hovering in
                    if hovering && !isSkipHovered { Haptics.playClick() }
                    isSkipHovered = hovering
                }
                
                // Move Button
                Button(action: {
                    Haptics.playClick()
                    appMoveHelper.moveToApplications()
                }) {
                    HStack(spacing: 6) {
                        if appMoveHelper.isMoving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        Text(appMoveHelper.isMoving ? "INSTALLING..." : "MOVE & RELAUNCH")
                            .font(.custom("DotGothic16-Regular", size: 13))
                            .fontWeight(.bold)
                    }
                    .foregroundColor(isInstallHovered ? .black : .white)
                    .frame(width: 180, height: 36)
                    .background(isInstallHovered ? Color.white : Color.red)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.red, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(appMoveHelper.isMoving)
                .onHover { hovering in
                    if hovering && !isInstallHovered { Haptics.playClick() }
                    isInstallHovered = hovering
                }
            }
        }
        .padding(32)
        .frame(width: 440)
        .background(theme.modalBackground)
        .border(theme.cardBorder, width: 1)
        .overlay(CornerBrackets())
    }
}

// MARK: - Window-Centered Rename Modal Card
struct RenameModalCard: View {
    let trackTitle: String
    @Binding var renameText: String
    let onCancel: () -> Void
    let onSave: (String) -> Void
    @State private var theme = ThemeManager.shared
    
    @State private var isCancelHovered = false
    @State private var isSaveHovered = false
    
    var body: some View {
        VStack(spacing: 22) {
            Text("RENAME TRACK")
                .font(.custom("DotGothic16-Regular", size: 20))
                .foregroundColor(theme.textPrimary)
            
            TextField("Track Title", text: $renameText)
                .font(.custom("DotGothic16-Regular", size: 15))
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.red, lineWidth: 1))
                .foregroundColor(theme.textPrimary)
            
            HStack(spacing: 16) {
                // Cancel Button
                Button(action: {
                    Haptics.playClick()
                    onCancel()
                }) {
                    Text("CANCEL")
                        .font(.custom("DotGothic16-Regular", size: 13))
                        .fontWeight(.bold)
                        .foregroundColor(isCancelHovered ? theme.textPrimary : theme.textSecondary)
                        .frame(width: 110, height: 34)
                        .background(isCancelHovered ? theme.surfaceHover : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(isCancelHovered ? theme.textPrimary : theme.border, lineWidth: 1))
                        .contentShape(Rectangle()) // Entire 110x34 area clickable!
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .onHover { hovering in
                    if hovering && !isCancelHovered { Haptics.playClick() }
                    isCancelHovered = hovering
                }
                
                // Save Button
                Button(action: {
                    Haptics.playClick()
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onSave(trimmed)
                    } else {
                        onCancel()
                    }
                }) {
                    Text("SAVE")
                        .font(.custom("DotGothic16-Regular", size: 13))
                        .fontWeight(.bold)
                        .foregroundColor(.black)
                        .frame(width: 110, height: 34)
                        .background(isSaveHovered ? Color.red.opacity(0.85) : Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .contentShape(Rectangle()) // Entire 110x34 area clickable!
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .onHover { hovering in
                    if hovering && !isSaveHovered { Haptics.playClick() }
                    isSaveHovered = hovering
                }
            }
        }
        .padding(32)
        .frame(width: 420)
        .background(theme.modalBackground)
        .border(theme.cardBorder, width: 1)
        .overlay(CornerBrackets())
        .shadow(color: Color.black.opacity(theme.isDark ? 0.9 : 0.15), radius: 12, x: 0, y: 6)
    }
}

// MARK: - Window-Centered Delete Modal Card
struct DeleteModalCard: View {
    let trackTitle: String
    let onCancel: () -> Void
    let onDelete: () -> Void
    @State private var theme = ThemeManager.shared
    
    @State private var isCancelHovered = false
    @State private var isDeleteHovered = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("DELETE TRACK?")
                .font(.custom("DotGothic16-Regular", size: 22))
                .foregroundColor(.red)
            
            Text("Are you sure you want to delete '\(trackTitle)' and its isolated stems?")
                .font(.custom("DotGothic16-Regular", size: 14))
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            
            HStack(spacing: 16) {
                // Cancel Button
                Button(action: {
                    Haptics.playClick()
                    onCancel()
                }) {
                    Text("CANCEL")
                        .font(.custom("DotGothic16-Regular", size: 13))
                        .fontWeight(.bold)
                        .foregroundColor(isCancelHovered ? theme.textPrimary : theme.textSecondary)
                        .frame(width: 110, height: 34)
                        .background(isCancelHovered ? theme.surfaceHover : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(isCancelHovered ? theme.textPrimary : theme.border, lineWidth: 1))
                        .contentShape(Rectangle()) // Entire 110x34 area clickable!
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .onHover { hovering in
                    if hovering && !isCancelHovered { Haptics.playClick() }
                    isCancelHovered = hovering
                }
                
                // Delete Button
                Button(action: {
                    Haptics.playClick()
                    onDelete()
                }) {
                    Text("DELETE")
                        .font(.custom("DotGothic16-Regular", size: 13))
                        .fontWeight(.bold)
                        .foregroundColor(.black)
                        .frame(width: 110, height: 34)
                        .background(isDeleteHovered ? Color.red.opacity(0.85) : Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .contentShape(Rectangle()) // Entire 110x34 area clickable!
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering && !isDeleteHovered { Haptics.playClick() }
                    isDeleteHovered = hovering
                }
            }
        }
        .padding(32)
        .frame(width: 420)
        .background(theme.modalBackground)
        .border(theme.cardBorder, width: 1)
        .overlay(CornerBrackets())
        .shadow(color: Color.black.opacity(theme.isDark ? 0.9 : 0.15), radius: 12, x: 0, y: 6)
    }
}

// MARK: - Window Accessor
struct WindowAccessor: NSViewRepresentable {
    final class Coordinator: NSObject {
        weak var window: NSWindow?
        
        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            
            NotificationCenter.default.removeObserver(self)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidEnterFullScreen),
                name: NSWindow.didEnterFullScreenNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidExitFullScreen),
                name: NSWindow.didExitFullScreenNotification,
                object: window
            )
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
        
        @objc private func windowDidEnterFullScreen() {
            window?.toolbar?.isVisible = false
        }
        
        @objc private func windowDidExitFullScreen() {
            window?.toolbar?.isVisible = true
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                applyWindowStyling(to: window, context: context)
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            applyWindowStyling(to: window, context: context)
        }
    }
    
    private func applyWindowStyling(to window: NSWindow, context: Context) {
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = false
        let isDark = ThemeManager.shared.isDark
        window.backgroundColor = isDark ? .black : NSColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1.0)
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.minSize = NSSize(width: 960, height: 580)
        window.isMovableByWindowBackground = false
        
        if window.toolbar == nil {
            let toolbar = NSToolbar(identifier: "IsolateMainWindowToolbar")
            toolbar.displayMode = .iconOnly
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified
        }
        
        context.coordinator.attach(to: window)
        
        if window.styleMask.contains(.fullScreen) {
            window.toolbar?.isVisible = false
        }
    }
}

// MARK: - Floating Nothing Hardware Error Toast Card
struct ErrorToastCard: View {
    let message: String
    let onDismiss: () -> Void
    @State private var theme = ThemeManager.shared
    @State private var isCloseHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.red)
                
                Text(message)
                    .font(.custom("DotGothic16-Regular", size: 12))
                    .fontWeight(.bold)
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(1)
            }
            
            Button(action: {
                Haptics.playClick()
                onDismiss()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(isCloseHovered ? theme.textPrimary : theme.textSecondary)
                    .padding(5)
                    .background(isCloseHovered ? theme.surfaceHover : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isCloseHovered = hovering
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.modalBackground)
        .compositingGroup()
        .border(Color.red.opacity(0.8), width: 1)
        .overlay(CornerBrackets())
        .shadow(color: Color.red.opacity(0.3), radius: 14, x: 0, y: 4)
    }
}
