import Foundation
import AVFoundation
import FileConverterCore

public final class AVFoundationBackend: ConversionBackend, @unchecked Sendable {
    public let backendType: BackendType = .avFoundation
    public var isAvailable: Bool { true }

    private var activeSessions: [UUID: AVAssetExportSession] = [:]
    private let lock = NSLock()

    public init() {}

    public func supports(sourceFormat: FormatDefinition, destinationFormat: FormatDefinition, preset: ConversionPreset) -> Bool {
        guard !preset.requiresExternalAudioProcessing else { return false }
        // Video to Video / Audio or Audio to Audio
        if sourceFormat.nativeDecoderAvailable && destinationFormat.nativeEncoderAvailable {
            let targetExt = destinationFormat.primaryExtension.lowercased()
            if targetExt == "qta" {
                guard #available(macOS 26.0, *) else { return false }
            }
            if targetExt == "wav" || targetExt == "aiff" {
                return sourceFormat.category == .audio || sourceFormat.category == .video
            }
            return targetExt == "mp4" || targetExt == "mov" || targetExt == "m4a" || targetExt == "qta"
        }
        return false
    }

    private func registerSession(jobID: UUID, session: AVAssetExportSession) {
        lock.lock()
        activeSessions[jobID] = session
        lock.unlock()
    }

    private func removeSession(jobID: UUID) -> AVAssetExportSession? {
        lock.lock()
        defer { lock.unlock() }
        return activeSessions.removeValue(forKey: jobID)
    }

    public func cancel(jobID: UUID) async {
        let session = removeSession(jobID: jobID)
        session?.cancelExport()
    }

    public func convert(job: ConversionJob, progressHandler: @escaping @Sendable (ConversionProgress) -> Void) async throws {
        let jobID = job.id
        let sourceURL = job.sourceURL
        guard let destURL = job.temporaryOutputURL ?? job.destinationURL else {
            throw ConversionError.destinationUnavailable(path: "")
        }

        // Check if output file already exists at temp URL and remove it
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }

        let asset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        if ["wav", "aiff", "aif"].contains(job.preset.destinationFormat.lowercased()) {
            try await convertToPCM(asset: asset, sourcePath: sourceURL.path, destinationURL: destURL, targetExtension: job.preset.destinationFormat, jobID: jobID, progressHandler: progressHandler)
            return
        }

        // Determine appropriate AVAssetExportPreset
        let exportPresetName = determineExportPreset(for: job.preset, targetFormat: job.preset.destinationFormat)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: exportPresetName) else {
            throw ConversionError.encoderUnavailable(codec: job.preset.videoCodec.rawValue, reason: "No compatible AVAssetExportSession preset found for this media asset.")
        }

        guard let outputFileType = Self.outputFileType(forTarget: job.preset.destinationFormat) else {
            throw ConversionError.incompatibleConversion(
                sourceFormat: sourceURL.pathExtension,
                targetFormat: job.preset.destinationFormat
            )
        }
        exportSession.outputURL = destURL
        exportSession.outputFileType = outputFileType
        exportSession.shouldOptimizeForNetworkUse = true

        registerSession(jobID: jobID, session: exportSession)
        defer {
            _ = removeSession(jobID: jobID)
        }

        let startTime = Date()

        // Start export
        exportSession.exportAsynchronously {}

        do {
            // Monitor progress
            while exportSession.status == .waiting || exportSession.status == .exporting {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms

                let fraction = Double(exportSession.progress)
                let elapsed = Date().timeIntervalSince(startTime)
                var eta: TimeInterval? = nil
                if fraction > 0.05 {
                    eta = (elapsed / fraction) - elapsed
                }

                progressHandler(ConversionProgress(
                    fractionCompleted: fraction,
                    elapsedTime: elapsed,
                    estimatedTimeRemaining: eta
                ))
            }
        } catch is CancellationError {
            // Task cancellation can interrupt the progress sleep before the
            // queue's backend-cancellation request reaches this session.
            // Stop the exporter here so it cannot keep writing a stale temp file.
            exportSession.cancelExport()
            throw ConversionError.cancelled
        }

        switch exportSession.status {
        case .completed:
            progressHandler(ConversionProgress(fractionCompleted: 1.0, elapsedTime: Date().timeIntervalSince(startTime)))
        case .cancelled:
            throw ConversionError.cancelled
        case .failed:
            let errorMsg = exportSession.error?.localizedDescription ?? "AVAssetExportSession failed"
            throw ConversionError.malformedSource(path: sourceURL.path, reason: errorMsg)
        default:
            break
        }
    }

    private func determineExportPreset(for preset: ConversionPreset, targetFormat: String) -> String {
        let isAudioOnly = preset.category == .audio || preset.videoCodec == .none

        if isAudioOnly {
            return AVAssetExportPresetAppleM4A
        }

        switch preset.videoCodec {
        case .hevc:
            switch preset.resolution {
            case .uhd4k:
                return AVAssetExportPresetHEVC3840x2160
            case .hd1080p:
                return AVAssetExportPresetHEVC1920x1080
            default:
                return AVAssetExportPresetHEVCHighestQuality
            }

        case .proRes:
            return AVAssetExportPresetAppleProRes422LPCM

        case .h264, .auto:
            switch preset.resolution {
            case .uhd4k:
                return AVAssetExportPreset3840x2160
            case .hd1080p:
                return AVAssetExportPreset1920x1080
            case .hd720p:
                return AVAssetExportPreset1280x720
            case .sd480p:
                return AVAssetExportPreset640x480
            default:
                switch preset.quality {
                case .low:
                    return AVAssetExportPresetMediumQuality
                case .medium, .high, .veryHigh, .lossless, .custom:
                    return AVAssetExportPresetHighestQuality
                }
            }

        default:
            return AVAssetExportPresetHighestQuality
        }
    }

    static func outputFileType(forTarget targetFormat: String) -> AVFileType? {
        switch targetFormat.lowercased() {
        case "mov":
            return .mov
        case "qta":
            if #available(macOS 26.0, *) {
                return .qta
            }
            return nil
        case "m4a":
            return .m4a
        default:
            return .mp4
        }
    }

    private func convertToPCM(
        asset: AVAsset,
        sourcePath: String,
        destinationURL: URL,
        targetExtension: String,
        jobID: UUID,
        progressHandler: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.decoderUnavailable(codec: "audio", reason: "The source has no audio track.")
        }

        let reader = try AVAssetReader(asset: asset)
        let bigEndian = ["aiff", "aif"].contains(targetExtension.lowercased())
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else {
            throw ConversionError.decoderUnavailable(codec: "audio", reason: "Could not read the source audio stream.")
        }
        reader.add(output)

        let fileType: AVFileType = bigEndian ? .aiff : .wav
        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw ConversionError.encoderUnavailable(codec: targetExtension, reason: "Could not create a PCM writer.")
        }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw ConversionError.malformedSource(path: sourcePath, reason: "Could not start the PCM conversion.")
        }
        writer.startSession(atSourceTime: .zero)

        let duration = max(0, CMTimeGetSeconds(try await asset.load(.duration)))
        let start = Date()
        while reader.status == .reading {
            try Task.checkCancellation()
            if input.isReadyForMoreMediaData, let sample = output.copyNextSampleBuffer() {
                guard input.append(sample) else {
                    throw ConversionError.destinationUnavailable(path: destinationURL.path)
                }
                let end = CMSampleBufferGetPresentationTimeStamp(sample) + CMSampleBufferGetDuration(sample)
                let seconds = CMTimeGetSeconds(end)
                progressHandler(ConversionProgress(
                    fractionCompleted: duration > 0 ? min(0.99, max(0, seconds / duration)) : 0,
                    elapsedTime: Date().timeIntervalSince(start)
                ))
            } else {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        input.markAsFinished()

        if reader.status == .failed {
            throw ConversionError.malformedSource(path: sourcePath, reason: reader.error?.localizedDescription ?? "Could not read audio.")
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? ConversionError.destinationUnavailable(path: destinationURL.path)
        }
        progressHandler(ConversionProgress(fractionCompleted: 1, elapsedTime: Date().timeIntervalSince(start)))
    }
}
