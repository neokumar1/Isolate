import Foundation

/// UI and hosted unit tests must not overwrite the user's settings or library.
enum AppPreferences {
    static let isTesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static let defaults: UserDefaults = {
        guard isTesting else { return .standard }
        let domain = "com.isolate.Isolate.TestPreferences"
        let preferences = UserDefaults(suiteName: domain)!
        preferences.removePersistentDomain(forName: domain)
        preferences.register(defaults: ["isMenuBarDisabled": true, "isHapticsDisabled": true,
                                       "hardwareTheme": ProcessInfo.processInfo.environment["ISOLATE_TEST_THEME"] ?? "dark"])
        return preferences
    }()
}
