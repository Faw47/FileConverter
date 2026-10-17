import Foundation
import FileConverterCore

public final class FFmpegBackend: ConversionBackend, @unchecked Sendable {
    public let backendType: BackendType = .ffmpeg
    public var isAvailable: Bool {
        executablePathProvider("ffmpeg") != nil
    }

    private let processRegistry = ExternalProcessRegistry()
    private let executablePathProvider: @Sendable (String) -> String?

    public init() {
        executablePathProvider = { toolName in
            ExternalToolDiscovery.shared.executablePath(for: toolName)
        }
    }

    init(executablePathProvider: @escaping @Sendable (String) -> String?) {
        self.executablePathProvider = executablePathProvider
    }

    public func supports(sourceFormat: FormatDefinition, destinationFormat: FormatDefinition, preset: ConversionPreset) -> Bool {
        if preset.requiresExternalAudioProcessing {
            guard sourceFormat.category == .audio, destinationFormat.category == .audio else {
                return false
            }
        }
        let supportsFormats = (sourceFormat.category == .video || sourceFormat.category == .audio) &&
            (destinationFormat.category == .video || destinationFormat.category == .audio || destinationFormat.id == "gif")
        guard supportsFormats else { return false }

        // Keep the backend visible as unavailable until the binary scan
        // completes. Once FFmpeg is known to exist, advertise only presets
        // whose encoders were actually reported by this installation.
        guard isAvailable else { return true }
        guard let encoders = ExternalToolDiscovery.shared.cachedAvailableFFmpegEncoders() else { return false }
        return missingRequiredEncoder(
            preset: preset,
            destinationFormat: destinationFormat,
            availableEncoders: encoders
        ) == nil
    }

    /// Hardware (VideoToolbox) encoders use a bitrate instead of CRF; software
    /// encoders use CRF and ignore a bitrate when CRF is set.
    public func ignoredSettings(for preset: ConversionPreset, source: FormatDefinition) -> Set<PresetSettingKey> {
        let encoders = ExternalToolDiscovery.shared.cachedAvailableFFmpegEncoders() ?? []
        let wantsHardware = preset.hardwareAcceleration != .softwareOnly
        var codec = preset.videoCodec
        if codec == .auto { codec = preset.destinationFormat == "webm" ? .vp9 : .h264 }
        switch codec {
        case .h264 where wantsHardware && encoders.contains("h264_videotoolbox"),
             .hevc where wantsHardware && encoders.contains("hevc_videotoolbox"):
            return [.crf]
        case .h264, .hevc:
            return preset.crf != nil ? [.videoBitrate] : []
        case .vp9, .av1:
            return [.videoBitrate, .hardwareAcceleration]
        case .proRes:
            return [.crf, .videoBitrate]
        default:
            return []
        }
    }

    public func cancel(jobID: UUID) async {
        processRegistry.cancel(jobID: jobID)
    }

    public func outputRequirements(for job: ConversionJob) async throws -> [ConversionOutputRequirement] {
        if job.preset.audioCodec == .copy {
            try requireFFprobe()
            guard let sourceCodec = try await probeAudioCodec(sourceURL: job.sourceURL, jobID: job.id) else {
                throw ConversionError.malformedSource(
                    path: job.sourceURL.path,
                    reason: "Direct Stream Copy requires an identifiable audio stream in the source file."
                )
            }
            let destExt = job.preset.destinationFormat.lowercased()
            if !Self.isMuxerCompatible(sourceAudioCodec: sourceCodec, destinationFormat: destExt) {
                throw ConversionError.invalidPreset(
                    reason: "Direct Stream Copy cannot mux '\(sourceCodec)' audio into '.\(destExt)' container. Choose a compatible container (e.g. .m4a) or transcode the audio."
                )
            }
        }

        guard let splitDuration = job.preset.audioSplitDurationSeconds else {
            return [ConversionOutputRequirement(extensionName: job.preset.destinationFormat)]
        }
        guard splitDuration > 0,
              let sourceFormat = FormatDetector.detect(url: job.sourceURL).format,
              sourceFormat.category == .audio,
              FormatRegistry.shared.format(forID: job.preset.destinationFormat)?.category == .audio else {
            throw ConversionError.invalidPreset(reason: "Audio splitting requires audio input, audio output, and a valid split length.")
        }
        try requireFFprobe()
        guard let duration = try await probeMediaDuration(sourceURL: job.sourceURL, jobID: job.id), duration > 0 else {
            throw ConversionError.malformedSource(
                path: job.sourceURL.path,
                reason: "Could not determine the audio duration needed for splitting."
            )
        }

        let outputCount = max(1, Int(ceil(duration / Double(splitDuration))))
        return (0..<outputCount).map { index in
            ConversionOutputRequirement(
                extensionName: job.preset.destinationFormat,
                suffix: ConversionOutputSequence.suffix(
                    prefix: "part",
                    index: index + 1,
                    totalCount: outputCount
                )
            )
        }
    }

    public func convert(
        job: ConversionJob,
        outputs: [PlannedConversionOutput],
        progressHandler: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws -> BackendConversionResult {
        if job.preset.audioSplitDurationSeconds != nil,
           job.preset.audioTargetFileSizeBytes != nil {
            throw ConversionError.invalidPreset(reason: "Choose either split audio or a target file size, not both.")
        }
        if job.preset.audioSplitDurationSeconds != nil {
            return try await convertSplitAudio(job: job, outputs: outputs, progressHandler: progressHandler)
        }

        guard let first = outputs.first else {
            throw ConversionError.destinationUnavailable(path: "")
        }
        var singleOutputJob = job
        singleOutputJob.destinationURL = first.finalURL
        singleOutputJob.temporaryOutputURL = first.temporaryURL
        let warnings = try await convertSingle(job: singleOutputJob, progressHandler: progressHandler)
        return BackendConversionResult(warnings: warnings)
    }

    public func convert(job: ConversionJob, progressHandler: @escaping @Sendable (ConversionProgress) -> Void) async throws {
        _ = try await convertSingle(job: job, progressHandler: progressHandler)
    }

    /// Converts to one output and returns warnings for the queue row.
    private func convertSingle(job: ConversionJob, progressHandler: @escaping @Sendable (ConversionProgress) -> Void) async throws -> [String] {
        // Validate extra backend options at execution boundary.
        for (key, value) in job.preset.extraBackendOptions {
            guard PresetValidator.isAllowlistedFFmpegOption(key) else {
                throw ConversionError.invalidPreset(reason: "Unsupported backend option '\(key)'")
            }
            if PresetValidator.containsControlCharacters(key) || PresetValidator.containsControlCharacters(value) {
                throw ConversionError.invalidPreset(reason: "Backend option '\(key)' contains prohibited control characters.")
            }
            if value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-") {
                throw ConversionError.invalidPreset(reason: "Backend option '\(key)' value cannot start with a hyphen.")
            }
            if key.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("--") {
                throw ConversionError.invalidPreset(reason: "Backend option '\(key)' cannot start with '--'.")
            }
        }

        guard let ffmpegPath = executablePathProvider("ffmpeg") else {
            throw ConversionError.dependencyMissing(dependencyName: "FFmpeg", installCommand: "brew install ffmpeg")
        }

        let jobID = job.id
        let sourceURL = job.sourceURL
        defer {
            Task {
                await MediaProbeCache.shared.evict(for: sourceURL)
            }
        }
        guard let destURL = job.temporaryOutputURL ?? job.destinationURL else {
            throw ConversionError.destinationUnavailable(path: "")
        }

        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }

        // Probe total duration with ffprobe for accurate progress calculation
        if job.preset.audioTargetFileSizeBytes != nil || job.preset.videoTargetFileSizeBytes != nil {
            try requireFFprobe()
        }
        let totalDurationSeconds: Double
        do {
            totalDurationSeconds = MediaTrim.keptDuration(
                totalSeconds: try await probeMediaDuration(sourceURL: sourceURL, jobID: jobID) ?? 0.0,
                preset: job.preset
            )
        } catch is CancellationError {
            throw ConversionError.cancelled
        }
        try Task.checkCancellation()
        if job.preset.isTrimmed, totalDurationSeconds <= 0,
           let full = try? await probeMediaDuration(sourceURL: sourceURL, jobID: jobID), full > 0 {
            throw ConversionError.invalidPreset(
                reason: "The start time (\(MediaTrim.formatTime(job.preset.trimStartSeconds ?? 0))) is after the end of this file (\(MediaTrim.formatTime(full)))."
            )
        }

        let availableEncoders: Set<String>
        do {
            availableEncoders = try await ExternalToolDiscovery.shared.availableFFmpegEncoders(
                executableURL: URL(fileURLWithPath: ffmpegPath),
                processRegistry: processRegistry,
                jobID: jobID
            )
        } catch is CancellationError {
            throw ConversionError.cancelled
        }
        if let missingEncoder = missingRequiredEncoder(
            preset: job.preset,
            destinationFormatID: job.preset.destinationFormat,
            availableEncoders: availableEncoders
        ) {
            throw ConversionError.encoderUnavailable(
                codec: missingEncoder,
                reason: "The detected FFmpeg build does not include a compatible encoder."
            )
        }
        if job.preset.audioCodec == .copy {
            guard let sourceCodec = try await probeAudioCodec(sourceURL: sourceURL, jobID: jobID) else {
                throw ConversionError.malformedSource(
                    path: sourceURL.path,
                    reason: "Direct Stream Copy requires an identifiable audio stream in the source file."
                )
            }
            let destExt = destURL.pathExtension.lowercased()
            if !Self.isMuxerCompatible(sourceAudioCodec: sourceCodec, destinationFormat: destExt) {
                throw ConversionError.invalidPreset(
                    reason: "Direct Stream Copy cannot mux '\(sourceCodec)' audio into '.\(destExt)' container. Choose a compatible container (e.g. .m4a) or transcode the audio."
                )
            }
        }
        let isAudioOnly = job.preset.category == .audio || job.preset.videoCodec == .none
        let sourceInfo: SourceMediaInfo?
        do {
            sourceInfo = isAudioOnly && !job.preset.normalizeLoudness
                ? nil
                : try await probeSourceInfo(sourceURL: sourceURL, jobID: jobID)
        } catch is CancellationError {
            throw ConversionError.cancelled
        }

        if let targetBytes = job.preset.audioTargetFileSizeBytes {
            guard totalDurationSeconds > 0 else {
                throw ConversionError.malformedSource(
                    path: sourceURL.path,
                    reason: "Could not determine the audio duration needed to target a file size."
                )
            }
            try await convertToTargetAudioSize(
                sourceURL: sourceURL,
                destinationURL: destURL,
                preset: job.preset,
                targetBytes: targetBytes,
                totalDurationSeconds: totalDurationSeconds,
                sourceInfo: sourceInfo,
                availableEncoders: availableEncoders,
                ffmpegPath: ffmpegPath,
                jobID: jobID,
                progressHandler: progressHandler
            )
            return []
        }

        if let targetBytes = job.preset.videoTargetFileSizeBytes {
            guard totalDurationSeconds > 0 else {
                throw ConversionError.malformedSource(
                    path: sourceURL.path,
                    reason: "Could not determine the video length needed to fit a size limit."
                )
            }
            return try await convertToTargetVideoSize(
                sourceURL: sourceURL,
                destinationURL: destURL,
                preset: job.preset,
                targetBytes: targetBytes,
                totalDurationSeconds: totalDurationSeconds,
                sourceInfo: sourceInfo,
                availableEncoders: availableEncoders,
                ffmpegPath: ffmpegPath,
                jobID: jobID,
                progressHandler: progressHandler
            )
        }

        var warnings: [String] = []
        let arguments = buildFFmpegArguments(
            sourceURL: sourceURL,
            destURL: destURL,
            preset: job.preset,
            availableEncoders: availableEncoders,
            sourceInfo: sourceInfo,
            warn: { warnings.append($0) }
        )
        try await runFFmpeg(
            executablePath: ffmpegPath,
            arguments: arguments,
            jobID: jobID,
            totalDurationSeconds: totalDurationSeconds,
            progressHandler: progressHandler
        )
        return warnings
    }

    /// Everything the video arguments need, from one ffprobe call.
    func probeSourceInfo(sourceURL: URL, jobID: UUID) async throws -> SourceMediaInfo? {
        if let cached = await MediaProbeCache.shared.metadata(for: sourceURL)?.sourceInfo {
            return cached
        }
        guard let ffprobePath = executablePathProvider("ffprobe") else { return nil }
        let process = ExternalProcessAttempt(
            executableURL: URL(fileURLWithPath: ffprobePath),
            arguments: ["-v", "error", "-show_streams", "-show_format", "-show_chapters", "-of", "json", sourceURL.path],
            stdoutCaptureLimit: 4 * 1024 * 1024,
            timeout: 30
        )
        let result: ExternalProcessResult
        do {
            result = try await processRegistry.run(process, for: jobID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        guard result.terminationStatus == 0, let info = Self.parseSourceInfo(result.stdout) else { return nil }
        await MediaProbeCache.shared.update(for: sourceURL) { $0.sourceInfo = info }
        return info
    }

    static func parseSourceInfo(_ data: Data) -> SourceMediaInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let streams = json["streams"] as? [[String: Any]] ?? []
        var info = SourceMediaInfo()
        if let video = streams.first(where: { ($0["codec_type"] as? String) == "video"
            && (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 0 }) {
            info.width = video["width"] as? Int
            info.height = video["height"] as? Int
            info.videoCodec = video["codec_name"] as? String
            info.pixelFormat = video["pix_fmt"] as? String
            info.colorTransfer = video["color_transfer"] as? String
            info.colorPrimaries = video["color_primaries"] as? String
            info.colorSpace = video["color_space"] as? String
            if let rate = video["avg_frame_rate"] as? String ?? video["r_frame_rate"] as? String {
                let parts = rate.split(separator: "/").compactMap { Double($0) }
                if parts.count == 2, parts[1] > 0, parts[0] > 0 { info.frameRate = parts[0] / parts[1] }
            }
            if let bitRate = (video["bit_rate"] as? String).flatMap(Double.init) {
                info.bitRateKbps = bitRate / 1_000
            }
            var rotation = 0
            for side in video["side_data_list"] as? [[String: Any]] ?? [] {
                if let value = side["rotation"] as? Int { rotation = value }
                if let value = side["rotation"] as? Double { rotation = Int(value) }
            }
            if rotation == 0, let tag = (video["tags"] as? [String: Any])?["rotate"] as? String, let value = Int(tag) {
                rotation = value
            }
            info.rotation = ((rotation % 360) + 360) % 360
        }
        let audioStreams = streams.filter { ($0["codec_type"] as? String) == "audio" }
        info.audioCodecs = audioStreams.compactMap { $0["codec_name"] as? String }
        info.audioSampleRate = audioStreams.first.flatMap { ($0["sample_rate"] as? String).flatMap(Int.init) }
        info.subtitleStreams = streams.compactMap { stream in
            guard (stream["codec_type"] as? String) == "subtitle",
                  let index = stream["index"] as? Int else { return nil }
            return (index, stream["codec_name"] as? String ?? "")
        }
        info.chapterCount = (json["chapters"] as? [Any])?.count ?? 0
        let format = json["format"] as? [String: Any] ?? [:]
        info.duration = (format["duration"] as? String).flatMap(Double.init)
        if info.bitRateKbps == nil, let total = (format["bit_rate"] as? String).flatMap(Double.init) {
            info.bitRateKbps = total / 1_000
        }
        return info
    }

    private func runFFmpeg(
        executablePath: String,
        arguments: [String],
        jobID: UUID,
        totalDurationSeconds: Double,
        emitCompletion: Bool = true,
        progressHandler: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws {
        let startTime = Date()
        let process = ExternalProcessAttempt(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            timeout: 120 * 60,
            stdoutLineHandler: { [weak self] line in
                guard let self,
                      let progress = self.parseProgressLine(
                          line,
                          totalDuration: totalDurationSeconds,
                          startTime: startTime
                      ) else {
                    return
                }
                progressHandler(progress)
            }
        )

        let result: ExternalProcessResult
        do {
            result = try await processRegistry.run(process, for: jobID)
        } catch is CancellationError {
            throw ConversionError.cancelled
        } catch ExternalProcessRunnerError.timedOut {
            throw ConversionError.externalToolFailed(tool: "FFmpeg", exitCode: -1, stderr: "The conversion exceeded the two-hour safety limit.")
        }

        let exitCode = result.terminationStatus
        if exitCode == 0 {
            guard emitCompletion else { return }
            progressHandler(ConversionProgress(fractionCompleted: 1.0, elapsedTime: Date().timeIntervalSince(startTime)))
        } else if exitCode == 15 || exitCode == 9 {
            throw ConversionError.cancelled
        } else {
            throw ConversionError.externalToolFailed(tool: "FFmpeg", exitCode: exitCode, stderr: result.stderr)
        }
    }

    private func convertToTargetAudioSize(
        sourceURL: URL,
        destinationURL: URL,
        preset: ConversionPreset,
        targetBytes: Int,
        totalDurationSeconds: Double,
        sourceInfo: SourceMediaInfo?,
        availableEncoders: Set<String>,
        ffmpegPath: String,
        jobID: UUID,
        progressHandler: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws {
        guard targetBytes > 0 else {
            throw ConversionError.invalidPreset(reason: "Choose a positive audio target size.")
        }

        // Reserve room for container and metadata overhead. The verification
        // pass below retries at a lower bitrate if a file still exceeds target.
        let overheadBytes = min(max(targetBytes / 20, 32 * 1_024), 128 * 1_024)
        let usableBytes = max(0, targetBytes - overheadBytes)
        var bitrate = Int((Double(usableBytes) * 8 / totalDurationSeconds / 1_000).rounded(.down))
        guard bitrate >= 16 else {
            throw ConversionError.invalidPreset(
                reason: "The selected file size is too small for this audio duration. Choose a larger target."
            )
        }
        bitrate = min(bitrate, 512)

        let fileManager = FileManager.default
        let overallStart = Date()
        for attempt in 0..<3 {
            try Task.checkCancellation()
            if fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: destinationURL)
            }
            let arguments = buildFFmpegArguments(
                sourceURL: sourceURL,
                destURL: destinationURL,
                preset: preset,
                availableEncoders: availableEncoders,
                audioBitrateOverride: bitrate,
                sourceInfo: sourceInfo
            )
            try await runFFmpeg(
                executablePath: ffmpegPath,
                arguments: arguments,
                jobID: jobID,
                totalDurationSeconds: totalDurationSeconds,
                emitCompletion: false,
                progressHandler: { progress in
                    // A target-size conversion may require several encoding
                    // passes. Keep the progress bar monotonic and reserve
                    // 100% for the pass that actually meets the size limit.
                    var adjusted = progress
                    adjusted.fractionCompleted =
                        (Double(attempt) + progress.fractionCompleted) / 3.0
                    progressHandler(adjusted)
                }
            )

            let producedBytes = Int(FileAccessManager.shared.fileSize(at: destinationURL))
            guard producedBytes > 0 else {
                throw ConversionError.externalToolFailed(
                    tool: "FFmpeg",
                    exitCode: -1,
                    stderr: "FFmpeg completed without producing a readable audio file."
                )
            }
            if producedBytes <= targetBytes {
                progressHandler(
                    ConversionProgress(
                        fractionCompleted: 1.0,
                        elapsedTime: Date().timeIntervalSince(overallStart)
                    )
                )
                return
            }
            guard attempt < 2 else { break }

            let scaled = Double(bitrate) * Double(targetBytes) / Double(producedBytes) * 0.92
            let nextBitrate = Int(scaled.rounded(.down))
            guard nextBitrate >= 16, nextBitrate < bitrate else { break }
            bitrate = nextBitrate
        }

        throw ConversionError.invalidPreset(
            reason: "The selected audio size could not be reached without dropping below the minimum supported bitrate."
        )
    }

    /// Bitrates and picture size for a video that must fit in `targetBytes`:
    /// a little room for the container, a modest audio track, the rest for
    /// video, and a smaller picture when the bitrate can't carry more.
    /// Nil when the video is too long for the size at any watchable quality.
    static func videoSizePlan(
        targetBytes: Int,
        durationSeconds: Double
    ) -> (videoKbps: Int, audioKbps: Int, resolution: ResolutionSetting)? {
        guard targetBytes > 0, durationSeconds > 0 else { return nil }
        let overheadBytes = min(max(targetBytes / 50, 64 * 1_024), 512 * 1_024)
        let totalKbps = Int((Double(targetBytes - overheadBytes) * 8 / durationSeconds / 1_000).rounded(.down))
        let audioKbps = totalKbps >= 1_000 ? 128 : (totalKbps >= 400 ? 96 : 64)
        let videoKbps = totalKbps - audioKbps
        guard videoKbps >= 150 else { return nil }
        let resolution: ResolutionSetting = videoKbps < 900 ? .sd480p : (videoKbps < 2_500 ? .hd720p : .hd1080p)
        return (min(videoKbps, 20_000), audioKbps, resolution)
    }

    private func convertToTargetVideoSize(
        sourceURL: URL,
        destinationURL: URL,
        preset: ConversionPreset,
        targetBytes: Int,
        totalDurationSeconds: Double,
        sourceInfo: SourceMediaInfo?,
        availableEncoders: Set<String>,
        ffmpegPath: String,
        jobID: UUID,
        progressHandler: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws -> [String] {
        let megabytes = ByteCountFormatter.string(fromByteCount: Int64(targetBytes), countStyle: .file)
        guard let plan = Self.videoSizePlan(targetBytes: targetBytes, durationSeconds: totalDurationSeconds) else {
            throw ConversionError.invalidPreset(
                reason: "This video is too long to fit in \(megabytes) at a watchable quality. Choose a larger size limit."
            )
        }

        var attemptPreset = preset
        attemptPreset.crf = nil
        attemptPreset.audioBitrateKbps = plan.audioKbps
        // The software encoder follows a bitrate closely; hardware does not.
        attemptPreset.hardwareAcceleration = .softwareOnly
        if preset.resolution == .original {
            attemptPreset.resolution = plan.resolution
        }
        var videoKbps = plan.videoKbps

        let fileManager = FileManager.default
        let overallStart = Date()
        var warnings: [String] = []
        for attempt in 0..<3 {
            try Task.checkCancellation()
            if fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: destinationURL)
            }
            attemptPreset.videoBitrateKbps = videoKbps
            warnings.removeAll()
            let arguments = buildFFmpegArguments(
                sourceURL: sourceURL,
                destURL: destinationURL,
                preset: attemptPreset,
                availableEncoders: availableEncoders,
                sourceInfo: sourceInfo,
                warn: { warnings.append($0) }
            )
            try await runFFmpeg(
                executablePath: ffmpegPath,
                arguments: arguments,
                jobID: jobID,
                totalDurationSeconds: totalDurationSeconds,
                emitCompletion: false,
                progressHandler: { progress in
                    // Up to three passes; keep the bar moving forward.
                    var adjusted = progress
                    adjusted.fractionCompleted = (Double(attempt) + progress.fractionCompleted) / 3.0
                    progressHandler(adjusted)
                }
            )

            let producedBytes = Int(FileAccessManager.shared.fileSize(at: destinationURL))
            guard producedBytes > 0 else {
                throw ConversionError.externalToolFailed(
                    tool: "FFmpeg",
                    exitCode: -1,
                    stderr: "FFmpeg completed without producing a readable video file."
                )
            }
            if producedBytes <= targetBytes {
                progressHandler(ConversionProgress(fractionCompleted: 1.0, elapsedTime: Date().timeIntervalSince(overallStart)))
                return warnings
            }
            guard attempt < 2 else { break }
            let scaled = Double(videoKbps) * Double(targetBytes) / Double(producedBytes) * 0.92
            let next = Int(scaled.rounded(.down))
            guard next >= 150, next < videoKbps else { break }
            videoKbps = next
        }

        throw ConversionError.invalidPreset(
            reason: "The video could not be made to fit in \(megabytes). Choose a larger size limit."
        )
    }

    private func convertSplitAudio(
        job: ConversionJob,
        outputs: [PlannedConversionOutput],
        progressHandler: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws -> BackendConversionResult {
        guard let splitDuration = job.preset.audioSplitDurationSeconds,
              !outputs.isEmpty,
              let ffmpegPath = executablePathProvider("ffmpeg") else {
            throw ConversionError.dependencyMissing(dependencyName: "FFmpeg", installCommand: "brew install ffmpeg")
        }
        try requireFFprobe()
        guard let totalDurationSeconds = try await probeMediaDuration(sourceURL: job.sourceURL, jobID: job.id), totalDurationSeconds > 0 else {
            throw ConversionError.malformedSource(
                path: job.sourceURL.path,
                reason: "Could not determine the audio duration needed for splitting."
            )
        }
        let availableEncoders = try await ExternalToolDiscovery.shared.availableFFmpegEncoders(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            processRegistry: processRegistry,
            jobID: job.id
        )
        if let missingEncoder = missingRequiredEncoder(
            preset: job.preset,
            destinationFormatID: job.preset.destinationFormat,
            availableEncoders: availableEncoders
        ) {
            throw ConversionError.encoderUnavailable(
                codec: missingEncoder,
                reason: "The detected FFmpeg build does not include a compatible encoder."
            )
        }

        if job.preset.audioCodec == .copy {
            guard let sourceCodec = try await probeAudioCodec(sourceURL: job.sourceURL, jobID: job.id) else {
                throw ConversionError.malformedSource(
                    path: job.sourceURL.path,
                    reason: "Direct Stream Copy requires an identifiable audio stream in the source file."
                )
            }
            let destExt = outputs[0].temporaryURL.pathExtension.lowercased()
            if !Self.isMuxerCompatible(sourceAudioCodec: sourceCodec, destinationFormat: destExt) {
                throw ConversionError.invalidPreset(
                    reason: "Direct Stream Copy cannot mux '\(sourceCodec)' audio into '.\(destExt)' container. Choose a compatible container (e.g. .m4a) or transcode the audio."
                )
            }
        }

        let fileManager = FileManager.default
        // Stage beside the planned temporary outputs rather than in the
        // system temp directory. The final destination may be an external
        // volume, and same-volume moves avoid cross-volume failures.
        let stagingDirectory = Self.splitStagingDirectory(for: outputs[0], jobID: job.id)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let extensionName = outputs[0].temporaryURL.pathExtension
        let outputPattern = stagingDirectory.appendingPathComponent(
            Self.splitStagingFilenamePattern(
                totalOutputCount: outputs.count,
                extensionName: extensionName
            )
        )
        let arguments = buildFFmpegArguments(
            sourceURL: job.sourceURL,
            destURL: outputPattern,
            preset: job.preset,
            availableEncoders: availableEncoders,
            segmentDuration: splitDuration
        )
        try await runFFmpeg(
            executablePath: ffmpegPath,
            arguments: arguments,
            jobID: job.id,
            totalDurationSeconds: totalDurationSeconds,
            progressHandler: progressHandler
        )

        let produced = try fileManager.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == extensionName.lowercased() }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard produced.count == outputs.count else {
            throw ConversionError.externalToolFailed(
                tool: "FFmpeg",
                exitCode: -1,
                stderr: "Expected \(outputs.count) audio segments, but FFmpeg produced \(produced.count)."
            )
        }
        for (producedURL, output) in zip(produced, outputs) {
            try Task.checkCancellation()
            try fileManager.moveItem(at: producedURL, to: output.temporaryURL)
        }
        return BackendConversionResult()
    }

    static func splitStagingFilenamePattern(
        totalOutputCount: Int,
        extensionName: String
    ) -> String {
        let width = max(6, String(max(1, totalOutputCount)).count)
        return "segment-%0\(width)d.\(extensionName)"
    }

    static func splitStagingDirectory(
        for firstOutput: PlannedConversionOutput,
        jobID: UUID
    ) -> URL {
        firstOutput.temporaryURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".FileConverter-AudioSplit-\(jobID.uuidString)-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private func probeMediaDuration(sourceURL: URL, jobID: UUID) async throws -> Double? {
        if let cached = await MediaProbeCache.shared.metadata(for: sourceURL)?.duration {
            return cached
        }

        guard let ffprobePath = executablePathProvider("ffprobe") else {
            return nil
        }

        let process = ExternalProcessAttempt(
            executableURL: URL(fileURLWithPath: ffprobePath),
            arguments: [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                sourceURL.path
            ],
            stdoutCaptureLimit: 64 * 1024,
            timeout: 30
        )

        do {
            let result = try await processRegistry.run(process, for: jobID)
            guard result.terminationStatus == 0 else { return nil }
            if let str = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let dur = Double(str), dur > 0 {
                await MediaProbeCache.shared.update(for: sourceURL) { $0.duration = dur }
                return dur
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        return nil
    }

    public static func isMuxerCompatible(sourceAudioCodec: String, destinationFormat: String) -> Bool {
        let dest = destinationFormat.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let codec = sourceAudioCodec.lowercased()
        switch dest {
        case "mp3":
            return codec == "mp3"
        case "wav":
            return codec.hasPrefix("pcm_") || codec == "pcm"
        case "aiff", "aif":
            return codec.hasPrefix("pcm_") || codec == "pcm"
        case "flac":
            return codec == "flac"
        case "aac":
            return codec == "aac"
        case "m4a":
            return codec == "aac" || codec == "alac"
        case "opus":
            return codec == "opus"
        case "ogg":
            return codec == "opus" || codec == "vorbis" || codec == "flac"
        case "mp4":
            return codec == "aac" || codec == "mp3" || codec == "ac3" || codec == "eac3" || codec == "alac"
        case "mov", "mkv":
            return true
        case "webm":
            return codec == "opus" || codec == "vorbis"
        default:
            return true
        }
    }

    private func probeAudioCodec(sourceURL: URL, jobID: UUID) async throws -> String? {
        if let cached = await MediaProbeCache.shared.metadata(for: sourceURL)?.audioCodec {
            return cached
        }

        guard let ffprobePath = executablePathProvider("ffprobe") else {
            return nil
        }

        let process = ExternalProcessAttempt(
            executableURL: URL(fileURLWithPath: ffprobePath),
            arguments: [
                "-v", "error",
                "-select_streams", "a:0",
                "-show_entries", "stream=codec_name",
                "-of", "default=noprint_wrappers=1:nokey=1",
                sourceURL.path
            ],
            stdoutCaptureLimit: 64 * 1024,
            timeout: 30
        )

        do {
            let result = try await processRegistry.run(process, for: jobID)
            guard result.terminationStatus == 0 else { return nil }
            if let str = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !str.isEmpty {
                let codec = str.lowercased()
                await MediaProbeCache.shared.update(for: sourceURL) { $0.audioCodec = codec }
                return codec
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        return nil
    }

    private func requireFFprobe() throws {
        guard executablePathProvider("ffprobe") != nil else {
            throw ConversionError.dependencyMissing(
                dependencyName: "FFprobe (included with FFmpeg)",
                installCommand: "brew install ffmpeg"
            )
        }
    }

    private func parseProgressLine(_ line: String, totalDuration: Double, startTime: Date) -> ConversionProgress? {
        // Line format: key=value
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }

        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let value = parts[1].trimmingCharacters(in: .whitespaces)

        if key == "out_time_us", let micros = Double(value) {
            let seconds = micros / 1_000_000.0
            let elapsed = Date().timeIntervalSince(startTime)
            var fraction = 0.0
            var eta: TimeInterval? = nil

            if totalDuration > 0 {
                fraction = min(max(seconds / totalDuration, 0.0), 0.99)
                if fraction > 0.02 {
                    eta = (elapsed / fraction) - elapsed
                }
            } else {
                // If duration unknown, simulate monotonic progress
                fraction = min(1.0 - exp(-elapsed / 30.0), 0.95)
            }

            return ConversionProgress(
                fractionCompleted: fraction,
                elapsedTime: elapsed,
                estimatedTimeRemaining: eta
            )
        }

        return nil
    }

    public func buildFFmpegArguments(sourceURL: URL, destURL: URL, preset: ConversionPreset) -> [String] {
        buildFFmpegArguments(
            sourceURL: sourceURL,
            destURL: destURL,
            preset: preset,
            availableEncoders: ExternalToolDiscovery.shared.availableFFmpegEncoders(),
            segmentDuration: preset.audioSplitDurationSeconds
        )
    }

    func buildFFmpegArguments(
        sourceURL: URL,
        destURL: URL,
        preset: ConversionPreset,
        availableEncoders: Set<String>,
        audioBitrateOverride: Int? = nil,
        segmentDuration: Int? = nil,
        sourceInfo: SourceMediaInfo? = nil,
        warn: (String) -> Void = { _ in }
    ) -> [String] {
        var args: [String] = [
            "-y",
            "-nostdin",
            "-hide_banner"
        ]

        if sourceURL.pathExtension.lowercased() == "qta" {
            args.append(contentsOf: ["-f", "mov"])
        }

        args.append(contentsOf: Self.trimArguments(for: preset))
        args.append(contentsOf: ["-i", sourceURL.path])


        let isAudioOnly = preset.category == .audio || preset.videoCodec == .none
        let targetExt = destURL.pathExtension.lowercased()
        let effectiveAudioBitrate = audioBitrateOverride ?? preset.audioBitrateKbps

        if isAudioOnly {
            args.append(contentsOf: [
                "-vn",
                "-sn",
                "-dn",
                "-map", "0:a:0"
            ])
            switch preset.audioCodec {
            case .copy:
                args.append(contentsOf: ["-c:a", "copy"])
            case .none:
                args.append(contentsOf: ["-an"])
            case .mp3:
                args.append(contentsOf: ["-c:a", "libmp3lame"])
                if let bitrate = effectiveAudioBitrate {
                    args.append(contentsOf: ["-b:a", "\(bitrate)k"])
                }
            case .aac:
                args.append(contentsOf: ["-c:a", "aac"])
                if let bitrate = effectiveAudioBitrate {
                    args.append(contentsOf: ["-b:a", "\(bitrate)k"])
                }
            case .opus:
                args.append(contentsOf: ["-c:a", "libopus"])
                if let bitrate = effectiveAudioBitrate {
                    args.append(contentsOf: ["-b:a", "\(bitrate)k"])
                }
            case .flac:
                args.append(contentsOf: ["-c:a", "flac"])
                let compressionLevel: Int = {
                    switch preset.quality {
                    case .low: return 2
                    case .medium: return 5
                    case .high, .lossless: return 8
                    case .veryHigh: return 12
                    default: return 8
                    }
                }()
                args.append(contentsOf: ["-compression_level", "\(compressionLevel)"])
            case .alac:
                args.append(contentsOf: ["-c:a", "alac"])
            case .wav:
                let pcmCodec = preset.audioBitDepth?.ffmpegWavCodec ?? "pcm_s16le"
                args.append(contentsOf: ["-c:a", pcmCodec])
            case .aiff:
                let pcmCodec = preset.audioBitDepth?.ffmpegAiffCodec ?? "pcm_s16be"
                args.append(contentsOf: ["-c:a", pcmCodec])
            default:
                if targetExt == "mp3" {
                    args.append(contentsOf: ["-c:a", "libmp3lame"])
                    if let bitrate = effectiveAudioBitrate {
                        args.append(contentsOf: ["-b:a", "\(bitrate)k"])
                    }
                } else if targetExt == "ogg" {
                    args.append(contentsOf: ["-c:a", "libvorbis"])
                    if let bitrate = effectiveAudioBitrate {
                        args.append(contentsOf: ["-b:a", "\(bitrate)k"])
                    }
                } else if targetExt == "opus" {
                    args.append(contentsOf: ["-c:a", "libopus"])
                    if let bitrate = effectiveAudioBitrate {
                        args.append(contentsOf: ["-b:a", "\(bitrate)k"])
                    }
                } else if targetExt == "flac" {
                    args.append(contentsOf: ["-c:a", "flac"])
                    let compressionLevel: Int = {
                        switch preset.quality {
                        case .low: return 2
                        case .medium: return 5
                        case .high, .lossless: return 8
                        case .veryHigh: return 12
                        default: return 8
                        }
                    }()
                    args.append(contentsOf: ["-compression_level", "\(compressionLevel)"])
                } else if targetExt == "wav" {
                    let pcmCodec = preset.audioBitDepth?.ffmpegWavCodec ?? "pcm_s16le"
                    args.append(contentsOf: ["-c:a", pcmCodec])
                } else if targetExt == "aiff" || targetExt == "aif" {
                    let pcmCodec = preset.audioBitDepth?.ffmpegAiffCodec ?? "pcm_s16be"
                    args.append(contentsOf: ["-c:a", pcmCodec])
                } else {
                    args.append(contentsOf: ["-c:a", "aac"])
                    if let bitrate = effectiveAudioBitrate {
                        args.append(contentsOf: ["-b:a", "\(bitrate)k"])
                    }
                }
            }

            if preset.audioCodec != .copy && preset.audioCodec != .none {
                if preset.normalizeLoudness {
                    args.append(contentsOf: ["-af", MediaTrim.loudnormFilter])
                }
                if let sampleRate = preset.audioSampleRate {
                    args.append(contentsOf: ["-ar", "\(sampleRate)"])
                } else if preset.normalizeLoudness {
                    // loudnorm works at 192 kHz; go back to the original rate.
                    let rate = Self.loudnormOutputSampleRate(
                        sourceRate: sourceInfo?.audioSampleRate,
                        targetExt: targetExt,
                        audioCodec: preset.audioCodec
                    )
                    args.append(contentsOf: ["-ar", "\(rate)"])
                }
                if let channels = preset.audioChannels {
                    args.append(contentsOf: ["-ac", "\(channels)"])
                }
            }
        } else {
            args.append(contentsOf: videoArguments(
                preset: preset,
                targetExt: targetExt,
                sourceInfo: sourceInfo,
                availableEncoders: availableEncoders,
                warn: warn
            ))
            if targetExt != "gif" {
                args.append(contentsOf: audioArgumentsForVideo(
                    preset: preset,
                    targetExt: targetExt,
                    effectiveAudioBitrate: effectiveAudioBitrate,
                    copyStreams: canStreamCopy(preset: preset, targetExt: targetExt, sourceInfo: sourceInfo)
                ))
            }
        }

        if preset.preserveMetadata {
            args.append(contentsOf: ["-map_metadata", "0"])
            if preset.removeLocationData ?? true {
                // Clear the tags FFmpeg copies GPS coordinates into.
                args.append(contentsOf: [
                    "-metadata", "location=",
                    "-metadata", "location-eng=",
                    "-metadata", "com.apple.quicktime.location.ISO6709="
                ])
            }
        } else {
            args.append(contentsOf: ["-map_metadata", "-1"])
        }
        if ["mp4", "m4v", "mov"].contains(targetExt) && segmentDuration == nil {
            // Index first, so players and browsers can start before the end
            // of the download.
            args.append(contentsOf: ["-movflags", "+faststart"])
        }

        if let segmentDuration {
            args.append(contentsOf: [
                "-f", "segment",
                "-segment_time", "\(segmentDuration)",
                "-segment_start_number", "1",
                "-reset_timestamps", "1"
            ])
            if let segmentFormat = determineFFmpegMuxerFormat(for: targetExt) {
                args.append(contentsOf: ["-segment_format", segmentFormat])
            }
        } else if let muxer = preset.container?.trimmingCharacters(in: .whitespacesAndNewlines), !muxer.isEmpty {
            args.append(contentsOf: ["-f", muxer])
        } else if let muxer = determineFFmpegMuxerFormat(for: targetExt) {
            args.append(contentsOf: ["-f", muxer])
        }

        // Preserve explicitly supplied backend options. Keys are emitted in
        // deterministic order so exported presets remain reproducible.
        // Guard against argument injection: only allowlisted options are forwarded.
        for (key, value) in preset.extraBackendOptions.sorted(by: { $0.key < $1.key }) {
            guard PresetValidator.isAllowlistedFFmpegOption(key) else { continue }
            guard !PresetValidator.containsControlCharacters(key) && !PresetValidator.containsControlCharacters(value) &&
                  !key.contains("\n") && !key.contains("\r") && !key.contains("\0") &&
                  !value.contains("\n") && !value.contains("\r") && !value.contains("\0") else { continue }
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.hasPrefix("-") else { continue }
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.hasPrefix("--") else { continue }

            let optionName = trimmedKey.hasPrefix("-") ? String(trimmedKey.dropFirst()) : trimmedKey
            let normalizedKey = "-\(optionName)"

            // Handle boolean flags: vn, an, sn
            if ["vn", "an", "sn"].contains(optionName) {
                let lowerVal = trimmedValue.lowercased()
                if lowerVal == "false" || lowerVal == "0" {
                    continue
                } else if lowerVal.isEmpty || lowerVal == "true" || lowerVal == "1" {
                    args.append(normalizedKey)
                }
            } else {
                args.append(normalizedKey)
                if !trimmedValue.isEmpty { args.append(trimmedValue) }
            }
        }

        // Output progress flags and destination
        args.append(contentsOf: [
            "-progress", "pipe:1",
            destURL.path
        ])

        return args
    }


    /// Input seeking keeps trimmed conversions fast: FFmpeg starts reading
    /// at the start time and stops at the end time.
    static func trimArguments(for preset: ConversionPreset) -> [String] {
        var args: [String] = []
        if let start = preset.trimStartSeconds, start > 0 {
            args += ["-ss", MediaTrim.argument(start)]
        }
        if let end = preset.trimEndSeconds {
            args += ["-to", MediaTrim.argument(end)]
        }
        return args
    }

    /// Sample rate after loudnorm: the original rate when the encoder can
    /// take it, otherwise 48 kHz.
    static func loudnormOutputSampleRate(sourceRate: Int?, targetExt: String, audioCodec: AudioCodecType) -> Int {
        // Opus encodes at 48 kHz only.
        if targetExt == "opus" || audioCodec == .opus { return 48_000 }
        guard let sourceRate, sourceRate >= 8_000 else { return 48_000 }
        if targetExt == "mp3" {
            let mp3Rates = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]
            return mp3Rates.last { $0 <= sourceRate } ?? 48_000
        }
        return sourceRate
    }

    // MARK: - Video

    static let textSubtitleCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text"]

    /// MKV → MP4 style presets copy the streams when the target container can
    /// hold them unchanged (no quality loss, seconds instead of minutes).
    func canStreamCopy(preset: ConversionPreset, targetExt: String, sourceInfo: SourceMediaInfo?) -> Bool {
        guard preset.allowsStreamCopy == true,
              preset.resolution == .original,
              preset.framerate == nil,
              let info = sourceInfo,
              let videoCodec = info.videoCodec?.lowercased(),
              ["mp4", "m4v", "mov"].contains(targetExt) else { return false }
        let copyableVideo: Set<String> = ["h264", "hevc"]
        let copyableAudio: Set<String> = ["aac", "alac", "mp3", "ac3", "eac3"]
        return copyableVideo.contains(videoCodec)
            && info.audioCodecs.allSatisfy { copyableAudio.contains($0.lowercased()) }
    }

    static func defaultCRF(for codec: VideoCodecType, quality: QualitySetting) -> Int {
        let table: (low: Int, medium: Int, high: Int, veryHigh: Int)
        switch codec {
        case .hevc: table = (32, 28, 25, 22)
        case .vp9: table = (38, 34, 31, 28)
        case .av1: table = (40, 35, 30, 26)
        default: table = (28, 24, 21, 18)
        }
        switch quality {
        case .low: return table.low
        case .medium, .custom: return table.medium
        case .high: return table.high
        case .veryHigh, .lossless: return table.veryHigh
        }
    }

    /// VideoToolbox constant-quality scale used when the source size is unknown.
    static func hardwareQuality(for quality: QualitySetting) -> Int {
        switch quality {
        case .low: return 45
        case .medium, .custom: return 55
        case .high: return 65
        case .veryHigh, .lossless: return 75
        }
    }

    /// Filters that convert HDR (PQ/HLG) to SDR BT.709, when this FFmpeg has them.
    static let toneMapFilters = [
        "zscale=t=linear:npl=100",
        "format=gbrpf32le",
        "zscale=p=bt709",
        "tonemap=tonemap=hable:desat=0",
        "zscale=t=bt709:m=bt709:r=tv",
        "format=yuv420p"
    ]

    func videoArguments(
        preset: ConversionPreset,
        targetExt: String,
        sourceInfo: SourceMediaInfo?,
        availableEncoders: Set<String>,
        warn: (String) -> Void
    ) -> [String] {
        var args: [String] = []
        let isHDR = sourceInfo?.isHDR ?? false
        let canToneMap = ExternalToolDiscovery.shared.hasFFmpegFilter("zscale")

        if targetExt == "gif" {
            var filters = ["fps=\(preset.framerate.map { String(format: "%.3g", $0) } ?? "15")"]
            if isHDR {
                if canToneMap {
                    filters += Self.toneMapFilters
                } else {
                    warn("This HDR video was turned into a GIF without converting it to standard range; colors may look washed out.")
                }
            }
            if let scale = VideoGeometry.ffmpegScaleFilter(for: preset.resolution) {
                filters.append(scale + ":flags=lanczos")
            }
            filters.append("split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse")
            args += ["-map", "0:v:0", "-an", "-sn", "-dn", "-vf", filters.joined(separator: ","), "-loop", "0"]
            return args
        }

        // Streams: first video, every audio track, chapters; subtitles the
        // target container can hold.
        args += ["-map", "0:v:0", "-map", "0:a?", "-map_chapters", "0", "-dn"]
        let isMP4Family = ["mp4", "m4v", "mov"].contains(targetExt)
        if targetExt == "mkv" {
            args += ["-map", "0:s?", "-c:s", "copy"]
        } else if let info = sourceInfo, isMP4Family || targetExt == "webm" {
            let text = info.subtitleStreams.filter { Self.textSubtitleCodecs.contains($0.codec.lowercased()) }
            let pictures = info.subtitleStreams.count - text.count
            for stream in text {
                args += ["-map", "0:\(stream.index)"]
            }
            if !text.isEmpty {
                args += ["-c:s", targetExt == "webm" ? "webvtt" : "mov_text"]
            }
            if pictures > 0 {
                let container = targetExt.uppercased()
                warn(pictures == 1
                    ? "1 picture-based subtitle track was not kept (\(container) cannot store it)."
                    : "\(pictures) picture-based subtitle tracks were not kept (\(container) cannot store them).")
            }
        }

        if canStreamCopy(preset: preset, targetExt: targetExt, sourceInfo: sourceInfo) {
            args += ["-c:v", "copy"]
            if sourceInfo?.videoCodec?.lowercased() == "hevc" {
                args += ["-tag:v", "hvc1"]
            }
            return args
        }

        var codec = preset.videoCodec
        if codec == .auto || codec == .copy || codec == .none {
            codec = targetExt == "webm" ? .vp9 : .h264
        }
        let wantsHardware = preset.hardwareAcceleration != .softwareOnly
        var filters: [String] = []
        var encoder: String

        let outputSize: (width: Int, height: Int)? = sourceInfo?.displaySize.map {
            VideoGeometry.targetSize(displayWidth: $0.width, displayHeight: $0.height, resolution: preset.resolution)
        }
        let outputFPS = preset.framerate ?? sourceInfo?.frameRate
        func modelKbps() -> Int? {
            if let explicit = preset.videoBitrateKbps { return explicit }
            guard let outputSize else { return nil }
            return VideoBitrateModel.targetKbps(
                width: outputSize.width,
                height: outputSize.height,
                fps: outputFPS,
                codec: codec,
                quality: preset.quality,
                sourceKbps: sourceInfo?.bitRateKbps
            )
        }
        func hardwareRateControl() -> [String] {
            if let kbps = modelKbps() {
                return ["-b:v", "\(kbps)k", "-maxrate", "\(kbps * 3 / 2)k", "-bufsize", "\(kbps * 2)k"]
            }
            return ["-q:v", "\(Self.hardwareQuality(for: preset.quality))"]
        }
        let crf = preset.crf ?? Self.defaultCRF(for: codec, quality: preset.quality)

        switch codec {
        case .hevc:
            if wantsHardware && availableEncoders.contains("hevc_videotoolbox") {
                encoder = "hevc_videotoolbox"
                args += ["-c:v", encoder] + hardwareRateControl()
            } else {
                encoder = "libx265"
                args += ["-c:v", encoder, "-preset", "medium", "-crf", "\(crf)", "-x265-params", "log-level=error"]
            }
            if isMP4Family { args += ["-tag:v", "hvc1"] }
        case .vp9:
            encoder = "libvpx-vp9"
            args += ["-c:v", encoder, "-crf", "\(crf)", "-b:v", "0", "-row-mt", "1"]
        case .av1:
            if availableEncoders.contains("libsvtav1") {
                encoder = "libsvtav1"
                args += ["-c:v", encoder, "-crf", "\(crf)", "-preset", "8"]
            } else {
                encoder = "libaom-av1"
                args += ["-c:v", encoder, "-crf", "\(crf)", "-b:v", "0", "-cpu-used", "6", "-row-mt", "1"]
            }
        case .proRes:
            if availableEncoders.contains("prores_videotoolbox") {
                encoder = "prores_videotoolbox"
                args += ["-c:v", encoder, "-profile:v", "2"]
            } else {
                encoder = "prores_ks"
                args += ["-c:v", encoder, "-profile:v", "2"]
            }
        default:
            if wantsHardware && availableEncoders.contains("h264_videotoolbox") {
                encoder = "h264_videotoolbox"
                args += ["-c:v", encoder] + hardwareRateControl()
            } else {
                encoder = "libx264"
                args += ["-c:v", encoder, "-preset", "medium"]
                if let explicit = preset.videoBitrateKbps, preset.crf == nil {
                    args += ["-b:v", "\(explicit)k"]
                } else {
                    args += ["-crf", "\(crf)"]
                }
            }
        }

        // Pixel format and HDR. 10-bit capable codecs keep HDR; 8-bit H.264
        // is tone-mapped to SDR when FFmpeg can, otherwise warned about.
        let keepsHDR = isHDR && [VideoCodecType.hevc, .av1, .vp9, .proRes].contains(codec)
        if keepsHDR, let info = sourceInfo {
            switch encoder {
            case "hevc_videotoolbox": args += ["-pix_fmt", "p010le", "-profile:v", "main10"]
            case "prores_videotoolbox", "prores_ks": args += ["-pix_fmt", "yuv422p10le"]
            case "libvpx-vp9": args += ["-pix_fmt", "yuv420p10le", "-profile:v", "2"]
            default: args += ["-pix_fmt", "yuv420p10le"]
            }
            if let primaries = info.colorPrimaries { args += ["-color_primaries", primaries] }
            if let transfer = info.colorTransfer { args += ["-color_trc", transfer] }
            if let space = info.colorSpace { args += ["-colorspace", space] }
        } else {
            if isHDR {
                if canToneMap {
                    filters += Self.toneMapFilters
                    args += ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
                } else if let info = sourceInfo {
                    // No tone mapper in this FFmpeg build: keep the true HDR
                    // labels (mislabelling as SDR would distort colors).
                    if let primaries = info.colorPrimaries { args += ["-color_primaries", primaries] }
                    if let transfer = info.colorTransfer { args += ["-color_trc", transfer] }
                    if let space = info.colorSpace { args += ["-colorspace", space] }
                    warn("This HDR video was saved as 8-bit \(codec == .h264 ? "H.264" : "video") without converting it to standard range. Choose an HEVC preset to keep full HDR quality.")
                }
            }
            switch encoder {
            case "prores_videotoolbox", "prores_ks": args += ["-pix_fmt", "yuv422p10le"]
            default: args += ["-pix_fmt", "yuv420p"]
            }
        }

        if let framerate = preset.framerate, framerate > 0 {
            args += ["-r", String(format: "%.3g", framerate)]
        }
        if let scale = VideoGeometry.ffmpegScaleFilter(for: preset.resolution) {
            filters.append(scale)
        }
        if !filters.isEmpty {
            args += ["-vf", filters.joined(separator: ",")]
        }
        return args
    }

    func audioArgumentsForVideo(
        preset: ConversionPreset,
        targetExt: String,
        effectiveAudioBitrate: Int?,
        copyStreams: Bool
    ) -> [String] {
        var args: [String] = []
        if copyStreams {
            return ["-c:a", "copy"]
        }
        // Audio tracks (every mapped track uses these settings)
        switch preset.audioCodec {
        case .opus:
            args.append(contentsOf: ["-c:a", "libopus"])
        case .mp3:
            args.append(contentsOf: ["-c:a", "libmp3lame"])
        case .flac:
            args.append(contentsOf: ["-c:a", "flac"])
        case .alac:
            args.append(contentsOf: ["-c:a", "alac"])
        case .wav:
            let pcmCodec = preset.audioBitDepth?.ffmpegWavCodec ?? "pcm_s16le"
            args.append(contentsOf: ["-c:a", pcmCodec])
        case .aiff:
            let pcmCodec = preset.audioBitDepth?.ffmpegAiffCodec ?? "pcm_s16be"
            args.append(contentsOf: ["-c:a", pcmCodec])
        case .copy:
            args.append(contentsOf: ["-c:a", "copy"])
        case .none:
            args.append(contentsOf: ["-an"])
        default:
            if targetExt == "webm" {
                args.append(contentsOf: ["-c:a", "libopus", "-b:a", "128k"])
            } else {
                args.append(contentsOf: ["-c:a", "aac", "-b:a", "192k"])
            }
        }
        if let bitrate = effectiveAudioBitrate,
           preset.audioCodec != .none,
           preset.audioCodec != .copy,
           preset.audioCodec != .wav,
           preset.audioCodec != .aiff,
           preset.audioCodec != .flac,
           preset.audioCodec != .alac {
            args.append(contentsOf: ["-b:a", "\(bitrate)k"])
        }
        if preset.audioCodec != .copy && preset.audioCodec != .none {
            if let sampleRate = preset.audioSampleRate {
                args.append(contentsOf: ["-ar", "\(sampleRate)"])
            }
            if let channels = preset.audioChannels {
                args.append(contentsOf: ["-ac", "\(channels)"])
            }
        }

        return args
    }

    private func determineFFmpegMuxerFormat(for targetExt: String) -> String? {
        switch targetExt.lowercased() {
        case "mp3": return "mp3"
        case "mp4", "m4v": return "mp4"
        case "mov", "qt", "qta": return "mov"
        case "m4a": return "ipod"
        case "mkv": return "matroska"
        case "webm": return "webm"
        case "wav": return "wav"
        case "aiff", "aif": return "aiff"
        case "flac": return "flac"
        case "ogg", "oga": return "ogg"
        case "opus": return "opus"
        case "gif": return "gif"
        case "avi": return "avi"
        default: return nil
        }
    }

    private func missingRequiredEncoder(
        preset: ConversionPreset,
        destinationFormat: FormatDefinition,
        availableEncoders: Set<String>
    ) -> String? {
        missingRequiredEncoder(
            preset: preset,
            destinationFormatID: destinationFormat.id,
            availableEncoders: availableEncoders
        )
    }

    private func missingRequiredEncoder(
        preset: ConversionPreset,
        destinationFormatID: String,
        availableEncoders: Set<String>
    ) -> String? {
        let target = destinationFormatID.lowercased()
        if target == "gif" {
            return availableEncoders.contains("gif") ? nil : "GIF"
        }

        let isAudioOnly = preset.category == .audio || preset.videoCodec == .none
        var requirements: [(label: String, alternatives: Set<String>)] = []

        if !isAudioOnly {
            switch preset.videoCodec {
            case .h264:
                requirements.append(videoEncoderRequirement(
                    label: "H.264",
                    hardware: "h264_videotoolbox",
                    software: "libx264",
                    policy: preset.hardwareAcceleration
                ))
            case .hevc:
                requirements.append(videoEncoderRequirement(
                    label: "HEVC",
                    hardware: "hevc_videotoolbox",
                    software: "libx265",
                    policy: preset.hardwareAcceleration
                ))
            case .proRes:
                requirements.append(("ProRes", ["prores_videotoolbox", "prores_ks"]))
            case .vp9:
                requirements.append(("VP9", ["libvpx-vp9"]))
            case .av1:
                requirements.append(("AV1", ["libsvtav1", "libaom-av1"]))
            case .auto:
                if target == "webm" {
                    requirements.append(("VP9", ["libvpx-vp9"]))
                } else {
                    requirements.append(videoEncoderRequirement(
                        label: "H.264",
                        hardware: "h264_videotoolbox",
                        software: "libx264",
                        policy: preset.hardwareAcceleration
                    ))
                }
            case .copy, .none:
                break
            }
        }

        let audioRequirement: (label: String, alternatives: Set<String>)?
        switch preset.audioCodec {
        case .aac: audioRequirement = ("AAC", ["aac"])
        case .alac: audioRequirement = ("ALAC", ["alac"])
        case .mp3: audioRequirement = ("MP3", ["libmp3lame"])
        case .flac: audioRequirement = ("FLAC", ["flac"])
        case .opus: audioRequirement = ("Opus", ["libopus"])
        case .wav: audioRequirement = ("PCM WAV", ["pcm_s16le"])
        case .aiff: audioRequirement = ("PCM AIFF", ["pcm_s16be"])
        case .auto:
            switch target {
            case "mp3": audioRequirement = ("MP3", ["libmp3lame"])
            case "ogg", "oga": audioRequirement = ("Ogg Vorbis", ["libvorbis"])
            case "opus", "webm": audioRequirement = ("Opus", ["libopus"])
            case "flac": audioRequirement = ("FLAC", ["flac"])
            case "wav": audioRequirement = ("PCM WAV", ["pcm_s16le"])
            case "aiff", "aif": audioRequirement = ("PCM AIFF", ["pcm_s16be"])
            default: audioRequirement = ("AAC", ["aac"])
            }
        case .copy, .none:
            audioRequirement = nil
        }
        if let audioRequirement { requirements.append(audioRequirement) }

        return requirements.first { requirement in
            requirement.alternatives.isDisjoint(with: availableEncoders)
        }?.label
    }

    private func videoEncoderRequirement(
        label: String,
        hardware: String,
        software: String,
        policy: HardwareAccelerationPolicy
    ) -> (label: String, alternatives: Set<String>) {
        switch policy {
        case .auto:
            return (label, [hardware, software])
        case .forceAppleHardware:
            return (label, [hardware])
        case .softwareOnly:
            return (label, [software])
        }
    }
}
