import AppKit
import SwiftUI

@MainActor
public final class AppMoveHelper: ObservableObject {
    public static let shared = AppMoveHelper()
    
    @Published public var shouldShowMoveModal = false
    @Published public var isMoving = false
    @Published public var moveErrorMessage: String? = nil
    /// Set when Applications already holds Isolate; replacing it needs a second click.
    @Published public var replacementPrompt: String? = nil

    static let installURL = URL(filePath: "/Applications/Isolate.app")

    enum MoveError: LocalizedError {
        case destinationExists
        var errorDescription: String? { "Isolate is already in Applications." }
    }
    
    private init() {}
    
    /// Where the user opened the app. Gatekeeper runs a quarantined app opened
    /// from a downloaded disk image from a randomized read-only
    /// AppTranslocation path, which never starts with /Volumes/.
    nonisolated static func originalURL(of bundleURL: URL) -> URL {
        guard bundleURL.path.contains("/AppTranslocation/"),
              let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return bundleURL }
        typealias CreateOriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let createOriginalPath = unsafeBitCast(symbol, to: CreateOriginalPath.self)
        guard let original = createOriginalPath(bundleURL as CFURL, nil)?.takeRetainedValue() else { return bundleURL }
        return original as URL
    }

    /// A mounted read-only volume, as a disk image is; an app a user keeps on
    /// a writable external drive is left alone.
    nonisolated static func isDiskImageLocation(_ url: URL) -> Bool {
        guard url.path.hasPrefix("/Volumes/") else { return false }
        return (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? true
    }

    public var isRunningFromApplications: Bool {
        let bundlePath = Self.originalURL(of: Bundle.main.bundleURL).path
        return bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
    
    public var isRunningFromDiskImage: Bool {
        Self.isDiskImageLocation(Self.originalURL(of: Bundle.main.bundleURL))
    }
    
    public func checkLocationOnStartup() {
        #if !DEBUG
        // Earlier builds stored a permanent decline; "not now" is per launch.
        if AppPreferences.defaults.bool(forKey: "hasDeclinedMoveToApplications") {
            return
        }
        
        // ONLY prompt when running from a disk image, including a translocated one.
        if isRunningFromDiskImage && !isRunningFromApplications {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.shouldShowMoveModal = true
            }
        }
        #endif
    }
    
    public func dismissMoveModal() {
        shouldShowMoveModal = false
        replacementPrompt = nil
        moveErrorMessage = nil
    }

    /// Bundle identifier and version of an installed app, read without Bundle's cache.
    nonisolated static func installedInfo(at url: URL) -> (identifier: String?, version: String?)? {
        guard let plist = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")) else { return nil }
        return (plist["CFBundleIdentifier"] as? String, plist["CFBundleShortVersionString"] as? String)
    }

    public func moveToApplications(replacingExisting: Bool = false) {
        guard !isMoving else { return }
        moveErrorMessage = nil
        let source = Bundle.main.bundleURL
        let destination = Self.installURL
        if !replacingExisting, FileManager.default.fileExists(atPath: destination.path) {
            let installed = Self.installedInfo(at: destination)
            guard installed?.identifier == Bundle.main.bundleIdentifier else {
                moveErrorMessage = "A different app named Isolate is already in Applications. Drag Isolate into Applications in Finder to choose which to keep."
                return
            }
            let version = installed?.version.map { " \($0)" } ?? ""
            replacementPrompt = "Isolate\(version) is already in Applications. Replace it? The installed copy will be moved to the Trash."
            return
        }
        isMoving = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Self.install(from: source, to: destination, replacingExisting: replacingExisting)
                }.value
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
                // Keep this instance alive if macOS cannot launch the installed copy.
                NSApp.terminate(nil)
            } catch {
                isMoving = false
                replacementPrompt = nil
                moveErrorMessage = "Could not install or open Isolate. \(error.localizedDescription) You can also drag Isolate into Applications in Finder."
            }
        }
    }

    /// Copies the app next to `destination` first, so a failed copy never
    /// touches an existing installation. An existing app is only retired (moved
    /// to the Trash by default) when the user confirmed replacing it.
    nonisolated static func install(from source: URL, to destination: URL, replacingExisting: Bool,
                                    retire: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appending(path: ".Isolate-install-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        removeQuarantine(from: staging)
        if fm.fileExists(atPath: destination.path) {
            guard replacingExisting else { throw MoveError.destinationExists }
            try retire(destination)
        }
        try fm.moveItem(at: staging, to: destination)
    }

    /// The user already opened this copy. A copy made by the app, unlike one
    /// dragged in Finder, keeps the download's quarantine flag and would be
    /// translocated again on every launch from Applications.
    nonisolated static func removeQuarantine(from bundle: URL) {
        var paths = [bundle.path]
        if let enumerator = FileManager.default.enumerator(atPath: bundle.path) {
            while let relative = enumerator.nextObject() as? String {
                paths.append(bundle.appending(path: relative).path)
            }
        }
        for path in paths {
            removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }
}
