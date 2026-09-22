import AppKit
import SwiftUI

@MainActor
public final class AppMoveHelper: ObservableObject {
    public static let shared = AppMoveHelper()
    
    @Published public var shouldShowMoveModal = false
    @Published public var isMoving = false
    @Published public var moveErrorMessage: String? = nil
    
    private init() {}
    
    public var isRunningFromApplications: Bool {
        let bundlePath = Bundle.main.bundlePath
        return bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
    
    public var isRunningFromDiskImage: Bool {
        let bundlePath = Bundle.main.bundlePath
        return bundlePath.hasPrefix("/Volumes/")
    }
    
    public func checkLocationOnStartup() {
        #if !DEBUG
        if AppPreferences.defaults.bool(forKey: "hasDeclinedMoveToApplications") {
            return
        }
        
        // ONLY prompt if the user is running the app directly off a mounted disk image volume (/Volumes/...)
        if isRunningFromDiskImage && !isRunningFromApplications {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.shouldShowMoveModal = true
            }
        }
        #endif
    }
    
    public func moveToApplications() {
        guard !isMoving else { return }
        isMoving = true
        moveErrorMessage = nil
        let source = Bundle.main.bundleURL
        let destination = URL(filePath: "/Applications/Isolate.app")
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    let staging = destination.deletingLastPathComponent()
                        .appending(path: ".Isolate-install-\(UUID().uuidString).app")
                    defer { try? fm.removeItem(at: staging) }
                    // Finish copying before replacing an existing installation.
                    try fm.copyItem(at: source, to: staging)
                    if fm.fileExists(atPath: destination.path) {
                        _ = try fm.replaceItemAt(destination, withItemAt: staging)
                    } else {
                        try fm.moveItem(at: staging, to: destination)
                    }
                }.value
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
                // Keep this instance alive if macOS cannot launch the installed copy.
                NSApp.terminate(nil)
            } catch {
                isMoving = false
                moveErrorMessage = "Could not install or open Isolate. \(error.localizedDescription) You can also drag Isolate into Applications in Finder."
            }
        }
    }
}
