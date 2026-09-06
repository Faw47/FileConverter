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

    public func cancel(jobID: UUID) async {
        processRegistry.cancel(jobID: jobID)
    }

    public func outputRequirements(for job: ConversionJob) async throws -> [ConversionOutputRequirement] {
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
        try await convert(job: singleOutputJob, progressHandler: progressHandler)
        return BackendConversionResult()
    }

    public func convert(job: ConversionJob, progressHandler: @escaping @Sendable (ConversionProgress) -> Void) async throws {
        guard let ffmpegPath = executablePathProvider("ffmpeg") else {
            throw ConversionError.dependencyMissing(dependencyName: "FFmpeg", installCommand: "brew install ffmpeg")
        }

        let jobID = job.id
        let sourceURL = job.sourceURL
        guard let destURL = job.temporaryOutputURL ?? job.destinationURL else {
            throw ConversionError.destinationUnavailable(path: "")
        }

        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }

        // Probe total duration with ffprobe for accurate progress calculation
        if job.preset.audioTargetFileSizeBytes != nil {
            try requireFFprobe()
        }
        let totalDurationSeconds: Double
        do {
            totalDurationSeconds = try await probeMediaDuration(sourceURL: sourceURL, jobID: jobID) ?? 0.0
        } catch is CancellationError {
            throw ConversionError.cancelled
        }
        try Task.checkCancellation()

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
                availableEncoders: availableEncoders,
                ffmpegPath: ffmpegPath,
                jobID: jobID,
                progressHandler: progressHandler
            )
            return
        }

        let arguments = buildFFmpegArguments(
            sourceURL: sourceURL,
            destURL: destURL,
            preset: job.preset,
            availableEncoders: availableEncoders
        )
        try await runFFmpeg(
            executablePath: ffmpegPath,
            arguments: arguments,
            jobID: jobID,
            totalDurationSeconds: totalDurationSeconds,
            progressHandler: progressHandler
        )
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
                audioBitrateOverride: bitrate
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
                return dur
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

    private func buildFFmpegArguments(
        sourceURL: URL,
        destURL: URL,
        preset: ConversionPreset,
        availableEncoders: Set<String>,
        audioBitrateOverride: Int? = nil,
        segmentDuration: Int? = nil
    ) -> [String] {
        var args: [String] = [
            "-y",
            "-nostdin",
            "-hide_banner"
        ]

        if sourceURL.pathExtension.lowercased() == "qta" {
            args.append(contentsOf: ["-f", "mov"])
        }

        args.append(contentsOf: ["-i", sourceURL.path])

        let hasH264HardwareEncoder = availableEncoders.contains("h264_videotoolbox")
        let hasHEVCHardwareEncoder = availableEncoders.contains("hevc_videotoolbox")

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
            case .alac:
                args.append(contentsOf: ["-c:a", "alac"])
            case .wav:
                args.append(contentsOf: ["-c:a", "pcm_s16le"])
            case .aiff:
                args.append(contentsOf: ["-c:a", "pcm_s16be"])
            default:
                if targetExt == "mp3" { args.append(contentsOf: ["-c:a", "libmp3lame"]) }
                else if targetExt == "ogg" { args.append(contentsOf: ["-c:a", "libvorbis"]) }
                else if targetExt == "opus" { args.append(contentsOf: ["-c:a", "libopus"]) }
                else if targetExt == "flac" { args.append(contentsOf: ["-c:a", "flac"]) }
                else { args.append(contentsOf: ["-c:a", "aac"]) }
            }

            if preset.audioCodec == .auto, let bitrate = effectiveAudioBitrate {
                args.append(contentsOf: ["-b:a", "\(bitrate)k"])
            }

            if let sampleRate = preset.audioSampleRate {
                args.append(contentsOf: ["-ar", "\(sampleRate)"])
            }
            if let channels = preset.audioChannels {
                args.append(contentsOf: ["-ac", "\(channels)"])
            }
        } else if targetExt == "gif" {
            // High quality animated GIF filter palettegen/paletteuse
            let fps = preset.framerate.map { String(format: "%.3g", $0) } ?? "15"
            let scale: String = {
                switch preset.resolution {
                case .uhd4k: return "3840:-1"
                case .hd1080p: return "1920:-1"
                case .hd720p: return "1280:-1"
                case .sd480p: return "854:-1"
                case .custom(let width, _): return "\(width):-1"
                case .original: return "640:-1"
                }
            }()
            args.append(contentsOf: [
                "-dn",
                "-vf", "fps=\(fps),scale=\(scale):flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse",
                "-loop", "0"
            ])
        } else {
            args.append(contentsOf: ["-dn"])
            // Video encoding
            switch preset.videoCodec {
            case .h264:
                let wantsHardware = preset.hardwareAcceleration != .softwareOnly
                if hasH264HardwareEncoder && wantsHardware {
                    args.append(contentsOf: ["-c:v", "h264_videotoolbox"])
                    if let bitrate = preset.videoBitrateKbps {
                        args.append(contentsOf: ["-b:v", "\(bitrate)k"])
                    } else {
                        args.append(contentsOf: ["-q:v", "65"])
                    }
                } else {
                    args.append(contentsOf: ["-c:v", "libx264", "-preset", "medium"])
                    if let bitrate = preset.videoBitrateKbps {
                        args.append(contentsOf: ["-b:v", "\(bitrate)k"])
                    }
                    if let crf = preset.crf {
                        args.append(contentsOf: ["-crf", "\(crf)"])
                    }
                }

            case .hevc:
                let wantsHardware = preset.hardwareAcceleration != .softwareOnly
                if hasHEVCHardwareEncoder && wantsHardware {
                    args.append(contentsOf: ["-c:v", "hevc_videotoolbox"])
                    if let bitrate = preset.videoBitrateKbps {
                        args.append(contentsOf: ["-b:v", "\(bitrate)k"])
                    } else {
                        args.append(contentsOf: ["-q:v", "65"])
                    }
                } else {
                    args.append(contentsOf: ["-c:v", "libx265", "-preset", "medium"])
                    if let bitrate = preset.videoBitrateKbps {
                        args.append(contentsOf: ["-b:v", "\(bitrate)k"])
                    }
                    if let crf = preset.crf {
                        args.append(contentsOf: ["-crf", "\(crf)"])
                    }
                }

            case .vp9:
                args.append(contentsOf: ["-c:v", "libvpx-vp9"])
                if let crf = preset.crf {
                    args.append(contentsOf: ["-crf", "\(crf)", "-b:v", "0"])
                }

            case .av1:
                if availableEncoders.contains("libsvtav1") {
                    args.append(contentsOf: ["-c:v", "libsvtav1"])
                    if let bitrate = preset.videoBitrateKbps {
                        args.append(contentsOf: ["-b:v", "\(bitrate)k"])
                    }
                    if let crf = preset.crf {
                        args.append(contentsOf: ["-crf", "\(crf)"])
                    }
                } else {
                    args.append(contentsOf: ["-c:v", "libaom-av1"])
                    if let crf = preset.crf {
                        args.append(contentsOf: ["-crf", "\(crf)"])
                    }
                }

            case .proRes:
                if availableEncoders.contains("prores_videotoolbox") {
                    args.append(contentsOf: ["-c:v", "prores_videotoolbox"])
                } else {
                    args.append(contentsOf: ["-c:v", "prores_ks", "-profile:v", "2"])
                }

            default:
                if targetExt == "webm" {
                    args.append(contentsOf: ["-c:v", "libvpx-vp9"])
                } else if hasH264HardwareEncoder && preset.hardwareAcceleration != .softwareOnly {
                    args.append(contentsOf: ["-c:v", "h264_videotoolbox"])
                } else {
                    args.append(contentsOf: ["-c:v", "libx264"])
                }
            }

            if let framerate = preset.framerate, framerate > 0 {
                args.append(contentsOf: ["-r", String(format: "%.3g", framerate)])
            }

            // Audio track
            switch preset.audioCodec {
            case .opus:
                args.append(contentsOf: ["-c:a", "libopus"])
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
               preset.audioCodec != .copy {
                args.append(contentsOf: ["-b:a", "\(bitrate)k"])
            }

            // Resolution
            switch preset.resolution {
            case .uhd4k:
                args.append(contentsOf: ["-vf", "scale=3840:2160:force_original_aspect_ratio=decrease"])
            case .hd1080p:
                args.append(contentsOf: ["-vf", "scale=1920:1080:force_original_aspect_ratio=decrease"])
            case .hd720p:
                args.append(contentsOf: ["-vf", "scale=1280:720:force_original_aspect_ratio=decrease"])
            case .sd480p:
                args.append(contentsOf: ["-vf", "scale=854:480:force_original_aspect_ratio=decrease"])
            case .custom(let w, let h):
                args.append(contentsOf: ["-vf", "scale=\(w):\(h):force_original_aspect_ratio=decrease"])
            case .original:
                break
            }
        }

        if preset.preserveMetadata {
            args.append(contentsOf: ["-map_metadata", "0"])
        } else {
            args.append(contentsOf: ["-map_metadata", "-1"])
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
        for (key, value) in preset.extraBackendOptions.sorted(by: { $0.key < $1.key }) {
            let normalizedKey = key.hasPrefix("-") ? key : "-\(key)"
            args.append(normalizedKey)
            if !value.isEmpty { args.append(value) }
        }

        // Output progress flags and destination
        args.append(contentsOf: [
            "-progress", "pipe:1",
            destURL.path
        ])

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
