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

    func testEmptyLibraryAndExportGuards() {
        let app = launch()
        XCTAssertTrue(app.buttons["Play"].exists)
        XCTAssertFalse(app.buttons["Play"].isEnabled)
        app.menuBars.menuBarItems["File"].click()
        XCTAssertFalse(app.menuItems["Export Stems…"].isEnabled)
        XCTAssertFalse(app.menuItems["Export Mix…"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        capture(app, name: "Empty player — dark")
    }

    func testSettingsThemesAndKeyboardDismissal() {
        let app = launch()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["SYSTEM PREFERENCES"].waitForExistence(timeout: 3))
        app.buttons["NOTHING LIGHT"].click()
        capture(app, name: "Settings — light")
        app.buttons["FLAC"].click()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.staticTexts["SYSTEM PREFERENCES"].exists)
        capture(app, name: "Empty player — light")
        app.typeKey(",", modifierFlags: .command)
        app.buttons["NOTHING DARK"].click()
        app.buttons["SHORTCUTS"].click()
        XCTAssertTrue(app.staticTexts["Export Current Mix as WAV"].exists)
        capture(app, name: "Keyboard shortcuts")
    }

    func testImportDialogCanBeCancelled() {
        let app = launch(theme: "light")
        app.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.buttons["Cancel"].exists)
        XCTAssertFalse(app.buttons["Play"].isEnabled)
    }

    func testCommandsReopenClosedMainWindow() {
        let app = launch()
        app.typeKey("w", modifierFlags: .command)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["SYSTEM PREFERENCES"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Play"].isEnabled)
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
        let autoPlay = app.buttons["Auto-play on select"]
        XCTAssertTrue(autoPlay.waitForExistence(timeout: 3))
        XCTAssertEqual(autoPlay.value as? String, "On")
        autoPlay.click()
        XCTAssertEqual(autoPlay.value as? String, "Off")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("o", modifierFlags: .command)
        let openButton = app.windows["open-panel"].buttons["Open"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(source.path)
        app.typeKey(.return, modifierFlags: [])
        openButton.click()
        let actions = app.buttons["Actions for UI Workflow"]
        XCTAssertTrue(actions.waitForExistence(timeout: 120), "Import must publish the track into the library")
        let librarySummary = app.descendants(matching: .any)["library-summary"]
        let statisticsReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "MB"), object: librarySummary)
        XCTAssertEqual(XCTWaiter.wait(for: [statisticsReady], timeout: 5), .completed,
                       "Library statistics should reflect the imported audio before deletion")

        app.activate()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3))
        app.typeKey("l", modifierFlags: [])
        app.buttons["Play"].click()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
        app.buttons["Pause"].click()

        let stems = ["VOCALS", "DRUMS", "BASS", "OTHER"]
        for selectedStem in stems {
            app.buttons["Solo \(selectedStem)"].click()
            for stem in stems {
                XCTAssertEqual(app.buttons["Solo \(stem)"].value as? String,
                               stem == selectedStem ? "On" : "Off",
                               "Solo should make only the selected stem active")
            }
        }
        app.buttons["Solo OTHER"].click()
        for stem in stems {
            XCTAssertEqual(app.buttons["Solo \(stem)"].value as? String, "Off")
            app.buttons["Mute \(stem)"].click()
            XCTAssertEqual(app.buttons["Mute \(stem)"].value as? String, "On")
            app.buttons["Mute \(stem)"].click()
            XCTAssertEqual(app.buttons["Mute \(stem)"].value as? String, "Off")
        }

        // Text entry must not accidentally invoke the mixer's unmodified shortcuts.
        let search = app.textFields["Search library"]
        search.click()
        search.typeText("vadbo1234")
        XCTAssertTrue(app.staticTexts["NO MATCHING TRACKS"].exists)
        for stem in stems {
            XCTAssertEqual(app.buttons["Solo \(stem)"].value as? String, "Off")
            XCTAssertEqual(app.buttons["Mute \(stem)"].value as? String, "Off")
        }
        app.buttons["Clear library search"].click()
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["Actions for UI Workflow"].exists)

        app.typeKey("v", modifierFlags: [])
        XCTAssertEqual(app.buttons["Mute VOCALS"].value as? String, "On")
        app.typeKey("r", modifierFlags: [])
        XCTAssertEqual(app.buttons["Mute VOCALS"].value as? String, "Off")
        capture(app, name: "Imported track and mixer")

        actions.click()
        app.buttons["[ RENAME ]"].click()
        let title = app.textFields["Track Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.click()
        app.typeKey("a", modifierFlags: .command)
        title.typeText("Renamed UI Track")
        XCTAssertEqual(title.value as? String, "Renamed UI Track")
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
        let exported = directory.appending(path: "Renamed UI Track_Mix.wav")
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: exported.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 20), .completed)
        let mix = try AVAudioFile(forReading: exported)
        XCTAssertEqual(mix.length, 88_200)
        XCTAssertEqual(mix.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)

        // Export reveals its file in Finder; return to the tested app for deletion.
        app.activate()
        app.menuBars.menuBarItems["File"].click()
        let exportReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"),
                                                    object: app.menuItems["Export Mix…"])
        XCTAssertEqual(XCTWaiter.wait(for: [exportReady], timeout: 5), .completed)
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["Actions for Renamed UI Track"].click()
        app.buttons["[ DELETE ]"].click()
        XCTAssertTrue(app.staticTexts["DELETE TRACK?"].waitForExistence(timeout: 3))
        app.buttons["DELETE"].click()
        XCTAssertFalse(app.buttons["Play"].isEnabled)
        XCTAssertFalse(app.buttons["Actions for Renamed UI Track"].exists)
        XCTAssertEqual(librarySummary.label, "0 tracks",
                       "Deleting the final track must clear its displayed size and duration")
        XCTAssertEqual(try Data(contentsOf: source), originalBytes, "Deleting a library track must preserve source audio")
        capture(app, name: "Library after safe deletion")
    }
}
