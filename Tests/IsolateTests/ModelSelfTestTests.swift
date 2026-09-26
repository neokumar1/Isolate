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
            try Hardening.requireCompatibleModel(detail)
            XCTAssertTrue(detail.hasPrefix("self-test:"), detail)
            print("Model refused on this macOS: \(detail)")
        }
    }

    func testNonfiniteSelfTestOutputTriesEveryPathAndIsRefusedWithoutCrashing() {
        for quality in [Double.nan, .infinity, -.infinity, -Double.greatestFiniteMagnitude] {
            var attempts = 0
            XCTAssertThrowsError(try DemucsEngine.verifiedComputePath(load: { units in
                attempts += 1
                return units
            }, reconstructionDB: { _ in quality })) { error in
                guard case DemucsError.modelIncompatibleWithSystem(let detail) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertTrue(detail.hasPrefix("self-test:"))
            }
            XCTAssertEqual(attempts, 4)
        }
    }

    func testFailedLoadAndPredictionStillReachAWorkingComputePath() throws {
        var attempted: [MLComputeUnits] = []
        let verified = try DemucsEngine.verifiedComputePath(load: { units in
            attempted.append(units)
            if units == .all { throw DemucsError.modelLoadFailed("GPU unavailable") }
            return units
        }, reconstructionDB: { units in
            if units == .cpuAndGPU { throw DemucsError.conversionFailed("Prediction failed") }
            return units == .cpuOnly ? 42 : 3
        })
        XCTAssertEqual(attempted, [.all, .cpuAndGPU, .cpuAndNeuralEngine, .cpuOnly])
        XCTAssertEqual(verified.computeUnits, .cpuOnly)
        XCTAssertEqual(verified.model, .cpuOnly)
    }

    func testSelfTestStopsAtFirstPassingPath() throws {
        var attempts = 0
        let verified = try DemucsEngine.verifiedComputePath(load: { units in
            attempts += 1
            return units
        }, reconstructionDB: { _ in DemucsEngine.selfTestFloorDB })
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(verified.computeUnits, .all)
    }

    func testAllLoadFailuresReportAnUnusableModelInsteadOfOSIncompatibility() {
        XCTAssertThrowsError(try DemucsEngine.verifiedComputePath(load: { _ -> Int in
            throw DemucsError.modelLoadFailed("Damaged model")
        }, reconstructionDB: { _ in 42 })) { error in
            guard case DemucsError.modelLoadFailed(let detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("Damaged model"))
            XCTAssertTrue(detail.contains("CPU:"))
        }
    }

    func testReleaseGateFailsIncompatibilityUnlessExplicitlyAllowed() throws {
        for environment in [[:], ["ISOLATE_REQUIRE_MODEL": "1"], ["ISOLATE_ALLOW_INCOMPATIBLE_MODEL": "0"]] {
            XCTAssertThrowsError(try Hardening.requireCompatibleModel("self-test: CPU 3 dB", environment: environment))
        }
        XCTAssertNoThrow(try Hardening.requireCompatibleModel("self-test: CPU 3 dB", environment: [
            "ISOLATE_REQUIRE_MODEL": "1", "ISOLATE_ALLOW_INCOMPATIBLE_MODEL": "1"
        ]))
    }

    func testIncompatibilityMessageTellsPeopleWhatToDo() {
        let message = DemucsError.modelIncompatibleWithSystem("self-test: CPU 3 dB").localizedDescription
        XCTAssertTrue(message.contains("macOS 26"), message)
        XCTAssertTrue(message.contains("CPU 3 dB"), message)
    }
}
