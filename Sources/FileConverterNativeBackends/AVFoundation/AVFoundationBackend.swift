import Foundation
import AVFoundation
import CoreMedia
import CoreAudio
import FileConverterCore

public final class AVFoundationBackend: ConversionBackend, @unchecked Sendable {
    public let backendType: BackendType = .avFoundation
    public var isAvailable: Bool { true }

    private var activeSessions: [UUID: AVAssetExportSession] = [:]
    private var activePCMSessions: [UUID: (reader: AVAssetReader, writer: AVAssetWriter)] = [:]
    private var cancelledJobs = Set<UUID>()
    private let lock = NSLock()

    public init() {}

    public func supports(sourceFormat: FormatDefinition, destinationFormat: FormatDefinition, preset: ConversionPreset) -> Bool {
        guard !preset.requiresExternalAudioProcessing else { return false }
        // Video to Video / Audio or Audio to Audio
        if sourceFormat.nativeDecoderAvailable && destinationFormat.nativeEncoderAvailable {
            let targetExt = destinationFormat.primaryExtension.lowercased()
            if targetExt == "qta" {
                guard #available(macOS 14.0, *) else { return false }
            }
            if targetExt == "wav" || targetExt == "aiff" {
                return sourceFormat.category == .audio || sourceFormat.category == .video
            }
            return targetExt == "mp4" || targetExt == "mov" || targetExt == "m4a" || targetExt == "qta"
        }
        return false
    }

    private func checkCancelled(jobID: UUID) -> Bool {
        lock.withLock { cancelledJobs.contains(jobID) }
    }

    private func clearCancelled(jobID: UUID) {
        lock.withLock { _ = cancelledJobs.remove(jobID) }
    }

    private func registerSession(jobID: UUID, session: AVAssetExportSession) -> Bool {
        lock.withLock {
            if cancelledJobs.contains(jobID) {
                session.cancelExport()
                return false
            }
            activeSessions[jobID] = session
            return true
        }
    }

    private func removeSession(jobID: UUID) -> AVAssetExportSession? {
        lock.withLock { activeSessions.removeValue(forKey: jobID) }
    }

    private func registerPCMSession(jobID: UUID, reader: AVAssetReader, writer: AVAssetWriter) -> Bool {
        lock.withLock {
            if cancelledJobs.contains(jobID) {
                reader.cancelReading()
                writer.cancelWriting()
                return false
            }
            activePCMSessions[jobID] = (reader, writer)
            return true
        }
    }

    private func removePCMSession(jobID: UUID) -> (reader: AVAssetReader, writer: AVAssetWriter)? {
        lock.withLock { activePCMSessions.removeValue(forKey: jobID) }
    }

    public func cancel(jobID: UUID) async {
        let (session, pcm) = lock.withLock { () -> (AVAssetExportSession?, (reader: AVAssetReader, writer: AVAssetWriter)?) in
            cancelledJobs.insert(jobID)
            let s = activeSessions.removeValue(forKey: jobID)
            let p = activePCMSessions.removeValue(forKey: jobID)
            return (s, p)
        }

        session?.cancelExport()
        pcm?.reader.cancelReading()
        pcm?.writer.cancelWriting()
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

        // Check if output file already exists at temp URL and remove it
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }

        let asset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        if Self.isAudioOnlyOutput(job.preset) {
            try await convertAudio(asset: asset, sourcePath: sourceURL.path, destinationURL: destURL, targetExtension: job.preset.destinationFormat, preset: job.preset, jobID: jobID, progressHandler: progressHandler)
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

        guard registerSession(jobID: jobID, session: exportSession) else {
            throw ConversionError.cancelled
        }
        defer {
            _ = removeSession(jobID: jobID)
        }

        let startTime = Date()

        try Task.checkCancellation()
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
            if #available(macOS 14.0, *) {
                // The named `.qta` constant is only present in newer macOS
                // SDKs. Construct the documented UTI so this package still
                // compiles with the macOS 14 SDK used for the minimum target.
                return AVFileType(rawValue: "com.apple.quicktime-audio")
            }
            return nil
        case "m4a":
            return .m4a
        default:
            return .mp4
        }
    }

    /// Audio-only outputs are written with AVAssetReader/AVAssetWriter so the
    /// preset's codec, bitrate, sample rate, channel count, and bit depth are
    /// honored. (AVAssetExportPresetAppleM4A always produces 256 kbps AAC.)
    static func isAudioOnlyOutput(_ preset: ConversionPreset) -> Bool {
        let ext = preset.destinationFormat.lowercased()
        return preset.category == .audio
            || preset.videoCodec == .none
            || ["m4a", "qta", "wav", "aiff", "aif"].contains(ext)
    }

    enum NativeAudioTarget: Equatable {
        case pcm(bigEndian: Bool)
        case aac
        case alac
    }

    static func audioTarget(for preset: ConversionPreset) -> NativeAudioTarget {
        let ext = preset.destinationFormat.lowercased()
        if ext == "wav" { return .pcm(bigEndian: false) }
        if ext == "aiff" || ext == "aif" { return .pcm(bigEndian: true) }
        switch preset.audioCodec {
        case .alac: return .alac
        case .wav: return .pcm(bigEndian: false)
        case .aiff: return .pcm(bigEndian: true)
        default: return .aac
        }
    }

    /// AAC supports these rates; anything else is mapped to the nearest
    /// supported rate not above the requested one (minimum 8 kHz).
    static func aacSampleRate(for requested: Double) -> Double {
        let supported: [Double] = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]
        return supported.last { $0 <= requested } ?? supported[0]
    }

    /// Apple's AAC encoder accepts roughly 32–160 kbps per channel.
    static func aacBitRate(requestedKbps: Int?, channels: Int) -> Int {
        let perChannelMin = 32_000, perChannelMax = 160_000
        let requested = (requestedKbps ?? 256) * 1_000
        let count = max(1, channels)
        return min(max(requested, perChannelMin * count), perChannelMax * count)
    }

    /// Bit depth carried by a lossless or PCM source, if it reports one.
    static func sourceBitDepth(_ asbd: AudioStreamBasicDescription) -> Int? {
        if asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBitsPerChannel > 0 {
            return Int(asbd.mBitsPerChannel)
        }
        if asbd.mFormatID == kAudioFormatAppleLossless || asbd.mFormatID == kAudioFormatFLAC {
            switch asbd.mFormatFlags {
            case 1: return 16
            case 2: return 20
            case 3: return 24
            case 4: return 32
            default: return nil
            }
        }
        return nil
    }

    private func convertAudio(
        asset: AVAsset,
        sourcePath: String,
        destinationURL: URL,
        targetExtension: String,
        preset: ConversionPreset,
        jobID: UUID,
        progressHandler: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.decoderUnavailable(codec: "audio", reason: "The source has no audio track.")
        }

        var sampleRate: Double = 44100.0
        var channels: Int = 2
        var channelLayoutData: Data? = nil
        var sourceBits: Int? = nil
        if let descriptions = try? await track.load(.formatDescriptions),
           let firstDesc = descriptions.first {
            let audioDesc = firstDesc as CMAudioFormatDescription
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioDesc)?.pointee {
                if asbd.mSampleRate > 0 {
                    sampleRate = asbd.mSampleRate
                }
                if asbd.mChannelsPerFrame > 0 {
                    channels = Int(asbd.mChannelsPerFrame)
                }
                sourceBits = Self.sourceBitDepth(asbd)
            }
            var layoutSize: Int = 0
            if let layoutPtr = CMAudioFormatDescriptionGetChannelLayout(audioDesc, sizeOut: &layoutSize), layoutSize > 0 {
                channelLayoutData = Data(bytes: layoutPtr, count: layoutSize)
            }
        }

        if let explicitRate = preset.audioSampleRate {
            sampleRate = Double(explicitRate)
        }
        if let explicitChannels = preset.audioChannels {
            channels = explicitChannels
            channelLayoutData = nil
        }

        let target = Self.audioTarget(for: preset)
        if target == .aac {
            sampleRate = Self.aacSampleRate(for: sampleRate)
        }

        var layoutData: Data? = channelLayoutData
        if layoutData == nil, channels > 2 {
            var layout = AudioChannelLayout()
            if channels == 6 {
                layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
                layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            } else if channels == 8 {
                layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_7_1_A
                layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            } else {
                channels = 2
            }
        }

        let reader = try AVAssetReader(asset: asset)
        // Decoded samples handed from reader to writer.
        var decodeSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMIsNonInterleaved: false
        ]
        // Encoded format written to the file.
        var encodeSettings: [String: Any]
        let fileType: AVFileType
        switch target {
        case .pcm(let bigEndian):
            let bitDepth = preset.audioBitDepth ?? .bit16
            decodeSettings[AVLinearPCMBitDepthKey] = bitDepth.bitDepthNumber
            decodeSettings[AVLinearPCMIsFloatKey] = bitDepth.isFloat
            decodeSettings[AVLinearPCMIsBigEndianKey] = bigEndian
            encodeSettings = decodeSettings
            fileType = bigEndian ? .aiff : .wav
        case .aac:
            decodeSettings[AVLinearPCMBitDepthKey] = 32
            decodeSettings[AVLinearPCMIsFloatKey] = true
            decodeSettings[AVLinearPCMIsBigEndianKey] = false
            encodeSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: Self.aacBitRate(requestedKbps: preset.audioBitrateKbps, channels: channels)
            ]
            fileType = Self.outputFileType(forTarget: targetExtension) ?? .m4a
        case .alac:
            let requestedBits = preset.audioBitDepth?.bitDepthNumber ?? sourceBits ?? 16
            let bits = [16, 20, 24, 32].contains(requestedBits) ? requestedBits : 16
            decodeSettings[AVLinearPCMBitDepthKey] = bits == 20 ? 24 : bits
            decodeSettings[AVLinearPCMIsFloatKey] = false
            decodeSettings[AVLinearPCMIsBigEndianKey] = false
            encodeSettings = [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitDepthHintKey: bits
            ]
            fileType = Self.outputFileType(forTarget: targetExtension) ?? .m4a
        }
        if let layoutData {
            decodeSettings[AVChannelLayoutKey] = layoutData
            encodeSettings[AVChannelLayoutKey] = layoutData
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: decodeSettings)
        guard reader.canAdd(output) else {
            throw ConversionError.decoderUnavailable(codec: "audio", reason: "Could not read the source audio stream.")
        }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: fileType)
        guard writer.canApply(outputSettings: encodeSettings, forMediaType: .audio) else {
            throw ConversionError.encoderUnavailable(
                codec: targetExtension,
                reason: "macOS cannot encode audio with these settings (\(Int(sampleRate)) Hz, \(channels) channels)."
            )
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: encodeSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw ConversionError.encoderUnavailable(codec: targetExtension, reason: "Could not create an audio writer.")
        }
        writer.add(input)
        guard reader.startReading() else {
            throw ConversionError.malformedSource(path: sourcePath, reason: reader.error?.localizedDescription ?? "Could not start reading the source audio.")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? ConversionError.destinationUnavailable(path: destinationURL.path)
        }
        writer.startSession(atSourceTime: .zero)
        guard registerPCMSession(jobID: jobID, reader: reader, writer: writer) else {
            throw ConversionError.cancelled
        }
        defer {
            _ = removePCMSession(jobID: jobID)
        }

        let duration = max(0, CMTimeGetSeconds(try await asset.load(.duration)))
        let start = Date()
        do {
            while reader.status == .reading {
                try Task.checkCancellation()
                if checkCancelled(jobID: jobID) {
                    throw CancellationError()
                }
                if writer.status != .writing {
                    break
                }
                if !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(10))
                    continue
                }
                guard let sample = output.copyNextSampleBuffer() else {
                    break
                }
                guard input.append(sample) else {
                    throw writer.error ?? ConversionError.destinationUnavailable(path: destinationURL.path)
                }
                let end = CMSampleBufferGetPresentationTimeStamp(sample) + CMSampleBufferGetDuration(sample)
                let seconds = CMTimeGetSeconds(end)
                if seconds.isFinite && duration > 0 {
                    progressHandler(ConversionProgress(
                        fractionCompleted: min(0.99, max(0, seconds / duration)),
                        elapsedTime: Date().timeIntervalSince(start)
                    ))
                }
                await Task.yield()
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            if error is CancellationError {
                throw ConversionError.cancelled
            }
            throw error
        }

        if Task.isCancelled || checkCancelled(jobID: jobID) || reader.status == .cancelled || writer.status == .cancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw ConversionError.cancelled
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw ConversionError.malformedSource(path: sourcePath, reason: reader.error?.localizedDescription ?? "Could not read audio.")
        }

        if writer.status == .failed {
            reader.cancelReading()
            throw writer.error ?? ConversionError.destinationUnavailable(path: destinationURL.path)
        }

        input.markAsFinished()

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? ConversionError.destinationUnavailable(path: destinationURL.path)
        }
        progressHandler(ConversionProgress(fractionCompleted: 1, elapsedTime: Date().timeIntervalSince(start)))
    }
}
