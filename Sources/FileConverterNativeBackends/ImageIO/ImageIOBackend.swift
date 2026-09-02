import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import FileConverterCore

public final class ImageIOBackend: ConversionBackend, @unchecked Sendable {
    public let backendType: BackendType = .imageIO
    public var isAvailable: Bool { true }

    private var cancelledJobs = Set<UUID>()
    private let lock = NSLock()

    public init() {}

    public func supports(sourceFormat: FormatDefinition, destinationFormat: FormatDefinition, preset: ConversionPreset) -> Bool {
        guard sourceFormat.category == .image && destinationFormat.category == .image else {
            return false
        }
        return destinationFormat.nativeEncoderAvailable
    }

    private func markCancelled(jobID: UUID) {
        lock.lock()
        cancelledJobs.insert(jobID)
        lock.unlock()
    }

    private func clearCancelled(jobID: UUID) {
        lock.lock()
        cancelledJobs.remove(jobID)
        lock.unlock()
    }

    private func checkCancelled(jobID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledJobs.contains(jobID)
    }

    public func cancel(jobID: UUID) async {
        markCancelled(jobID: jobID)
    }

    public func convert(job: ConversionJob, progressHandler: @escaping @Sendable (ConversionProgress) -> Void) async throws {
        let jobID = job.id
        clearCancelled(jobID: jobID)

        let sourceURL = job.sourceURL
        guard let destURL = job.temporaryOutputURL ?? job.destinationURL else {
            throw ConversionError.destinationUnavailable(path: "")
        }

        let isCancelled = { [weak self] () -> Bool in
            guard let self = self else { return false }
            return self.checkCancelled(jobID: jobID)
        }

        if isCancelled() { throw ConversionError.cancelled }

        progressHandler(ConversionProgress(fractionCompleted: 0.1, elapsedTime: 0.1))

        // Create Image Source
        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw ConversionError.malformedSource(path: sourceURL.path, reason: "Failed to create ImageIO source")
        }

        let imageCount = CGImageSourceGetCount(imageSource)
        guard imageCount > 0 else {
            throw ConversionError.malformedSource(path: sourceURL.path, reason: "Image contains no frames")
        }

        // Determine destination UTType
        guard let targetFormatDef = FormatRegistry.shared.format(forID: job.preset.destinationFormat),
              let destUTType = targetFormatDef.utTypes.first ?? UTType(filenameExtension: targetFormatDef.primaryExtension) else {
            throw ConversionError.unsupportedOutputFormat(targetFormat: job.preset.destinationFormat)
        }

        // Create Destination
        guard let imageDestination = CGImageDestinationCreateWithURL(destURL as CFURL, destUTType.identifier as CFString, imageCount, nil) else {
            throw ConversionError.destinationUnavailable(path: destURL.path)
        }

        let qualityFactor: Float
        switch job.preset.quality {
        case .low: qualityFactor = 0.5
        case .medium: qualityFactor = 0.75
        case .high: qualityFactor = 0.9
        case .veryHigh: qualityFactor = 0.98
        case .lossless: qualityFactor = 1.0
        case .custom: qualityFactor = 0.85
        }

        for index in 0..<imageCount {
            if isCancelled() { throw ConversionError.cancelled }

            autoreleasepool {
                var properties: [CFString: Any] = [:]
                if job.preset.preserveMetadata,
                   let sourceProps = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil) as? [CFString: Any] {
                    properties = sourceProps
                }

                // Apply compression quality to properties
                properties[kCGImageDestinationLossyCompressionQuality] = qualityFactor as CFNumber

                CGImageDestinationAddImageFromSource(imageDestination, imageSource, index, properties as CFDictionary)
            }

            let progressFraction = 0.2 + (0.7 * Double(index + 1) / Double(imageCount))
            progressHandler(ConversionProgress(
                fractionCompleted: progressFraction,
                processedFrames: Int64(index + 1),
                totalFrames: Int64(imageCount),
                elapsedTime: 0.5
            ))
        }

        if isCancelled() { throw ConversionError.cancelled }

        guard CGImageDestinationFinalize(imageDestination) else {
            throw ConversionError.unknown(message: "Failed to finalize ImageIO destination file.")
        }

        progressHandler(ConversionProgress(fractionCompleted: 1.0, processedFrames: Int64(imageCount), totalFrames: Int64(imageCount), elapsedTime: 1.0))
    }
}
