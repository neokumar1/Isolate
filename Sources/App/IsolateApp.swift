import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@main
struct IsolateApp: App {
    @NSApplicationDelegateAdaptor(IsolateAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var engineManager = AudioEngineManager()
    @State private var theme = ThemeManager.shared
    @State private var isShowingAboutModal = false
    @State private var isShowingSettingsModal = false
    private let libraryContainer: ModelContainer

    init() {
        // One logical main window: without this, the tab bar's "+" opens more.
        NSWindow.allowsAutomaticWindowTabbing = false
        libraryContainer = LibraryStore.makeContainer()
    }

    var body: some Scene {
        WindowGroup("Isolate", id: "main", for: String.self) { _ in
            ContentView(isShowingAboutModal: $isShowingAboutModal,
                        isShowingSettingsModal: $isShowingSettingsModal)
                .ignoresSafeArea()
                .preferredColorScheme(theme.preferredColorScheme)
                .frame(minWidth: 960, minHeight: 580)
                .background(WindowAccessor())
                .environment(engineManager)
                .onAppear {
                    appDelegate.engineManager = engineManager
                    // The status menu has no SwiftUI environment; hand it the
                    // scene's action so it can reopen a closed window.
                    MenuBarManager.shared.openMainWindow = { openWindow(id: "main", value: "main") }
                }
        } defaultValue: {
            "main"
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Isolate") {
                    isShowingSettingsModal = false
                    isShowingAboutModal = true
                    openWindow(id: "main", value: "main")
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    isShowingAboutModal = false
                    isShowingSettingsModal = true
                    openWindow(id: "main", value: "main")
                }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Import Audio…") {
                    isShowingAboutModal = false
                    isShowingSettingsModal = false
                    engineManager.importRequested = true
                    openWindow(id: "main", value: "main")
                }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(engineManager.isSplitting)
                Button("Export Stems…") { engineManager.exportStems() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!engineManager.hasLoadedTrack || engineManager.isSplitting || engineManager.isExporting)
                Button("Export Mix…") { engineManager.exportMix() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(!engineManager.hasLoadedTrack || engineManager.isSplitting || engineManager.isExporting)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Show Isolate") { openWindow(id: "main", value: "main") }
                    .keyboardShortcut("0", modifiers: .command)
            }
            CommandMenu("Playback") {
                Button(engineManager.isPlaying ? "Pause" : "Play") { engineManager.togglePlayback() }
                    .disabled(!engineManager.hasLoadedTrack || engineManager.isSplitting)
                Button("Compare Original") { engineManager.isBypassed.toggle() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                    .disabled(!engineManager.canBypass || engineManager.isSplitting)
            }
        }
        .modelContainer(libraryContainer)
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)

    }
}

/// Asks before quitting while work that cannot resume is running.
@MainActor
final class IsolateAppDelegate: NSObject, NSApplicationDelegate {
    weak var engineManager: AudioEngineManager?

    enum PendingWork: Equatable {
        case separation
        case export
    }

    /// A finished export only shows COMPLETED briefly and needs no confirmation.
    static func pendingWork(isSplitting: Bool, exportState: ExportState) -> PendingWork? {
        if isSplitting { return .separation }
        if case .exporting = exportState { return .export }
        return nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine = engineManager,
              let work = Self.pendingWork(isSplitting: engine.isSplitting, exportState: engine.exportState) else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch work {
        case .separation:
            alert.messageText = "Quit while a track is being separated?"
            alert.informativeText = "Quitting cancels the import, and its separation progress is lost."
            alert.addButton(withTitle: "Keep Separating")
            alert.addButton(withTitle: "Cancel Import & Quit")
        case .export:
            alert.messageText = "Quit while an export is running?"
            alert.informativeText = "The export stops and its file is not saved."
            alert.addButton(withTitle: "Keep Exporting")
            alert.addButton(withTitle: "Quit")
        }
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        guard work == .separation else { return .terminateNow }
        // Quit once the cancelled separation has removed its temporary files.
        engine.cancelSplitAudio()
        Task { @MainActor in
            let deadline = ContinuousClock.now + .seconds(15)
            while engine.isSplitting && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct SplittingProgressModal: View {
    /// True while About or Settings is drawn on top. Escape then closes that
    /// card and must never reach CANCEL IMPORT underneath.
    var isCovered = false
    @Environment(AudioEngineManager.self) private var engineManager
    @State private var theme = ThemeManager.shared

    static func cancelShortcut(isCovered: Bool) -> KeyboardShortcut? {
        isCovered ? nil : .cancelAction
    }

    var body: some View {
        ZStack {
            theme.modalBackdrop
            VStack(spacing: 24) {
                Text(engineManager.splitStatusMessage)
                    .font(.custom("DotGothic16-Regular", size: 22))
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)
                ModalDotMatrixProgressBar(progress: engineManager.splitProgress)
                    .frame(height: 10)
                    .accessibilityLabel("Separation progress")
                    .accessibilityValue("\(Int(engineManager.splitProgress * 100)) percent")
                HStack {
                    Text("\(Int(engineManager.splitProgress * 100))%")
                    Spacer()
                    if engineManager.totalChunkCount > 0 {
                        Text("\(engineManager.currentChunkNumber) / \(engineManager.totalChunkCount) CHUNKS")
                    }
                    Spacer()
                    Text(engineManager.etaRemainingString)
                }
                .font(.custom("DotGothic16-Regular", size: 16))
                .foregroundStyle(theme.textPrimary)
                Text(engineManager.liveSpeedSubtitle)
                    .font(.custom("DotGothic16-Regular", size: 12))
                    .foregroundStyle(theme.textSecondary)
                Button(engineManager.lastImportCancelled ? "CANCELLING…" : "CANCEL IMPORT") {
                    engineManager.cancelSplitAudio()
                }
                .keyboardShortcut(Self.cancelShortcut(isCovered: isCovered))
                .disabled(engineManager.lastImportCancelled || isCovered)
                .tint(.red)
            }
            .padding(36)
            .frame(width: 580)
            .background(theme.modalBackground)
            .border(theme.cardBorder)
            .overlay(CornerBrackets())
        }
        .ignoresSafeArea()
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
    @State private var importer = ImportCoordinator()
    @ObservedObject private var appMoveHelper = AppMoveHelper.shared
    @State private var isTargeted = false
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
                    onImport: { importer.chooseFiles(context: modelContext, engine: engineManager) },
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
                    if isSidebarVisible && activeMenuTrackID != nil {
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                activeMenuTrackID = nil
                            }
                    }
                }
        }
        .disabled(engineManager.isSplitting || isShowingDeleteModal || isShowingSettingsModal || isShowingAboutModal)
        .background(theme.background)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            importer.acceptDrop(providers, context: modelContext, engine: engineManager)
        }
        .onChange(of: engineManager.importRequested, initial: true) { _, requested in
            if requested {
                engineManager.importRequested = false
                activeMenuTrackID = nil
                isShowingRenameModal = false
                isShowingDeleteModal = false
                isShowingSettingsModal = false
                isShowingAboutModal = false
                Task { @MainActor in
                    // Let any existing sheet close before presenting the file picker.
                    await Task.yield()
                    importer.chooseFiles(context: modelContext, engine: engineManager)
                }
            }
        }
        .onChange(of: engineManager.isSplitting) { _, splitting in
            // Media keys can start a recovery separation while a delete card is
            // open; deleting that track mid-separation would orphan its stems.
            if splitting {
                isShowingDeleteModal = false
                trackToDelete = nil
                activeMenuTrackID = nil
            }
        }
        .onChange(of: isSidebarVisible) { _, visible in
            if !visible { activeMenuTrackID = nil }
        }
        .overlay {
            if engineManager.isSplitting {
                SplittingProgressModal(isCovered: isShowingAboutModal || isShowingSettingsModal || isShowingDeleteModal)
            } else if isTargeted {
                Text("DROP AUDIO TO IMPORT")
                    .font(.custom("DotGothic16-Regular", size: 24))
                    .padding(32)
                    .background(theme.modalBackground)
                    .border(Color.red)
                    .allowsHitTesting(false)
            }
        }
        .background {
            // Global ⌘B Keyboard Shortcut for Sidebar Toggle
            Button("") {
                Haptics.playClick()
                withAnimation(.easeOut(duration: 0.12)) {
                    isSidebarVisible.toggle()
                }
            }
            .keyboardShortcut("b", modifiers: [.command])
            .hidden()
        }
        // Native sheet ownership gives the text field a working key window and
        // blocks the player without disabling the sheet's text-input hierarchy.
        .sheet(isPresented: $isShowingRenameModal) {
            if let track = trackToRename {
                RenameModalCard(
                        trackTitle: track.title,
                        renameText: $renameText,
                        onCancel: {
                            isShowingRenameModal = false
                        },
                        onSave: { newTitle in
                            let oldTitle = track.title
                            track.title = newTitle
                            do { try modelContext.save() }
                            catch {
                                track.title = oldTitle
                                isShowingRenameModal = false
                                engineManager.showError("Could not rename the track: \(error.localizedDescription)")
                                return
                            }
                            engineManager.updateTrackTitle(id: track.id, newTitle: newTitle)
                            isShowingRenameModal = false
                        }
                    )
            }
        }
        .overlay {
            if isShowingDeleteModal, let track = trackToDelete {
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
                            guard !engineManager.isExporting else {
                                engineManager.showError("Wait for the export to finish before deleting this track.")
                                return
                            }
                            guard !engineManager.isSplitting else {
                                engineManager.showError("Wait for separation to finish before deleting this track.")
                                return
                            }
                            let wasActive = engineManager.currentTrackID == track.id
                            let stemDir = track.vocalStemURL.deletingLastPathComponent()
                            let sharedCache = tracks.contains { $0.id != track.id && $0.vocalStemURL.deletingLastPathComponent() == stemDir }
                            modelContext.delete(track)
                            do { try modelContext.save() }
                            catch {
                                modelContext.rollback()
                                engineManager.showError("Could not delete the track: \(error.localizedDescription)")
                                return
                            }
                            if wasActive { engineManager.unloadTrack() }
                            if !sharedCache, StemCache.owns(stemDir), FileManager.default.fileExists(atPath: stemDir.path) {
                                do { try FileManager.default.removeItem(at: stemDir) }
                                catch { engineManager.showError("Track removed; cached audio could not be cleaned up: \(error.localizedDescription)") }
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
            } else if appMoveHelper.shouldShowMoveModal && !engineManager.isSplitting {
                // MARK: - Window-Centered Move to Applications Prompt
                // Dismissing only lasts for this launch; the prompt appears only
                // while running from a disk image, where asking again is correct.
                ZStack {
                    theme.modalBackdrop
                        .ignoresSafeArea()
                        .onTapGesture {
                            appMoveHelper.dismissMoveModal()
                        }
                    
                    MoveToApplicationsModalCard(
                        appMoveHelper: appMoveHelper,
                        onDismiss: {
                            appMoveHelper.dismissMoveModal()
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
                .zIndex(9999)
            }
        }
        .onAppear {
            theme.updateWindowAppearance()
            appMoveHelper.checkLocationOnStartup()
            configureSystemControls(tracks)
            if let notice = LibraryStore.takeStartupNotice() {
                engineManager.showError(notice)
            }
        }
        .onChange(of: tracks) { _, newTracks in
            configureSystemControls(newTracks)
        }
    }

    /// Media keys, Control Center and the status menu step through the library
    /// in the sidebar's folder order.
    private func configureSystemControls(_ library: [TrackModel]) {
        let selectTrack: (TrackModel) -> Void = { track in
            Task {
                guard !engineManager.isSplitting else { return }
                await engineManager.loadTrack(track)
                if engineManager.currentTrackID == track.id && !engineManager.isPlaying {
                    engineManager.togglePlayback()
                }
            }
        }
        NowPlayingManager.shared.configure(engineManager: engineManager,
                                           playlistProvider: { library.libraryPlaybackOrder() },
                                           trackSelectHandler: selectTrack)
        MenuBarManager.shared.configure(engineManager: engineManager,
                                        playlistProvider: { library.libraryPlaybackOrder() },
                                        trackSelectHandler: selectTrack)
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
                    
                    Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"))
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
                
                Text("4-STEM ON-DEVICE AUDIO SEPARATION")
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
                    Text("CORE ML PROCESSING ON APPLE SILICON")
                        .font(.custom("DotGothic16-Regular", size: 11))
                        .foregroundColor(theme.textPrimary.opacity(0.85))
                }
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 5, height: 5)
                    Text("LIVE SPECTRUM & ACCELERATE AUDIO ANALYSIS")
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
                .keyboardShortcut(.cancelAction)
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
            
            Text("Isolate works best when installed in your Applications folder.\nWould you like to move it there and relaunch?")
                .font(.custom("DotGothic16-Regular", size: 13))
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            
            if let prompt = appMoveHelper.replacementPrompt {
                Text(prompt)
                    .font(.custom("DotGothic16-Regular", size: 12))
                    .foregroundColor(theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
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
                    // A second click after the prompt confirms replacing the installed copy.
                    appMoveHelper.moveToApplications(replacingExisting: appMoveHelper.replacementPrompt != nil)
                }) {
                    HStack(spacing: 6) {
                        if appMoveHelper.isMoving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        Text(appMoveHelper.isMoving ? "INSTALLING..." : (appMoveHelper.replacementPrompt == nil ? "MOVE & RELAUNCH" : "REPLACE & RELAUNCH"))
                            .font(.custom("DotGothic16-Regular", size: 13))
                            .fontWeight(.bold)
                    }
                    .foregroundColor(isInstallHovered ? .black : .white)
                    .frame(width: 200, height: 36)
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
    @FocusState private var isTitleFocused: Bool
    
    /// Long enough for any real title; a pasted paragraph would otherwise push
    /// the delete confirmation's buttons off screen.
    static let maxTitleLength = 200

    static func sanitizedTitle(_ text: String) -> String? {
        let title = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTitleLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
    
    var body: some View {
        VStack(spacing: 22) {
            Text("RENAME TRACK")
                .font(.custom("DotGothic16-Regular", size: 20))
                .foregroundColor(theme.textPrimary)
            
            TextField("Track Title", text: $renameText)
                .focused($isTitleFocused)
                .font(.custom("DotGothic16-Regular", size: 15))
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.red, lineWidth: 1).allowsHitTesting(false))
                .foregroundColor(theme.textPrimary)
                .onChange(of: renameText) { _, text in
                    if text.count > Self.maxTitleLength { renameText = String(text.prefix(Self.maxTitleLength)) }
                }
            
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
                    if let title = Self.sanitizedTitle(renameText) {
                        onSave(title)
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
        .onAppear { isTitleFocused = true }
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
            
            VStack(spacing: 4) {
                Text("Are you sure you want to delete")
                Text("'\(trackTitle)'")
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("and its isolated stems?")
            }
            .font(.custom("DotGothic16-Regular", size: 14))
            .foregroundColor(theme.textSecondary)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .accessibilityElement(children: .combine)
            
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
        window.appearance = ThemeManager.shared.currentTheme == .system ? nil : NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.minSize = NSSize(width: 960, height: 580)
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        
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
                    .fixedSize(horizontal: false, vertical: true)
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
            .accessibilityLabel("Dismiss error")
            .onHover { hovering in
                isCloseHovered = hovering
            }
        }
        .frame(maxWidth: 700)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.modalBackground)
        .compositingGroup()
        .border(Color.red.opacity(0.8), width: 1)
        .overlay(CornerBrackets())
        .shadow(color: Color.red.opacity(0.3), radius: 14, x: 0, y: 4)
    }
}
