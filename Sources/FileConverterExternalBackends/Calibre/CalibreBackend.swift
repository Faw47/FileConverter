import Foundation
import FileConverterCore

/// Converts EPUB books to PDF with Calibre's dedicated e-book renderer.
/// LibreOffice does not provide equivalent EPUB import fidelity.
public final class CalibreBackend: ConversionBackend, @unchecked Sendable {
    public let backendType: BackendType = .calibre
    public var isAvailable: Bool {
        executableURLOverride != nil || ExternalToolDiscovery.shared.isToolAvailable("ebook-convert")
    }

    private let processRegistry = ExternalProcessRegistry()
    private let executableURLOverride: URL?

    public init() {
        executableURLOverride = nil
    }

    init(executableURL: URL) {
        executableURLOverride = executableURL
    }

    public func supports(sourceFormat: FormatDefinition, destinationFormat: FormatDefinition, preset: ConversionPreset) -> Bool {
        sourceFormat.id == "epub" && destinationFormat.id == "pdf"
    }

    public func cancel(jobID: UUID) async {
        processRegistry.cancel(jobID: jobID)
    }

    public func convert(
        job: ConversionJob,
        progressHandler: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws {
        guard let executableURL = executableURLOverride
            ?? ExternalToolDiscovery.shared.executablePath(for: "ebook-convert").map({ URL(fileURLWithPath: $0) }) else {
            throw ConversionError.dependencyMissing(
                dependencyName: "Calibre",
                installCommand: "brew install --cask calibre"
            )
        }
        guard let destinationURL = job.temporaryOutputURL ?? job.destinationURL else {
            throw ConversionError.destinationUnavailable(path: "")
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }

        let startTime = Date()
        progressHandler(ConversionProgress(fractionCompleted: 0.05, elapsedTime: 0))
        let process = ExternalProcessAttempt(
            executableURL: executableURL,
            arguments: [job.sourceURL.path, destinationURL.path],
            timeout: 20 * 60
        )

        let result: ExternalProcessResult
        do {
            result = try await processRegistry.run(process, for: job.id)
        } catch is CancellationError {
            throw ConversionError.cancelled
        } catch ExternalProcessRunnerError.timedOut {
            throw ConversionError.externalToolFailed(
                tool: "Calibre",
                exitCode: -1,
                stderr: "The EPUB conversion exceeded the twenty-minute safety limit."
            )
        }

        switch result.terminationStatus {
        case 0:
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw ConversionError.externalToolFailed(
                    tool: "Calibre",
                    exitCode: 0,
                    stderr: "Calibre completed without producing a PDF output file."
                )
            }
            progressHandler(ConversionProgress(fractionCompleted: 1, elapsedTime: Date().timeIntervalSince(startTime)))
        case 9, 15:
            throw ConversionError.cancelled
        default:
            throw ConversionError.externalToolFailed(
                tool: "Calibre",
                exitCode: result.terminationStatus,
                stderr: result.stderr
            )
        }
    }
}
