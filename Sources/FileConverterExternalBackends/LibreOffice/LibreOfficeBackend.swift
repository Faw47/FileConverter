import Foundation
import FileConverterCore

public final class LibreOfficeBackend: ConversionBackend, @unchecked Sendable {
    public let backendType: BackendType = .libreOffice
    public var isAvailable: Bool {
        ExternalToolDiscovery.shared.isToolAvailable("soffice")
    }

    private let processRegistry = ExternalProcessRegistry()
    private let executableURLOverride: URL?
    private let stagingDirectoryParentURL: URL

    public init() {
        executableURLOverride = nil
        stagingDirectoryParentURL = FileManager.default.temporaryDirectory
    }

    init(executableURL: URL, stagingDirectoryParentURL: URL) {
        executableURLOverride = executableURL
        self.stagingDirectoryParentURL = stagingDirectoryParentURL
    }

    public func supports(sourceFormat: FormatDefinition, destinationFormat: FormatDefinition, preset: ConversionPreset) -> Bool {
        return sourceFormat.category == .document && destinationFormat.category == .document
    }

    public func cancel(jobID: UUID) async {
        processRegistry.cancel(jobID: jobID)
    }

    public func convert(job: ConversionJob, progressHandler: @escaping @Sendable (ConversionProgress) -> Void) async throws {
        guard let sofficeURL = executableURLOverride
            ?? ExternalToolDiscovery.shared.executablePath(for: "soffice").map({ URL(fileURLWithPath: $0) }) else {
            throw ConversionError.dependencyMissing(dependencyName: "LibreOffice", installCommand: "brew install --cask libreoffice")
        }

        let jobID = job.id
        let sourceURL = job.sourceURL
        guard let temporaryOutputURL = job.temporaryOutputURL else {
            throw ConversionError.destinationUnavailable(path: job.destinationURL?.path ?? "")
        }

        let stagingDirectoryURL = stagingDirectoryParentURL.appendingPathComponent(
            "FileConverter-LibreOffice-\(jobID.uuidString)-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagingOutputURL = stagingDirectoryURL.appendingPathComponent("output", isDirectory: true)
        let profileURL = stagingDirectoryURL.appendingPathComponent("profile", isDirectory: true)

        try FileManager.default.createDirectory(
            at: stagingDirectoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: stagingDirectoryURL) }

        try FileManager.default.createDirectory(at: stagingOutputURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: false)

        let args = [
            "-env:UserInstallation=\(profileURL.absoluteString)",
            "--headless",
            "--convert-to", job.preset.destinationFormat,
            "--outdir", stagingOutputURL.path,
            sourceURL.path
        ]

        let process = ExternalProcessAttempt(executableURL: sofficeURL, arguments: args)

        let startTime = Date()
        progressHandler(ConversionProgress(fractionCompleted: 0.1, elapsedTime: 0.1))

        let result: ExternalProcessResult
        do {
            result = try await processRegistry.run(process, for: jobID)
        } catch is CancellationError {
            throw ConversionError.cancelled
        }

        let exitCode = result.terminationStatus
        if exitCode == 0 {
            let outputExtension = job.preset.destinationFormat.split(separator: ":", maxSplits: 1).first.map(String.init)
                ?? job.preset.destinationFormat
            let producedFilename = sourceURL.deletingPathExtension()
                .appendingPathExtension(outputExtension)
                .lastPathComponent
            let producedURL = stagingOutputURL.appendingPathComponent(producedFilename)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: producedURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw ConversionError.externalToolFailed(
                    tool: "LibreOffice",
                    exitCode: exitCode,
                    stderr: "LibreOffice did not produce the expected output file '\(producedFilename)'."
                )
            }

            try FileManager.default.moveItem(at: producedURL, to: temporaryOutputURL)
            progressHandler(ConversionProgress(fractionCompleted: 1.0, elapsedTime: Date().timeIntervalSince(startTime)))
        } else if exitCode == 15 || exitCode == 9 {
            throw ConversionError.cancelled
        } else {
            throw ConversionError.externalToolFailed(tool: "LibreOffice", exitCode: exitCode, stderr: result.stderr)
        }
    }
}
