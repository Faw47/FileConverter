import Foundation

public protocol ConversionBackend: Sendable {
    var backendType: BackendType { get }
    var isAvailable: Bool { get }

    func supports(sourceFormat: FormatDefinition, destinationFormat: FormatDefinition, preset: ConversionPreset) -> Bool
    func convert(job: ConversionJob, progressHandler: @escaping @Sendable (ConversionProgress) -> Void) async throws
    func cancel(jobID: UUID) async
}
