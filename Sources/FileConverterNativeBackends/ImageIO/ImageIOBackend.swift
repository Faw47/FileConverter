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
        return destinationFormat.nativeEncoderAvailable && NativeImageCodecs.canEncode(destinationFormat)
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

        progressHandler(ConversionProgress(fractionCompleted: 0.1, elapsedTime: 0))

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

        let firstProps = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        let sourceWidth = firstProps[kCGImagePropertyPixelWidth] as? Int ?? 0
        let sourceHeight = firstProps[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maxPixelSize = ImageGeometry.maxPixelSize(
            resolution: job.preset.resolution,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )

        // Memory limits: a resize decodes at reduced size, so it can handle
        // much larger sources than a full-size conversion.
        let megapixels = (sourceWidth * sourceHeight) / 1_000_000
        let limit = maxPixelSize == nil ? ImageGeometry.fullSizeLimitMegapixels : ImageGeometry.resizeLimitMegapixels
        if megapixels > limit || megapixels * framesToWrite > limit * 3 {
            throw ConversionError.imageTooLarge(width: sourceWidth, height: sourceHeight, limitMegapixels: limit)
        }

        // Create Destination
        guard let imageDestination = CGImageDestinationCreateWithURL(destURL as CFURL, destUTType.identifier as CFString, framesToWrite, nil) else {
            throw ConversionError.encoderUnavailable(
                codec: targetFormatDef.name,
                reason: "macOS cannot write \(targetFormatDef.name) files on this Mac."
            )
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

        let preserveMetadata = job.preset.preserveMetadata
        let removeLocation = job.preset.removeLocationData ?? true
        let start = Date()

        for index in 0..<framesToWrite {
            if isCancelled() { throw ConversionError.cancelled }

            try autoreleasepool {
                let sourceProps = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil) as? [CFString: Any] ?? [:]
                if maxPixelSize == nil && preserveMetadata {
                    // Fast path: re-encode the frame with its metadata;
                    // properties set to kCFNull are removed.
                    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: qualityFactor]
                    if removeLocation {
                        properties[kCGImagePropertyGPSDictionary] = kCFNull
                    }
                    CGImageDestinationAddImageFromSource(imageDestination, imageSource, index, properties as CFDictionary)
                    return
                }

                // Decode (downsampled when resizing) and write only the
                // metadata the preset keeps. AddImageFromSource would copy
                // all source metadata regardless.
                let image: CGImage?
                var properties: [CFString: Any] = [:]
                if let maxPixelSize {
                    image = CGImageSourceCreateThumbnailAtIndex(imageSource, index, [
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceShouldCacheImmediately: true
                    ] as CFDictionary)
                    // The transform is applied, so the pixels are upright.
                    properties[kCGImagePropertyOrientation] = 1
                } else {
                    image = CGImageSourceCreateImageAtIndex(imageSource, index, nil)
                    if let orientation = sourceProps[kCGImagePropertyOrientation] {
                        properties[kCGImagePropertyOrientation] = orientation
                    }
                }
                guard let image else {
                    throw ConversionError.malformedSource(path: sourceURL.path, reason: "Frame \(index + 1) could not be decoded")
                }
                if preserveMetadata {
                    for key in [kCGImagePropertyExifDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary,
                                kCGImagePropertyGPSDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight,
                                kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary] {
                        if let value = sourceProps[key] { properties[key] = value }
                    }
                    if removeLocation { properties.removeValue(forKey: kCGImagePropertyGPSDictionary) }
                    if maxPixelSize != nil, var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                        tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
                        properties[kCGImagePropertyTIFFDictionary] = tiff
                    }
                } else if let delay = (sourceProps[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFDelayTime] {
                    // Keep animation timing even without metadata.
                    properties[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: delay]
                }
                properties[kCGImageDestinationLossyCompressionQuality] = qualityFactor
                let frame = targetFormatDef.supportsAlpha ? image : (ImageGeometry.flattenedOnWhite(image) ?? image)
                CGImageDestinationAddImage(imageDestination, frame, properties as CFDictionary)
            }

            let progressFraction = 0.2 + (0.7 * Double(index + 1) / Double(framesToWrite))
            progressHandler(ConversionProgress(
                fractionCompleted: progressFraction,
                processedFrames: Int64(index + 1),
                totalFrames: Int64(framesToWrite),
                elapsedTime: Date().timeIntervalSince(start)
            ))
        }

        if isCancelled() { throw ConversionError.cancelled }

        guard CGImageDestinationFinalize(imageDestination) else {
            throw ConversionError.unknown(message: "Failed to finalize ImageIO destination file.")
        }

        progressHandler(ConversionProgress(fractionCompleted: 1.0, processedFrames: Int64(framesToWrite), totalFrames: Int64(framesToWrite), elapsedTime: Date().timeIntervalSince(start)))
    }
}
