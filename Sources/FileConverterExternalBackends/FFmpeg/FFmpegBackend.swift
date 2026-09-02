import Foundation
import FileConverterCore

public final class FFmpegBackend: ConversionBackend, @unchecked Sendable {
    public let backendType: BackendType = .ffmpeg
    public var isAvailable: Bool {
        ExternalToolDiscovery.shared.isToolAvailable("ffmpeg")
    }

    private let processRegistry = ExternalProcessRegistry()

    public init() {}

    public func supports(sourceFormat: FormatDefinition, destinationFormat: FormatDefinition, preset: ConversionPreset) -> Bool {
        return (sourceFormat.category == .video || sourceFormat.category == .audio) &&
               (destinationFormat.category == .video || destinationFormat.category == .audio || destinationFormat.id == "gif")
    }

    public func cancel(jobID: UUID) async {
        processRegistry.cancel(jobID: jobID)
    }

    public func convert(job: ConversionJob, progressHandler: @escaping @Sendable (ConversionProgress) -> Void) async throws {
        guard let ffmpegPath = ExternalToolDiscovery.shared.executablePath(for: "ffmpeg") else {
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
        let arguments = buildFFmpegArguments(
            sourceURL: sourceURL,
            destURL: destURL,
            preset: job.preset,
            availableEncoders: availableEncoders
        )

        let startTime = Date()
        let process = ExternalProcessAttempt(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: arguments,
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
        }

        let exitCode = result.terminationStatus
        if exitCode == 0 {
            progressHandler(ConversionProgress(fractionCompleted: 1.0, elapsedTime: Date().timeIntervalSince(startTime)))
        } else if exitCode == 15 || exitCode == 9 {
            // SIGTERM or SIGKILL
            throw ConversionError.cancelled
        } else {
            throw ConversionError.externalToolFailed(tool: "FFmpeg", exitCode: exitCode, stderr: result.stderr)
        }
    }

    private func probeMediaDuration(sourceURL: URL, jobID: UUID) async throws -> Double? {
        guard let ffprobePath = ExternalToolDiscovery.shared.executablePath(for: "ffprobe") else {
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
            stdoutCaptureLimit: 64 * 1024
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
            availableEncoders: ExternalToolDiscovery.shared.availableFFmpegEncoders()
        )
    }

    private func buildFFmpegArguments(
        sourceURL: URL,
        destURL: URL,
        preset: ConversionPreset,
        availableEncoders: Set<String>
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

        let isAppleSilicon = availableEncoders.contains("h264_videotoolbox")

        let isAudioOnly = preset.category == .audio || preset.videoCodec == .none
        let targetExt = destURL.pathExtension.lowercased()

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
                if let bitrate = preset.audioBitrateKbps {
                    args.append(contentsOf: ["-b:a", "\(bitrate)k"])
                }
            case .aac:
                args.append(contentsOf: ["-c:a", "aac"])
                if let bitrate = preset.audioBitrateKbps {
                    args.append(contentsOf: ["-b:a", "\(bitrate)k"])
                }
            case .opus:
                args.append(contentsOf: ["-c:a", "libopus"])
                if let bitrate = preset.audioBitrateKbps {
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

            if let sampleRate = preset.audioSampleRate {
                args.append(contentsOf: ["-ar", "\(sampleRate)"])
            }
            if let channels = preset.audioChannels {
                args.append(contentsOf: ["-ac", "\(channels)"])
            }
        } else if targetExt == "gif" {
            // High quality animated GIF filter palettegen/paletteuse
            args.append(contentsOf: [
                "-dn",
                "-vf", "fps=15,scale=640:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse",
                "-loop", "0"
            ])
        } else {
            args.append(contentsOf: ["-dn"])
            // Video encoding
            switch preset.videoCodec {
            case .h264:
                if isAppleSilicon && preset.hardwareAcceleration != .softwareOnly {
                    args.append(contentsOf: ["-c:v", "h264_videotoolbox"])
                    if let bitrate = preset.videoBitrateKbps {
                        args.append(contentsOf: ["-b:v", "\(bitrate)k"])
                    } else {
                        args.append(contentsOf: ["-q:v", "65"])
                    }
                } else {
                    args.append(contentsOf: ["-c:v", "libx264", "-preset", "medium"])
                    if let crf = preset.crf {
                        args.append(contentsOf: ["-crf", "\(crf)"])
                    }
                }

            case .hevc:
                if isAppleSilicon && preset.hardwareAcceleration != .softwareOnly {
                    args.append(contentsOf: ["-c:v", "hevc_videotoolbox"])
                    if let bitrate = preset.videoBitrateKbps {
                        args.append(contentsOf: ["-b:v", "\(bitrate)k"])
                    } else {
                        args.append(contentsOf: ["-q:v", "65"])
                    }
                } else {
                    args.append(contentsOf: ["-c:v", "libx265", "-preset", "medium"])
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
                    if let crf = preset.crf {
                        args.append(contentsOf: ["-crf", "\(crf)"])
                    }
                } else {
                    args.append(contentsOf: ["-c:v", "libaom-av1"])
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
                } else if isAppleSilicon && preset.hardwareAcceleration != .softwareOnly {
                    args.append(contentsOf: ["-c:v", "h264_videotoolbox"])
                } else {
                    args.append(contentsOf: ["-c:v", "libx264"])
                }
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
        }

        if let muxer = determineFFmpegMuxerFormat(for: targetExt) {
            args.append(contentsOf: ["-f", muxer])
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
}
