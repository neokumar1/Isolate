import XCTest
import SwiftUI
import AppKit
@testable import Isolate

@MainActor
final class FinalUITests: XCTestCase {

    // MARK: - ui-1: EXPORT control speaks its state

    func testExportControlAnnouncesStateAndProgress() {
        let idle = TransportBar.exportAccessibility(for: .idle)
        XCTAssertEqual(idle.label, "Export stems")
        XCTAssertEqual(idle.value, "")

        let rendering = TransportBar.exportAccessibility(for: .exporting(stage: "RENDERING", percent: 0.456))
        XCTAssertEqual(rendering.label, "Cancel export")
        XCTAssertEqual(rendering.value, "45 percent", "The label replaces the visible progress, so the value must carry it")
        XCTAssertEqual(rendering.help, "Cancel the export in progress")

        let archiving = TransportBar.exportAccessibility(for: .exporting(stage: "ARCHIVING", percent: 0.83))
        XCTAssertEqual(archiving.value, "83 percent")

        let completed = TransportBar.exportAccessibility(for: .completed)
        XCTAssertEqual(completed.label, "Export complete", "COMPLETED has nothing left to cancel")
        XCTAssertNotEqual(completed.help, rendering.help)
    }

    // MARK: - ui-2: folder labels

    /// The pairwise definition the per-depth tally replaced.
    private func pairwiseFolderLabels(for folders: [URL]) -> [URL: String] {
        let unique = Array(Set(folders))
        func suffix(_ folder: URL, _ count: Int) -> String {
            folder.pathComponents.suffix(count).joined(separator: " / ")
        }
        var labels: [URL: String] = [:]
        for folder in unique {
            var count = 1
            while count < folder.pathComponents.count,
                  unique.contains(where: { $0 != folder && suffix($0, count).lowercased() == suffix(folder, count).lowercased() }) {
                count += 1
            }
            labels[folder] = suffix(folder, count)
        }
        return labels
    }

    func testFolderLabelsMatchPairwiseDefinitionOnALargeLibrary() {
        let music = URL(filePath: "/Users/someone/Music")
        var folders: [URL] = []
        for artist in 0..<40 {
            for album in ["Greatest Hits", "Live", "Album \(artist)", "Disc 1", "disc 1"] {
                folders.append(music.appending(path: "Artist \(artist % 25)/\(album)"))
            }
        }
        // Same name at different depths, and folders that differ only by case.
        folders += [
            URL(filePath: "/Volumes/Archive/Live"),
            URL(filePath: "/Volumes/Archive/Music/Artist 1/Live"),
            URL(filePath: "/Users/someone/Music/MIX"),
            URL(filePath: "/Users/someone/music/Mix"),
            URL(filePath: "/Mix"),
        ]
        folders += folders.prefix(30)

        let labels = LibraryView.folderLabels(for: folders)
        XCTAssertEqual(labels, pairwiseFolderLabels(for: folders))
        XCTAssertEqual(labels[music.appending(path: "Artist 3/Album 3")], "Album 3")
        XCTAssertEqual(labels[music.appending(path: "Artist 3/Live")], "Artist 3 / Live")
        XCTAssertEqual(labels[music.appending(path: "Artist 1/Live")], "someone / Music / Artist 1 / Live")
    }

    func testFolderLabelCacheRebuildsOnlyWhenTheFoldersChange() {
        let base = URL(filePath: "/Users/someone/Music")
        let hitsA = base.appending(path: "Artist A/Greatest Hits")
        let hitsB = base.appending(path: "Artist B/Greatest Hits")
        let other = base.appending(path: "Artist A/Other")
        let cache = FolderLabelCache()

        let first = cache.labels(for: [hitsA, other])
        XCTAssertEqual(first[hitsA], "Greatest Hits")
        // Search keystrokes and hover re-run the body with the same folders.
        _ = cache.labels(for: [hitsA, other])
        _ = cache.labels(for: [other, hitsA, hitsA])
        XCTAssertEqual(cache.buildCount, 1, "The same set of folders must reuse the labels")

        let second = cache.labels(for: [hitsA, other, hitsB])
        XCTAssertEqual(cache.buildCount, 2)
        XCTAssertEqual(second[hitsA], "Artist A / Greatest Hits", "A new same-named folder must relabel the old one")
        XCTAssertEqual(second[hitsB], "Artist B / Greatest Hits")
    }

    // MARK: - ui-3: marquee measures what it draws

    func testMarqueeTextDrawsAtTheWidthItMeasures() throws {
        try XCTSkipIf(NSFont(name: "DotGothic16-Regular", size: 10) == nil,
                      "Widths are only meaningful with the bundled DotGothic16 font")
        let line = "QUEEN • A NIGHT AT THE OPERA (DELUXE REMASTERED VERSION)"
        for size: CGFloat in [9.5, 10, 10.5, 11, 24] {
            let drawn = NSHostingView(rootView: Text(line).font(MarqueeText.font(size: size)).fixedSize()).fittingSize.width
            XCTAssertEqual(drawn, MarqueeText.measureTextWidth(line, size: size), accuracy: 1,
                           "At \(size) pt the scroll distance and tooltip must use the drawn width")
        }
    }

    // MARK: - ui-4: resting center under Increase Contrast

    func testRestingCenterStaysAboveTheUnlitDotsWithIncreaseContrast() {
        let theme = ThemeManager.shared
        let saved = theme.increaseContrast
        defer { theme.increaseContrast = saved }
        let environment = EnvironmentValues()

        for increaseContrast in [false, true] {
            theme.increaseContrast = increaseContrast
            let grid = theme.knobArcTrack.resolve(in: environment)
            let center = StemDynamicWaveformView.restingCenterColor(theme: theme, effectiveVolume: 1).resolve(in: environment)
            let muted = StemDynamicWaveformView.restingCenterColor(theme: theme, effectiveVolume: 0).resolve(in: environment)
            XCTAssertEqual(muted, grid, "A silent channel's center matches the unlit grid")
            if increaseContrast {
                XCTAssertEqual(center.red, grid.red, accuracy: 0.001)
                XCTAssertGreaterThan(center.opacity, grid.opacity,
                                     "With Increase Contrast the idle center row must stand out from the unlit dots")
            } else {
                XCTAssertEqual(center, theme.textDisabled.resolve(in: environment))
            }
        }
    }

    // MARK: - ui-6: HUD EQ captions at compact height

    func testHUDEqualizerHidesFrequencyCaptionsOnlyInTheCompactHUD() {
        // HUD height, minus its top bar, divider and the EQ view's vertical padding,
        // then the 16 pt toolbar and 4 pt gap above the curve.
        // Integer arithmetic keeps these quick for older compilers to type-check.
        let compactHeight: Int = 76 - 24 - 1 - 2 * 2 - (16 + 4)
        let regularHeight: Int = 100 - 28 - 1 - 4 * 2 - (16 + 4)
        let compactCanvas = CGFloat(compactHeight)
        let regularCanvas = CGFloat(regularHeight)
        XCTAssertFalse(HUDEqualizerCurveView.showsFrequencyLabels(canvasHeight: compactCanvas),
                       "The compact curve is too short for captions under the band nodes")
        XCTAssertTrue(HUDEqualizerCurveView.showsFrequencyLabels(canvasHeight: regularCanvas))
    }
}
