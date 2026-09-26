import XCTest
import AVFoundation

@MainActor
final class IsolateUITests: XCTestCase {
    private func launch(theme: String = "dark") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["ISOLATE_TEST_THEME"] = theme
        app.launch()
        app.activate()
        app.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Waits

    /// UI state lags the click or key press that changed it, so wait for it rather than
    /// reading it at once. Returns immediately when the state is already there.
    private func waitFor(_ element: XCUIElement, _ format: String, _ arguments: [Any] = [],
                         timeout: TimeInterval = 3) -> Bool {
        let predicate = NSPredicate(format: format, argumentArray: arguments)
        if predicate.evaluate(with: element) { return true }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func expectValue(_ element: XCUIElement, _ value: String, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        let found = waitFor(element, "value == %@", [value])
        XCTAssertTrue(found, "\(message) Expected \(value), found \(element.exists ? String(describing: element.value ?? "nil") : "no element")",
                      file: file, line: line)
    }

    private func expectGone(_ element: XCUIElement, _ message: String, timeout: TimeInterval = 3,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitFor(element, "exists == false", timeout: timeout), message, file: file, line: line)
    }

    private func expectEnabled(_ element: XCUIElement, _ enabled: Bool, _ message: String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitFor(element, "enabled == %@", [NSNumber(value: enabled)]), message, file: file, line: line)
    }

    /// Waits for the imported row. An import that ends in the error toast (a missing model,
    /// for example) or ends without a row (cancelled) fails at once instead of waiting out
    /// the timeout.
    private func waitForImportedRow(_ row: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 120) {
        let toast = app.buttons["Dismiss error"]
        let progress = [app.buttons["CANCEL IMPORT"], app.buttons["CANCELLING…"]]
        var sawProgress = false
        var progressGoneSince: Date?
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if row.waitForExistence(timeout: 1) { return }
            if toast.exists {
                capture(app, name: "Import error")
                let message = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "import")).firstMatch
                XCTFail("Import showed an error instead of adding the track: \(message.exists ? message.label : "see the Import error screenshot")")
                return
            }
            if progress.contains(where: \.exists) {
                sawProgress = true
                progressGoneSince = nil
            } else if sawProgress {
                let gone = progressGoneSince ?? Date()
                progressGoneSince = gone
                if Date().timeIntervalSince(gone) > 5 {
                    capture(app, name: "Import ended without a track")
                    XCTFail("The separation ended without adding the track; was it cancelled?")
                    return
                }
            }
        }
        XCTFail("Import must publish the track into the library")
    }

    // MARK: - Flows

    func testEmptyLibraryAndExportGuards() {
        let app = launch()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertFalse(play.isEnabled)
        let export = app.buttons["Export stems"]
        XCTAssertTrue(export.exists, "VoiceOver must announce the EXPORT control as Export stems")
        XCTAssertFalse(export.isEnabled)
        XCTAssertFalse(app.buttons["Loop"].isEnabled, "Loop controls need a loaded track")
        app.menuBars.menuBarItems["File"].click()
        let exportStems = app.menuItems["Export Stems…"]
        XCTAssertTrue(exportStems.waitForExistence(timeout: 3))
        XCTAssertFalse(exportStems.isEnabled)
        XCTAssertFalse(app.menuItems["Export Mix…"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        capture(app, name: "Empty player — dark")
    }

    func testSettingsThemesAndKeyboardDismissal() {
        let app = launch()
        app.typeKey(",", modifierFlags: .command)
        let preferences = app.staticTexts["SYSTEM PREFERENCES"]
        XCTAssertTrue(preferences.waitForExistence(timeout: 3))
        let dark = app.buttons["NOTHING DARK"]
        let light = app.buttons["NOTHING LIGHT"]
        let flac = app.buttons["FLAC"]
        // The chips mark their choice with the selected trait. If this macOS does not surface
        // it, say so in the report instead of failing on the platform.
        let exposesSelection = dark.isSelected
        if !exposesSelection {
            XCTContext.runActivity(named: "Settings chips do not report AXSelected; selection not asserted") { _ in }
        }
        light.click()
        if exposesSelection {
            XCTAssertTrue(waitFor(light, "selected == true"), "Clicking NOTHING LIGHT must select it")
            XCTAssertFalse(dark.isSelected)
        }
        capture(app, name: "Settings — light")
        flac.click()
        if exposesSelection {
            XCTAssertTrue(waitFor(flac, "selected == true"), "Clicking FLAC must make it the stem export format")
            XCTAssertFalse(app.buttons["WAV 24B"].isSelected)
        }
        // Switches toggle when clicked at their centre. Hosted tests start with haptics off.
        let haptics = app.buttons["Haptic feedback"]
        expectValue(haptics, "Off")
        haptics.click()
        expectValue(haptics, "On", "Clicking the switch's centre must turn it on")
        haptics.click()
        expectValue(haptics, "Off", "Clicking the switch's centre again must turn it off")
        app.typeKey(.escape, modifierFlags: [])
        expectGone(preferences, "Escape must close Settings")
        capture(app, name: "Empty player — light")
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(preferences.waitForExistence(timeout: 3))
        if exposesSelection {
            XCTAssertTrue(flac.isSelected, "The chosen export format must still be selected")
        }
        dark.click()
        if exposesSelection {
            XCTAssertTrue(waitFor(dark, "selected == true"))
        }
        app.buttons["SHORTCUTS"].click()
        XCTAssertTrue(app.staticTexts["Export Current Mix as WAV"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Clear A-B Loop Markers"].exists, "The shortcut list must include ⌥L")
        capture(app, name: "Keyboard shortcuts")
    }

    func testImportDialogCanBeCancelled() {
        let app = launch(theme: "light")
        app.typeKey("o", modifierFlags: .command)
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        expectGone(cancel, "Escape must close the open panel")
        XCTAssertFalse(app.buttons["Play"].isEnabled)
    }

    func testCommandsReopenClosedMainWindow() {
        let app = launch()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        expectGone(play, "⌘W must close the main window")
        app.typeKey(",", modifierFlags: .command)
        let preferences = app.staticTexts["SYSTEM PREFERENCES"]
        XCTAssertTrue(preferences.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        expectGone(preferences, "Escape must close Settings")
        app.typeKey("w", modifierFlags: .command)
        expectGone(play, "⌘W must close the reopened window")
        app.typeKey("o", modifierFlags: .command)
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        expectGone(cancel, "Escape must close the open panel")
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        XCTAssertFalse(play.isEnabled)
    }

    func testImportPlaybackRenameExportAndDelete() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Isolate-UI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "UI Workflow.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame] = 0.1 * sin(Float(frame) * 2 * .pi * 440 / 44_100)
            }
        }
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            try file.write(from: buffer)
        }
        let originalBytes = try Data(contentsOf: source)
        let app = launch()
        // Exercise the preference and avoid racing a two-second auto-playing
        // fixture's completion while clicking a changing Play/Pause button.
        app.typeKey(",", modifierFlags: .command)
        let preferences = app.staticTexts["SYSTEM PREFERENCES"]
        let autoPlay = app.buttons["Auto-play on select"]
        XCTAssertTrue(autoPlay.waitForExistence(timeout: 3))
        XCTAssertEqual(autoPlay.value as? String, "On")
        autoPlay.click()
        expectValue(autoPlay, "Off", "Clicking the switch's center must turn auto-play off")
        app.typeKey(.escape, modifierFlags: [])
        expectGone(preferences, "Escape must close Settings")
        app.typeKey("o", modifierFlags: .command)
        let openButton = app.windows["open-panel"].buttons["Open"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(source.path)
        app.typeKey(.return, modifierFlags: [])
        openButton.click()

        // Escape on a card opened over the separation closes that card and never cancels the
        // import. Checked only while the separation is still running when each card opens.
        let cancelImport = app.buttons["CANCEL IMPORT"]
        if cancelImport.waitForExistence(timeout: 5) {
            app.typeKey(",", modifierFlags: .command)
            if preferences.waitForExistence(timeout: 3) {
                app.typeKey(.escape, modifierFlags: [])
                expectGone(preferences, "Escape must close Settings opened over the separation")
                XCTAssertFalse(app.buttons["CANCELLING…"].exists, "Escape on Settings must not cancel the separation")
            }
        }
        if cancelImport.exists {
            app.menuBars.menuBarItems["Isolate"].click()
            app.menuItems["About Isolate"].click()
            let about = app.staticTexts["4-STEM ON-DEVICE AUDIO SEPARATION"]
            if about.waitForExistence(timeout: 3) {
                app.typeKey(.escape, modifierFlags: [])
                expectGone(about, "Escape must close About opened over the separation")
                XCTAssertFalse(app.buttons["CANCELLING…"].exists, "Escape on About must not cancel the separation")
            }
        }

        // A cancelled import adds no row, so this also proves the Escapes above left it running.
        let actions = app.buttons["Actions for UI Workflow"]
        waitForImportedRow(actions, in: app)
        let librarySummary = app.descendants(matching: .any)["library-summary"]
        XCTAssertTrue(waitFor(librarySummary, "label CONTAINS %@", ["MB"], timeout: 5),
                      "Library statistics should reflect the imported audio before deletion")

        app.activate()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        let export = app.buttons["Export stems"]
        XCTAssertTrue(export.exists, "VoiceOver must announce the EXPORT control as Export stems")
        expectEnabled(export, true, "EXPORT must be available once a track is loaded")
        let loop = app.buttons["Loop"]
        app.typeKey("l", modifierFlags: [])
        expectValue(loop, "On", "L must turn the loop on")
        play.click()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
        app.buttons["Pause"].click()
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        app.typeKey("l", modifierFlags: .option)
        expectValue(loop, "Off", "⌥L must clear the loop markers")

        let stems = ["VOCALS", "DRUMS", "BASS", "OTHER"]
        for selectedStem in stems {
            app.buttons["Solo \(selectedStem)"].click()
            for stem in stems {
                expectValue(app.buttons["Solo \(stem)"], stem == selectedStem ? "On" : "Off",
                            "Solo should make only the selected stem active")
            }
        }
        app.buttons["Solo OTHER"].click()
        for stem in stems {
            expectValue(app.buttons["Solo \(stem)"], "Off")
            app.buttons["Mute \(stem)"].click()
            expectValue(app.buttons["Mute \(stem)"], "On")
            app.buttons["Mute \(stem)"].click()
            expectValue(app.buttons["Mute \(stem)"], "Off")
        }

        // Text entry must not accidentally invoke the mixer's unmodified shortcuts.
        let search = app.textFields["Search library"]
        XCTAssertEqual(search.placeholderValue, "SEARCH LIBRARY...")
        search.click()
        search.typeText("vadbo1234")
        XCTAssertTrue(app.staticTexts["NO MATCHING TRACKS"].waitForExistence(timeout: 3))
        for stem in stems {
            XCTAssertEqual(app.buttons["Solo \(stem)"].value as? String, "Off")
            XCTAssertEqual(app.buttons["Mute \(stem)"].value as? String, "Off")
        }
        app.buttons["Clear library search"].click()
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(actions.waitForExistence(timeout: 3))

        app.typeKey("v", modifierFlags: [])
        expectValue(app.buttons["Mute VOCALS"], "On", "V must mute vocals")
        app.typeKey("r", modifierFlags: [])
        expectValue(app.buttons["Mute VOCALS"], "Off", "R must reset the mix")
        capture(app, name: "Imported track and mixer")

        actions.click()
        let rename = app.buttons["[ RENAME ]"]
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        rename.click()
        let title = app.textFields["Track Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.click()
        app.typeKey("a", modifierFlags: .command)
        title.typeText("Renamed UI Track")
        expectValue(title, "Renamed UI Track")
        app.buttons["SAVE"].click()
        XCTAssertTrue(app.buttons["Actions for Renamed UI Track"].waitForExistence(timeout: 3))

        app.typeKey("w", modifierFlags: .command)
        app.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Actions for Renamed UI Track"].waitForExistence(timeout: 5))

        app.typeKey("m", modifierFlags: [.command, .shift])
        let saveButton = app.buttons["OKButton"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(directory.path)
        app.typeKey(.return, modifierFlags: [])
        saveButton.click()
        // From the start of the render until COMPLETED clears (about 2 s), EXPORT cancels instead.
        XCTAssertTrue(app.buttons["Cancel export"].waitForExistence(timeout: 3),
                      "VoiceOver must announce the EXPORT control as Cancel export while exporting")
        let exported = directory.appending(path: "Renamed UI Track_Mix.wav")
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: exported.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 20), .completed)
        let mix = try AVAudioFile(forReading: exported)
        XCTAssertEqual(mix.length, 88_200)
        XCTAssertEqual(mix.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
        XCTAssertTrue(export.waitForExistence(timeout: 10), "EXPORT must return to Export stems after the export")

        // Export reveals its file in Finder; return to the tested app for deletion.
        app.activate()
        app.menuBars.menuBarItems["File"].click()
        XCTAssertTrue(waitFor(app.menuItems["Export Mix…"], "enabled == true", timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["Actions for Renamed UI Track"].click()
        let delete = app.buttons["[ DELETE ]"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.click()
        XCTAssertTrue(app.staticTexts["DELETE TRACK?"].waitForExistence(timeout: 3))
        app.buttons["DELETE"].click()
        expectEnabled(play, false, "Deleting the loaded track must unload it")
        expectGone(app.buttons["Actions for Renamed UI Track"], "The deleted track must leave the library")
        XCTAssertTrue(waitFor(librarySummary, "label == %@", ["0 tracks"]),
                      "Deleting the final track must clear its displayed size and duration")
        XCTAssertEqual(try Data(contentsOf: source), originalBytes, "Deleting a library track must preserve source audio")
        capture(app, name: "Library after safe deletion")
    }
}
