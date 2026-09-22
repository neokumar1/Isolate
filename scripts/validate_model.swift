import CoreML
import CryptoKit
import Foundation

func digest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw NSError(domain: "Isolate", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: swift scripts/validate_model.swift /path/to/HTDemucs.mlmodelc"])
    }
    let directory = URL(filePath: CommandLine.arguments[1])
    let expected = [
        "model.mil": "8e321470c16930183821c9b63ab058a2b3adc332d7974dc4aabbab15fbbd4ce0",
        "weights/weight.bin": "efab790ad07d93faeb5a19b6e1eedad8c37ad351563a891a153fce307811c099"
    ]
    for (path, checksum) in expected {
        guard try digest(directory.appending(path: path)) == checksum else {
            throw NSError(domain: "Isolate", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unrecognized model artifact: \(path). See MODEL.md before changing the release model."])
        }
    }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuOnly
    let model = try MLModel(contentsOf: directory, configuration: configuration)
    guard model.modelDescription.inputDescriptionsByName["audio"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, 2, 441000],
          model.modelDescription.outputDescriptionsByName["sources"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, 4, 2, 441000] else {
        throw NSError(domain: "Isolate", code: 3, userInfo: [NSLocalizedDescriptionKey: "Model tensor contract mismatch. See MODEL.md."])
    }
    print("Validated reference model hashes and tensor contract (vocals, drums, bass, other).")
} catch {
    FileHandle.standardError.write(Data("Model validation failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
