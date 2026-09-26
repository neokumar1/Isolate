import XCTest
import AppKit
@testable import Isolate

final class WindowSizingTests: XCTestCase {
    private let minimum = NSSize(width: 960, height: 580)

    func testFirstLaunchUsesTheDefaultSizeOnTypicalDisplays() {
        let size = WindowAccessor.Coordinator.fittedContentSize(visible: NSSize(width: 1728, height: 1079), minimum: minimum)
        XCTAssertEqual(size, WindowAccessor.Coordinator.defaultContentSize)
    }

    func testDefaultSizeShrinksToFitSmallDisplaysButNotBelowTheMinimum() {
        let small = WindowAccessor.Coordinator.fittedContentSize(visible: NSSize(width: 1280, height: 777), minimum: minimum)
        XCTAssertEqual(small, NSSize(width: 1240, height: 717))
        let tiny = WindowAccessor.Coordinator.fittedContentSize(visible: NSSize(width: 900, height: 500), minimum: minimum)
        XCTAssertEqual(tiny, minimum)
    }
}
