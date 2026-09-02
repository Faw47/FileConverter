import Foundation
import FileConverterCore

public final class ImageMagickBackend: ConversionBackend, @unchecked Sendable {
    public let backendType: BackendType = .imageMagick
    public var isAvailable: Bool {
        ExternalToolDiscovery.shared.isToolAvailable("magick")
    }

    private let processRegistry = ExternalProcessRegistry()

    public init() {}

    public func supports(sourceFormat: FormatDefinition, destinationFormat: FormatDefinition, preset: ConversionPreset) -> Bool {
        return sourceFormat.category == .image && destinationFormat.category == .image
    }

    public func cancel(jobID: UUID) async {
        processRegistry.cancel(jobID: jobID)
    }

    public func convert(job: ConversionJob, progressHandler: @escaping @Sendable (ConversionProgress) -> Void) async throws {
        guard let magickPath = ExternalToolDiscovery.shared.executablePath(for: "magick") else {
            throw ConversionError.dependencyMissing(dependencyName: "ImageMagick", installCommand: "brew install imagemagick")
        }

        let jobID = job.id
        let sourceURL = job.sourceURL
        guard let destURL = job.temporaryOutputURL ?? job.destinationURL else {
            throw ConversionError.destinationUnavailable(path: "")
        }

        var args: [String] = [sourceURL.path]

        switch job.preset.quality {
        case .low:
            args.append(contentsOf: ["-quality", "60"])
        case .medium:
            args.append(contentsOf: ["-quality", "80"])
        case .high:
            args.append(contentsOf: ["-quality", "92"])
        case .veryHigh:
            args.append(contentsOf: ["-quality", "98"])
        case .lossless:
            args.append(contentsOf: ["-quality", "100"])
        case .custom:
            break
        }

        if !job.preset.preserveMetadata {
            args.append("-strip")
        }

        args.append(destURL.path)

        let process = ExternalProcessAttempt(
            executableURL: URL(fileURLWithPath: magickPath),
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
            throw ConversionError.externalToolFailed(tool: "ImageMagick", exitCode: exitCode, stderr: result.stderr)
        }
    }
}
