import Foundation
import FileConverterCore

public final class GhostscriptBackend: ConversionBackend, @unchecked Sendable {
    public let backendType: BackendType = .ghostscript
    public var isAvailable: Bool {
        ExternalToolDiscovery.shared.isToolAvailable("gs")
    }

    private let processRegistry = ExternalProcessRegistry()

    public init() {}

    public func supports(sourceFormat: FormatDefinition, destinationFormat: FormatDefinition, preset: ConversionPreset) -> Bool {
        return sourceFormat.id == "pdf" || destinationFormat.id == "pdf"
    }

    public func cancel(jobID: UUID) async {
        processRegistry.cancel(jobID: jobID)
    }

    public func convert(job: ConversionJob, progressHandler: @escaping @Sendable (ConversionProgress) -> Void) async throws {
        guard let gsPath = ExternalToolDiscovery.shared.executablePath(for: "gs") else {
            throw ConversionError.dependencyMissing(dependencyName: "Ghostscript", installCommand: "brew install ghostscript")
        }

        let jobID = job.id
        let sourceURL = job.sourceURL
        guard let destURL = job.temporaryOutputURL ?? job.destinationURL else {
            throw ConversionError.destinationUnavailable(path: "")
        }

        var pdfSettings = "/ebook"
        switch job.preset.quality {
        case .low: pdfSettings = "/screen"
        case .medium: pdfSettings = "/ebook"
        case .high: pdfSettings = "/printer"
        case .veryHigh, .lossless, .custom: pdfSettings = "/prepress"
        }

        let args = [
            "-sDEVICE=pdfwrite",
            "-dCompatibilityLevel=1.4",
            "-dPDFSETTINGS=\(pdfSettings)",
            "-dNOPAUSE",
            "-dQUIET",
            "-dBATCH",
            "-sOutputFile=\(destURL.path)",
            sourceURL.path
        ]

        let process = ExternalProcessAttempt(
            executableURL: URL(fileURLWithPath: gsPath),
            arguments: args
        )

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
            progressHandler(ConversionProgress(fractionCompleted: 1.0, elapsedTime: Date().timeIntervalSince(startTime)))
        } else if exitCode == 15 || exitCode == 9 {
            throw ConversionError.cancelled
        } else {
            throw ConversionError.externalToolFailed(tool: "Ghostscript", exitCode: exitCode, stderr: result.stderr)
        }
    }
}
