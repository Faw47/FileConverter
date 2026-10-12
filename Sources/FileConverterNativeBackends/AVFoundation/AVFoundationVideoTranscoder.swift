import AVFoundation
import CoreMedia
import FileConverterCore
import Foundation
import VideoToolbox

/// Re-encodes video with AVAssetReader/AVAssetWriter so a preset's codec,
/// bitrate, size, frame rate, audio settings, metadata choices, and HDR
/// handling are all honored (Apple's export presets ignore them).
final class AVFoundationVideoTranscoder: @unchecked Sendable {
    struct Result {
        var warnings: [String] = []
    }

    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var cancelled = false

    func cancel() {
        let (reader, writer) = lock.withLock { () -> (AVAssetReader?, AVAssetWriter?) in
            cancelled = true
            return (self.reader, self.writer)
        }
        reader?.cancelReading()
        writer?.cancelWriting()
    }

    private var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    // MARK: - Source inspection

    struct VideoSource {
        let track: AVAssetTrack
        let naturalSize: CGSize
        let transform: CGAffineTransform
        let frameRate: Double?
        let bitRateKbps: Double?
        let transferFunction: String?
        let isHDR: Bool

        var displaySize: CGSize {
            let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
            return CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
        }
    }

    static func inspect(_ track: AVAssetTrack) async throws -> VideoSource {
        let (naturalSize, transform, frameRate, dataRate, descriptions) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions
        )
        var transfer: String?
        if let description = descriptions.first,
           let extensions = CMFormatDescriptionGetExtensions(description) as? [CFString: Any] {
            transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String
        }
        let hdrTransfers: Set<String> = [
            kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String,
            kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
        ]
        return VideoSource(
            track: track,
            naturalSize: naturalSize,
            transform: transform,
            frameRate: frameRate > 0 ? Double(frameRate) : nil,
            bitRateKbps: dataRate > 0 ? Double(dataRate) / 1_000 : nil,
            transferFunction: transfer,
            isHDR: transfer.map(hdrTransfers.contains) ?? false
        )
    }

    // MARK: - Transcode

    func transcode(
        asset: AVAsset,
        to destinationURL: URL,
        fileType: AVFileType,
        preset: ConversionPreset,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Result {
        var result = Result()
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.decoderUnavailable(codec: "video", reason: "The source has no video track.")
        }
        let audioTracks = preset.audioCodec == .none ? [] : try await asset.loadTracks(withMediaType: .audio)
        let source = try await Self.inspect(videoTrack)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))

        // Output picture.
        let display = source.displaySize
        let target = VideoGeometry.targetSize(
            displayWidth: Int(display.width),
            displayHeight: Int(display.height),
            resolution: preset.resolution
        )
        let codec: AVVideoCodecType
        switch preset.videoCodec {
        case .hevc: codec = .hevc
        case .proRes: codec = .proRes422
        default: codec = .h264
        }
        let keepsHDR = source.isHDR && (codec == .hevc || codec == .proRes422)
        if source.isHDR && !keepsHDR {
            result.warnings.append("This HDR video was converted to standard range (SDR) for H.264.")
        }
        let outputFPS = preset.framerate ?? source.frameRate ?? 30

        let colorProperties: [String: String] = keepsHDR
            ? [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: source.transferFunction == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
                    ? AVVideoTransferFunction_SMPTE_ST_2084_PQ
                    : AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
            : [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]

        // Composition: orientation, scale, frame rate, and color (setting
        // BT.709 on an HDR source makes AVFoundation tone-map to SDR).
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: target.width, height: target.height)
        composition.frameDuration = CMTime(value: 1_000, timescale: CMTimeScale(max(1, (outputFPS * 1_000).rounded())))
        composition.colorPrimaries = colorProperties[AVVideoColorPrimariesKey]
        composition.colorTransferFunction = colorProperties[AVVideoTransferFunctionKey]
        composition.colorYCbCrMatrix = colorProperties[AVVideoYCbCrMatrixKey]
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        let scale = display.width > 0 ? CGFloat(target.width) / display.width : 1
        layer.setTransform(source.transform.concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        let reader = try AVAssetReader(asset: asset)
        let pixelFormat = keepsHDR
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        )
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw ConversionError.decoderUnavailable(codec: "video", reason: "macOS could not read this video track.")
        }
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true

        var compression: [String: Any] = [:]
        if codec != .proRes422 {
            let kbps = preset.videoBitrateKbps ?? VideoBitrateModel.targetKbps(
                width: target.width,
                height: target.height,
                fps: outputFPS,
                codec: codec == .hevc ? .hevc : .h264,
                quality: preset.quality,
                sourceKbps: source.bitRateKbps
            )
            compression[AVVideoAverageBitRateKey] = kbps * 1_000
            compression[AVVideoExpectedSourceFrameRateKey] = outputFPS
            if codec == .hevc {
                compression[AVVideoProfileLevelKey] = keepsHDR
                    ? kVTProfileLevel_HEVC_Main10_AutoLevel as String
                    : kVTProfileLevel_HEVC_Main_AutoLevel as String
            } else {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
        }
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: target.width,
            AVVideoHeightKey: target.height,
            AVVideoColorPropertiesKey: colorProperties
        ]
        if !compression.isEmpty {
            videoSettings[AVVideoCompressionPropertiesKey] = compression
        }
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw ConversionError.encoderUnavailable(
                codec: codec.rawValue,
                reason: "this Mac cannot encode \(target.width)×\(target.height) video with these settings"
            )
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw ConversionError.encoderUnavailable(codec: codec.rawValue, reason: "could not create the video writer")
        }
        writer.add(videoInput)

        // Every audio track, re-encoded (or passed through for "copy").
        var audioPairs: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
        for track in audioTracks {
            let pair = try await Self.makeAudioPair(track: track, preset: preset, writer: writer, fileType: fileType)
            guard let pair, reader.canAdd(pair.output) else {
                result.warnings.append("An audio track could not be converted and was left out.")
                continue
            }
            reader.add(pair.output)
            writer.add(pair.input)
            audioPairs.append(pair)
        }

        writer.metadata = try await Self.outputMetadata(for: asset, preset: preset)

        lock.withLock {
            self.reader = reader
            self.writer = writer
        }
        if isCancelled { throw ConversionError.cancelled }

        guard reader.startReading() else {
            throw ConversionError.malformedSource(
                path: destinationURL.path,
                reason: reader.error?.localizedDescription ?? "Could not start reading the video."
            )
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? ConversionError.destinationUnavailable(path: destinationURL.path)
        }
        writer.startSession(atSourceTime: .zero)

        let total = max(duration, 0.001)
        let pumps = [Pump(output: videoOutput, input: videoInput, reportsProgress: true)]
            + audioPairs.map { Pump(output: $0.output, input: $0.input, reportsProgress: false) }
        let isCancelledCheck: @Sendable () -> Bool = { [weak self] in self?.isCancelled ?? true }
        await withTaskGroup(of: Void.self) { group in
            for pump in pumps {
                group.addTask {
                    await pump.run(isCancelled: isCancelledCheck) { seconds in
                        progress(min(0.99, max(0, seconds / total)))
                    }
                }
            }
        }

        if isCancelled || Task.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw ConversionError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw ConversionError.malformedSource(
                path: destinationURL.path,
                reason: reader.error?.localizedDescription ?? "Could not read the video."
            )
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? ConversionError.destinationUnavailable(path: destinationURL.path)
        }
        progress(1)
        return result
    }

    // MARK: - Audio

    private static func makeAudioPair(
        track: AVAssetTrack,
        preset: ConversionPreset,
        writer: AVAssetWriter,
        fileType: AVFileType
    ) async throws -> (output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)? {
        if preset.audioCodec == .copy {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let description = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: description)
            return writer.canAdd(input) ? (output, input) : nil
        }

        var sampleRate = 48_000.0
        var channels = 2
        var layoutData: Data?
        if let description = try await track.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
            if asbd.mChannelsPerFrame > 0 { channels = Int(asbd.mChannelsPerFrame) }
            var size = 0
            if let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size), size > 0 {
                layoutData = Data(bytes: layout, count: size)
            }
        }
        if let explicit = preset.audioSampleRate { sampleRate = Double(explicit) }
        if let explicit = preset.audioChannels {
            channels = explicit
            layoutData = nil
        }
        if channels > 2 && layoutData == nil {
            channels = 2
        }

        let isALAC = preset.audioCodec == .alac
        if !isALAC { sampleRate = AVFoundationBackend.aacSampleRate(for: sampleRate) }
        var decode: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: isALAC ? 24 : 32,
            AVLinearPCMIsFloatKey: !isALAC,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        var encode: [String: Any] = isALAC
            ? [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitDepthHintKey: 24
            ]
            : [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: AVFoundationBackend.aacBitRate(
                    requestedKbps: preset.audioBitrateKbps ?? 192,
                    channels: channels
                )
            ]
        if let layoutData {
            decode[AVChannelLayoutKey] = layoutData
            encode[AVChannelLayoutKey] = layoutData
        }
        guard writer.canApply(outputSettings: encode, forMediaType: .audio) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: decode)
        output.alwaysCopiesSampleData = false
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: encode)
        input.expectsMediaDataInRealTime = false
        return writer.canAdd(input) ? (output, input) : nil
    }

    // MARK: - Metadata

    static let locationIdentifiers: Set<AVMetadataIdentifier> = [
        .quickTimeMetadataLocationISO6709,
        .quickTimeUserDataLocationISO6709,
        .commonIdentifierLocation
    ]

    static func outputMetadata(for asset: AVAsset, preset: ConversionPreset) async throws -> [AVMetadataItem] {
        guard preset.preserveMetadata else { return [] }
        let items = try await asset.load(.metadata)
        guard preset.removeLocationData ?? true else { return items }
        return items.filter { item in
            guard let identifier = item.identifier else { return true }
            return !locationIdentifiers.contains(identifier)
        }
    }
}

/// Moves samples from one reader output to one writer input.
private final class Pump: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    let reportsProgress: Bool
    private let queue = DispatchQueue(label: "io.fileconverter.transcode.pump")

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput, reportsProgress: Bool) {
        self.output = output
        self.input = input
        self.reportsProgress = reportsProgress
    }

    func run(isCancelled: @escaping @Sendable () -> Bool, progress: @escaping @Sendable (Double) -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    if isCancelled() {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    guard let sample = output.copyNextSampleBuffer() else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    if reportsProgress {
                        let time = CMSampleBufferGetPresentationTimeStamp(sample)
                        let seconds = CMTimeGetSeconds(time)
                        if seconds.isFinite { progress(seconds) }
                    }
                    if !input.append(sample) {
                        finished = true
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
