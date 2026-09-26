import XCTest
import CoreML
@testable import Isolate

/// Core ML computes this model incorrectly on some macOS versions and compute paths
/// (measured on hosted macOS 14 and 15). Whatever the host, the installed model must be
/// either verified to separate correctly or refused — never accepted with bad output.
final class ModelSelfTestTests: XCTestCase {
    func testInstalledModelIsVerifiedOrRefused() throws {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Isolate/HTDemucs.mlmodelc")
        guard FileManager.default.fileExists(atPath: url.path) else {
            if ProcessInfo.processInfo.environment["ISOLATE_REQUIRE_MODEL"] == "1" {
                XCTFail("ISOLATE_REQUIRE_MODEL=1 but no model is installed at \(url.path)")
                return
            }
            throw XCTSkip("Install the model to run the self-test.")
        }
        do {
            let verified = try DemucsEngine.verifiedModel(at: url)
            let quality = try DemucsEngine.selfTestReconstructionDB(verified.model)
            XCTAssertGreaterThanOrEqual(quality, DemucsEngine.selfTestFloorDB)
            print("Model verified with compute units \(verified.computeUnits.rawValue) at \(String(format: "%.1f", quality)) dB")
        } catch DemucsError.modelIncompatibleWithSystem(let detail) {
            // Refusing is the correct outcome where every compute path is wrong.
            XCTAssertTrue(detail.hasPrefix("self-test:"), detail)
            print("Model refused on this macOS: \(detail)")
        }
    }

    func testIncompatibilityMessageTellsPeopleWhatToDo() {
        let message = DemucsError.modelIncompatibleWithSystem("self-test: CPU 3 dB").localizedDescription
        XCTAssertTrue(message.contains("macOS 26"), message)
        XCTAssertTrue(message.contains("CPU 3 dB"), message)
    }
}
