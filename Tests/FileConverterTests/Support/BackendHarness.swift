import Foundation
import XCTest
@testable import FileConverterCore

/// Runs one backend conversion outside the queue: asks the backend for its
/// output requirements, plans outputs in `directory`, converts, and returns
/// the produced files.
enum BackendHarness {
    static func convert(
        backend: any ConversionBackend,
        source: URL,
        preset: ConversionPreset,
        into directory: URL,
        baseName: String = "output"
    ) async throws -> (outputs: [URL], result: BackendConversionResult) {
        var job = ConversionJob(sourceURL: source, preset: preset)
        let requirements = try await backend.outputRequirements(for: job)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputs = requirements.map { requirement -> PlannedConversionOutput in
            var name = baseName
            if let suffix = requirement.suffix, !suffix.isEmpty { name += "-\(suffix)" }
            let url = directory.appendingPathComponent(name).appendingPathExtension(requirement.extensionName)
            try? FileManager.default.removeItem(at: url)
            return PlannedConversionOutput(finalURL: url, temporaryURL: url)
        }
        job.plannedOutputs = outputs
        job.destinationURL = outputs.first?.finalURL
        job.temporaryOutputURL = outputs.first?.temporaryURL
        let result = try await backend.convert(job: job, outputs: outputs, progressHandler: { _ in })
        return (outputs.map(\.finalURL), result)
    }

    static func makeTempDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func builtIn(_ key: String) throws -> ConversionPreset {
        try XCTUnwrap(BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == key }, "missing built-in \(key)")
    }
}
