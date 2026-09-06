import Foundation

/// A single output that a backend will create for a conversion job.
/// Backends may return more than one output (for example one image per PDF page).
public struct ConversionOutputRequirement: Sendable, Hashable {
    public let extensionName: String
    public let suffix: String?

    public init(extensionName: String, suffix: String? = nil) {
        self.extensionName = extensionName.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        self.suffix = suffix
    }
}

public struct PlannedConversionOutput: Sendable, Hashable {
    public let finalURL: URL
    public let temporaryURL: URL

    public init(finalURL: URL, temporaryURL: URL) {
        self.finalURL = finalURL
        self.temporaryURL = temporaryURL
    }
}

/// Stable, human-readable names for conversions that produce more than one file.
/// The width grows with the batch so Finder's alphabetical order remains the
/// actual conversion order for long recordings and large PDFs.
public enum ConversionOutputSequence {
    public static func suffix(
        prefix: String,
        index: Int,
        totalCount: Int,
        minimumWidth: Int = 2
    ) -> String {
        let safeIndex = max(1, index)
        let width = max(max(1, minimumWidth), String(max(safeIndex, totalCount)).count)
        return "\(prefix)-" + String(format: "%0\(width)d", safeIndex)
    }
}

public struct BackendConversionResult: Sendable {
    public let warnings: [String]

    public init(warnings: [String] = []) {
        self.warnings = warnings
    }
}

public protocol ConversionBackend: Sendable {
    var backendType: BackendType { get }
    var isAvailable: Bool { get }

    func supports(sourceFormat: FormatDefinition, destinationFormat: FormatDefinition, preset: ConversionPreset) -> Bool
    func convert(job: ConversionJob, progressHandler: @escaping @Sendable (ConversionProgress) -> Void) async throws
    func cancel(jobID: UUID) async

    /// Returns the outputs that will be produced. The default is one output using the preset extension.
    func outputRequirements(for job: ConversionJob) async throws -> [ConversionOutputRequirement]

    /// Multi-output entry point. Existing backends can keep implementing `convert(job:progressHandler:)`.
    func convert(
        job: ConversionJob,
        outputs: [PlannedConversionOutput],
        progressHandler: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws -> BackendConversionResult
}

public extension ConversionBackend {
    func outputRequirements(for job: ConversionJob) async throws -> [ConversionOutputRequirement] {
        [ConversionOutputRequirement(extensionName: job.preset.destinationFormat)]
    }

    func convert(
        job: ConversionJob,
        outputs: [PlannedConversionOutput],
        progressHandler: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws -> BackendConversionResult {
        guard let first = outputs.first else {
            throw ConversionError.destinationUnavailable(path: "")
        }
        var singleOutputJob = job
        singleOutputJob.destinationURL = first.finalURL
        singleOutputJob.temporaryOutputURL = first.temporaryURL
        _ = outputs.dropFirst()
        try await convert(job: singleOutputJob, progressHandler: progressHandler)
        return BackendConversionResult()
    }
}
