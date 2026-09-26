import XCTest
import AVFoundation
@testable import Isolate

@MainActor
final class ExporterFixTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testSafeFilenameNeverProducesHiddenOrWindowsInvalidNames() {
        XCTAssertEqual(AudioExporter.safeFilename("...Baby One More Time"), "Baby One More Time")
        XCTAssertEqual(AudioExporter.safeFilename(".38 Special - Hold On Loosely"), "38 Special - Hold On Loosely")
        XCTAssertEqual(AudioExporter.safeFilename("Where Is My Mind?"), "Where Is My Mind_")
        XCTAssertEqual(AudioExporter.safeFilename("The \"Heroes\" <*|>"), "The _Heroes_ ____")
        XCTAssertEqual(AudioExporter.safeFilename("Trailing dots... "), "Trailing dots")
        XCTAssertEqual(AudioExporter.safeFilename("Beyoncé"), "Beyoncé")
        for title in [".", "..", "...", " . . ", ""] {
            XCTAssertEqual(AudioExporter.safeFilename(title), "Isolate", "Title \(title.debugDescription)")
        }
        // Truncation must not leave a trailing space or dot either.
        let long = AudioExporter.safeFilename(String(repeating: "a", count: 119) + " tail")
        XCTAssertFalse(long.hasSuffix(" ") || long.hasSuffix("."))
        for title in ["..Hidden", "A?B*C\"D<E>F|G:H/I\\J", "Name. ", String(repeating: "音", count: 90) + "🎵"] {
            let name = AudioExporter.safeFilename(title)
            XCTAssertFalse(name.hasPrefix("."), name)
            XCTAssertFalse(name.hasSuffix(".") || name.hasSuffix(" "), name)
            XCTAssertNil(name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\\?*\"<>|")), name)
        }
    }
}
