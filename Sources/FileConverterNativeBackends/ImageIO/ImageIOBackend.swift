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
        lock.withLock {
            _ = cancelledJobs.insert(jobID)
        }
    }

    private func clearCancelled(jobID: UUID) {
        lock.withLock {
            _ = cancelledJobs.remove(jobID)
        }
    }

    private func checkCancelled(jobID: UUID) -> Bool {
        lock.withLock {
            cancelledJobs.contains(jobID)
        }
    }

    public func cancel(jobID: UUID) async {
        markCancelled(jobID: jobID)
    }

    public func convert(job: ConversionJob, progressHandler: @escaping @Sendable (ConversionProgress) -> Void) async throws {
        let jobID = job.id
        if Task.isCancelled || checkCancelled(jobID: jobID) {
            throw ConversionError.cancelled
        }
        defer { clearCancelled(jobID: jobID) }

        let sourceURL = job.sourceURL
        guard let destURL = job.temporaryOutputURL ?? job.destinationURL else {
            throw ConversionError.destinationUnavailable(path: "")
        }

        let destDir = destURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let isCancelled = { [weak self] () -> Bool in
            if Task.isCancelled { return true }
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

        // TASK-030: Enforce ImageIO frame semantics. Single-frame destinations write only frame 0.
        let isMultiFrameDestination = destUTType.conforms(to: .gif)
            || destUTType.conforms(to: .tiff)
            || destUTType.identifier == "public.heif"
            || destUTType.identifier == "public.heics"
        let framesToWrite = isMultiFrameDestination ? imageCount : 1

        // TASK-031: Decode safety checks against decompression bombs.
        if let firstProps = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
           let width = firstProps[kCGImagePropertyPixelWidth] as? Int,
           let height = firstProps[kCGImagePropertyPixelHeight] as? Int {
            let megapixels = (Int64(width) * Int64(height)) / 1_000_000
            if megapixels > 100 || (megapixels * Int64(framesToWrite)) > 300 {
                throw ConversionError.malformedSource(
                    path: sourceURL.path,
                    reason: "Image dimensions exceed safety limit (\(width)x\(height), \(framesToWrite) frame(s))."
                )
            }
        }

        // Create Destination
        guard let imageDestination = CGImageDestinationCreateWithURL(destURL as CFURL, destUTType.identifier as CFString, framesToWrite, nil) else {
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

        for index in 0..<framesToWrite {
            if isCancelled() { throw ConversionError.cancelled }

            autoreleasepool {
                var properties: [CFString: Any] = [:]
                if let sourceProps = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil) as? [CFString: Any] {
                    if job.preset.preserveMetadata {
                        properties = sourceProps
                    } else if let orientation = sourceProps[kCGImagePropertyOrientation] {
                        properties[kCGImagePropertyOrientation] = orientation
                    }
                }

                // Apply compression quality to properties
                properties[kCGImageDestinationLossyCompressionQuality] = qualityFactor as CFNumber

                CGImageDestinationAddImageFromSource(imageDestination, imageSource, index, properties as CFDictionary)
            }

            let progressFraction = 0.2 + (0.7 * Double(index + 1) / Double(framesToWrite))
            progressHandler(ConversionProgress(
                fractionCompleted: progressFraction,
                processedFrames: Int64(index + 1),
                totalFrames: Int64(framesToWrite),
                elapsedTime: 0.5
            ))
        }

        if isCancelled() { throw ConversionError.cancelled }

        guard CGImageDestinationFinalize(imageDestination) else {
            throw ConversionError.unknown(message: "Failed to finalize ImageIO destination file.")
        }

        progressHandler(ConversionProgress(fractionCompleted: 1.0, processedFrames: Int64(framesToWrite), totalFrames: Int64(framesToWrite), elapsedTime: 1.0))
    }
}
