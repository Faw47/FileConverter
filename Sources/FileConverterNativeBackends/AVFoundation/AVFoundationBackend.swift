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
        // Video to Video / Audio or Audio to Audio
        if sourceFormat.nativeDecoderAvailable && destinationFormat.nativeEncoderAvailable {
            let targetExt = destinationFormat.primaryExtension.lowercased()
            return targetExt == "mp4" || targetExt == "mov" || targetExt == "m4a" || targetExt == "wav" || targetExt == "aiff" || targetExt == "qta"
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

        // Determine appropriate AVAssetExportPreset
        let exportPresetName = determineExportPreset(for: job.preset, targetFormat: job.preset.destinationFormat)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: exportPresetName) else {
            throw ConversionError.encoderUnavailable(codec: job.preset.videoCodec.rawValue, reason: "No compatible AVAssetExportSession preset found for this media asset.")
        }

        exportSession.outputURL = destURL
        exportSession.outputFileType = determineOutputFileType(forTarget: job.preset.destinationFormat)
        exportSession.shouldOptimizeForNetworkUse = true

        registerSession(jobID: jobID, session: exportSession)
        defer {
            _ = removeSession(jobID: jobID)
        }

        let startTime = Date()

        // Start export
        exportSession.exportAsynchronously {}

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

    private func determineOutputFileType(forTarget targetFormat: String) -> AVFileType {
        switch targetFormat.lowercased() {
        case "mov", "qta":
            return .mov
        case "m4a":
            return .m4a
        case "wav":
            return .wav
        case "aiff", "aif":
            return .aiff
        default:
            return .mp4
        }
    }
}
