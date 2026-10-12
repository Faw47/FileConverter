import XCTest
import Foundation
@testable import FileConverterCore
@testable import FileConverterExternalBackends

final class AudioPresetFormatAwarenessTests: XCTestCase {

    // MARK: - 1. Sample Rate & Channel Controls

    func testSampleRateAndChannelArgumentsInFFmpeg() {
        let backend = FFmpegBackend()
        let srcURL = URL(fileURLWithPath: "/tmp/source.wav")
        let dstURL = URL(fileURLWithPath: "/tmp/output.mp3")

        let preset = ConversionPreset(
            name: "MP3 with Custom Sample Rate and Channels",
            menuName: "MP3 Custom",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "mp3",
            backend: .ffmpeg,
            audioCodec: .mp3,
            audioBitrateKbps: 192,
            audioSampleRate: 48_000,
            audioChannels: 2
        )

        let args = backend.buildFFmpegArguments(sourceURL: srcURL, destURL: dstURL, preset: preset)

        XCTAssertTrue(args.contains("-ar"))
        if let arIndex = args.firstIndex(of: "-ar") {
            XCTAssertEqual(args[arIndex + 1], "48000")
        }

        XCTAssertTrue(args.contains("-ac"))
        if let acIndex = args.firstIndex(of: "-ac") {
            XCTAssertEqual(args[acIndex + 1], "2")
        }
    }

    func testMonoChannelArgumentInFFmpeg() {
        let backend = FFmpegBackend()
        let srcURL = URL(fileURLWithPath: "/tmp/source.wav")
        let dstURL = URL(fileURLWithPath: "/tmp/output.aac")

        let preset = ConversionPreset(
            name: "AAC Mono",
            menuName: "AAC Mono",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "aac",
            backend: .ffmpeg,
            audioCodec: .aac,
            audioSampleRate: 22_050,
            audioChannels: 1
        )

        let args = backend.buildFFmpegArguments(sourceURL: srcURL, destURL: dstURL, preset: preset)
        XCTAssertTrue(args.contains("-ar"))
        if let arIndex = args.firstIndex(of: "-ar") {
            XCTAssertEqual(args[arIndex + 1], "22050")
        }
        XCTAssertTrue(args.contains("-ac"))
        if let acIndex = args.firstIndex(of: "-ac") {
            XCTAssertEqual(args[acIndex + 1], "1")
        }
    }

    func testSampleRateAndChannelValidationBounds() {
        var preset = ConversionPreset(
            name: "Bounds Test",
            menuName: "Bounds",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "mp3",
            backend: .ffmpeg,
            audioCodec: .mp3,
            audioSampleRate: -1,
            audioChannels: 0
        )

        var errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("sample rate must be a positive number") })
        XCTAssertTrue(errors.contains { $0.contains("channel count must be between 1 and 8") })

        preset.audioSampleRate = 48_000
        preset.audioChannels = 6 // 5.1 Surround
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertFalse(errors.contains { $0.contains("sample rate") })
        XCTAssertFalse(errors.contains { $0.contains("channel count") })
    }

    // MARK: - 2. Duration Parser (HH:MM:SS.ss)

    func testAudioDurationParserFormatting() {
        XCTAssertEqual(AudioDurationParser.format(seconds: 0), "00:00:00.00")
        XCTAssertEqual(AudioDurationParser.format(seconds: 30), "00:00:30.00")
        XCTAssertEqual(AudioDurationParser.format(seconds: 60), "00:01:00.00")
        XCTAssertEqual(AudioDurationParser.format(seconds: 300), "00:05:00.00")
        XCTAssertEqual(AudioDurationParser.format(seconds: 3661.25), "01:01:01.25")
        XCTAssertEqual(AudioDurationParser.format(seconds: 86_399.99), "23:59:59.99")
    }

    func testAudioDurationParserParsing() {
        XCTAssertEqual(AudioDurationParser.parse("00:05:00.00"), 300.0)
        XCTAssertEqual(AudioDurationParser.parseSecondsInt("00:05:00.00"), 300)
        XCTAssertEqual(AudioDurationParser.parseSecondsInt("00:01:30.00"), 90)
        XCTAssertEqual(AudioDurationParser.parseSecondsInt("01:00:00"), 3600)
        XCTAssertEqual(AudioDurationParser.parseSecondsInt("05:00"), 300)
        XCTAssertEqual(AudioDurationParser.parse("00:00:15.50"), 15.5)

        // Invalid cases
        XCTAssertNil(AudioDurationParser.parse(""))
        XCTAssertNil(AudioDurationParser.parse("-00:05:00"))
        XCTAssertNil(AudioDurationParser.parse("invalid"))
        XCTAssertNil(AudioDurationParser.parse("00:65:00")) // 65 minutes is invalid
        XCTAssertNil(AudioDurationParser.parse("00:05:70")) // 70 seconds is invalid
    }

    func testAudioDurationValidationHelper() {
        XCTAssertNil(AudioDurationParser.validateDurationString("00:05:00.00"))
        XCTAssertNil(AudioDurationParser.validateDurationString("00:00:30.00"))
        XCTAssertNil(AudioDurationParser.validateDurationString("00:00:05.00"))
        XCTAssertNil(AudioDurationParser.validateDurationString("25:00:00.00"))

        XCTAssertNotNil(AudioDurationParser.validateDurationString(""))
        XCTAssertTrue(AudioDurationParser.validateDurationString("-00:01:00")?.contains("negative") == true)
        XCTAssertTrue(AudioDurationParser.validateDurationString("00:00:00.00")?.contains("at least 1 second") == true)
    }

    // MARK: - 3. Direct Stream Copy Gating

    func testDirectStreamCopyFFmpegArgumentsSuppressTranscodingFlags() {
        let backend = FFmpegBackend()
        let srcURL = URL(fileURLWithPath: "/tmp/input.m4a")
        let dstURL = URL(fileURLWithPath: "/tmp/output.m4a")

        let preset = ConversionPreset(
            name: "Stream Copy",
            menuName: "Copy",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "m4a",
            backend: .ffmpeg,
            audioCodec: .copy,
            quality: .high,
            audioBitrateKbps: 320,      // Stale / conflicting parameter
            audioSampleRate: 48_000,    // Stale / conflicting parameter
            audioChannels: 2            // Stale / conflicting parameter
        )

        let args = backend.buildFFmpegArguments(sourceURL: srcURL, destURL: dstURL, preset: preset)

        XCTAssertTrue(args.contains("-c:a"))
        if let caIndex = args.firstIndex(of: "-c:a") {
            XCTAssertEqual(args[caIndex + 1], "copy")
        }

        // Must NOT contain transcoding flags
        XCTAssertFalse(args.contains("-b:a"), "Direct Stream Copy must not include -b:a")
        XCTAssertFalse(args.contains("-ar"), "Direct Stream Copy must not include -ar")
        XCTAssertFalse(args.contains("-ac"), "Direct Stream Copy must not include -ac")
        XCTAssertFalse(args.contains("-q:a"), "Direct Stream Copy must not include -q:a")
    }

    func testDirectStreamCopyRejectsTargetFileSizeInValidation() {
        var preset = ConversionPreset(
            name: "Invalid Copy Size",
            menuName: "Copy Size",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "m4a",
            backend: .ffmpeg,
            audioCodec: .copy
        )
        preset.audioTargetFileSizeBytes = 10_000_000

        let errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Direct Stream Copy cannot target a specific file size") })
    }

    // MARK: - 4. PCM WAV / AIFF Bit Depth Controls

    func testPCMWavBitDepthEncodersInFFmpeg() {
        let backend = FFmpegBackend()
        let srcURL = URL(fileURLWithPath: "/tmp/input.flac")
        let dstURL = URL(fileURLWithPath: "/tmp/output.wav")

        var preset = ConversionPreset(
            name: "WAV 16-bit",
            menuName: "WAV 16",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "wav",
            backend: .ffmpeg,
            audioCodec: .wav,
            audioBitDepth: .bit16
        )

        var args = backend.buildFFmpegArguments(sourceURL: srcURL, destURL: dstURL, preset: preset)
        if let caIndex = args.firstIndex(of: "-c:a") {
            XCTAssertEqual(args[caIndex + 1], "pcm_s16le")
        }
        XCTAssertFalse(args.contains("-b:a"), "WAV must not emit -b:a")

        // 24-bit
        preset.audioBitDepth = .bit24
        args = backend.buildFFmpegArguments(sourceURL: srcURL, destURL: dstURL, preset: preset)
        if let caIndex = args.firstIndex(of: "-c:a") {
            XCTAssertEqual(args[caIndex + 1], "pcm_s24le")
        }
        XCTAssertFalse(args.contains("-b:a"))

        // 32-bit float
        preset.audioBitDepth = .bit32Float
        args = backend.buildFFmpegArguments(sourceURL: srcURL, destURL: dstURL, preset: preset)
        if let caIndex = args.firstIndex(of: "-c:a") {
            XCTAssertEqual(args[caIndex + 1], "pcm_f32le")
        }
        XCTAssertFalse(args.contains("-b:a"))
    }

    func testPCMAiffBitDepthEncodersInFFmpeg() {
        let backend = FFmpegBackend()
        let srcURL = URL(fileURLWithPath: "/tmp/input.wav")
        let dstURL = URL(fileURLWithPath: "/tmp/output.aiff")

        let preset = ConversionPreset(
            name: "AIFF 24-bit",
            menuName: "AIFF 24",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "aiff",
            backend: .ffmpeg,
            audioCodec: .aiff,
            audioBitDepth: .bit24
        )

        let args = backend.buildFFmpegArguments(sourceURL: srcURL, destURL: dstURL, preset: preset)
        if let caIndex = args.firstIndex(of: "-c:a") {
            XCTAssertEqual(args[caIndex + 1], "pcm_s24be")
        }
        XCTAssertFalse(args.contains("-b:a"))
    }

    func testLosslessCodecsSuppressBitrateFlag() {
        let backend = FFmpegBackend()
        let srcURL = URL(fileURLWithPath: "/tmp/input.wav")
        let dstURL = URL(fileURLWithPath: "/tmp/output.flac")

        let preset = ConversionPreset(
            name: "FLAC Lossless",
            menuName: "FLAC",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "flac",
            backend: .ffmpeg,
            audioCodec: .flac,
            audioBitrateKbps: 320 // should be suppressed for FLAC
        )

        let args = backend.buildFFmpegArguments(sourceURL: srcURL, destURL: dstURL, preset: preset)
        if let caIndex = args.firstIndex(of: "-c:a") {
            XCTAssertEqual(args[caIndex + 1], "flac")
        }
        XCTAssertFalse(args.contains("-b:a"), "FLAC encoder must not receive -b:a")
    }

    // MARK: - 5. Codec-Aware Quality Settings

    func testLossyCodecsDisallowLosslessQuality() {
        for lossyCodec in [AudioCodecType.aac, AudioCodecType.mp3, AudioCodecType.opus] {
            let preset = ConversionPreset(
                name: "Invalid Lossless",
                menuName: "Lossless",
                category: .audio,
                sourceFormats: ["audio"],
                destinationFormat: lossyCodec == .aac ? "m4a" : (lossyCodec == .mp3 ? "mp3" : "opus"),
                backend: .ffmpeg,
                audioCodec: lossyCodec,
                quality: .lossless
            )

            let errors = PresetValidator.validationErrors(for: preset)
            XCTAssertTrue(
                errors.contains { $0.contains("Lossless quality cannot be used with lossy audio codec") },
                "Codec \(lossyCodec) must reject lossless quality"
            )
        }
    }

    func testLosslessCodecsAllowLosslessQuality() {
        for losslessCodec in [AudioCodecType.flac, AudioCodecType.alac, AudioCodecType.wav, AudioCodecType.aiff] {
            let destFormat: String
            switch losslessCodec {
            case .flac: destFormat = "flac"
            case .alac: destFormat = "m4a"
            case .wav: destFormat = "wav"
            case .aiff: destFormat = "aiff"
            default: destFormat = "wav"
            }

            let preset = ConversionPreset(
                name: "Valid Lossless",
                menuName: "Lossless",
                category: .audio,
                sourceFormats: ["audio"],
                destinationFormat: destFormat,
                backend: .ffmpeg,
                audioCodec: losslessCodec,
                quality: .lossless
            )

            let errors = PresetValidator.validationErrors(for: preset)
            XCTAssertFalse(
                errors.contains { $0.contains("Lossless quality cannot be used") },
                "Codec \(losslessCodec) must allow lossless quality"
            )
        }
    }

    // MARK: - 6. Container and Codec Compatibility Validation

    func testContainerAndCodecCompatibilityValidation() {
        // Incompatible: AAC codec in MP3 container
        let invalidPreset = ConversionPreset(
            name: "AAC in MP3",
            menuName: "Bad",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "mp3",
            backend: .ffmpeg,
            audioCodec: .aac
        )

        let errors = PresetValidator.validationErrors(for: invalidPreset)
        XCTAssertTrue(errors.contains { $0.contains("cannot contain audio codec") })

        // Compatible: MP3 in MP3
        let validPreset = ConversionPreset(
            name: "MP3 in MP3",
            menuName: "Good",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "mp3",
            backend: .ffmpeg,
            audioCodec: .mp3
        )
        let noErrors = PresetValidator.validationErrors(for: validPreset)
        XCTAssertFalse(noErrors.contains { $0.contains("cannot contain audio codec") })
    }

    func testStreamCopyMuxerCompatibilityValidation() {
        XCTAssertTrue(FFmpegBackend.isMuxerCompatible(sourceAudioCodec: "aac", destinationFormat: "m4a"))
        XCTAssertTrue(FFmpegBackend.isMuxerCompatible(sourceAudioCodec: "mp3", destinationFormat: "mp3"))
        XCTAssertTrue(FFmpegBackend.isMuxerCompatible(sourceAudioCodec: "flac", destinationFormat: "flac"))
        XCTAssertTrue(FFmpegBackend.isMuxerCompatible(sourceAudioCodec: "opus", destinationFormat: "ogg"))

        // Incompatible stream copy
        XCTAssertFalse(FFmpegBackend.isMuxerCompatible(sourceAudioCodec: "aac", destinationFormat: "mp3"))
        XCTAssertFalse(FFmpegBackend.isMuxerCompatible(sourceAudioCodec: "flac", destinationFormat: "mp3"))
        XCTAssertFalse(FFmpegBackend.isMuxerCompatible(sourceAudioCodec: "opus", destinationFormat: "wav"))
    }

    func testFLACCompressionLevelMapping() {
        let backend = FFmpegBackend()
        let src = URL(fileURLWithPath: "/tmp/in.wav")
        let dst = URL(fileURLWithPath: "/tmp/out.flac")

        // FLAC with low quality -> compression level 2
        let presetLow = ConversionPreset(
            name: "FLAC Low",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "flac",
            backend: .ffmpeg,
            audioCodec: .flac,
            quality: .low
        )
        let argsLow = backend.buildFFmpegArguments(sourceURL: src, destURL: dst, preset: presetLow)
        XCTAssertTrue(argsLow.contains("-compression_level"))
        if let idx = argsLow.firstIndex(of: "-compression_level") {
            XCTAssertEqual(argsLow[idx + 1], "2")
        }

        // FLAC with high quality -> compression level 8
        let presetHigh = ConversionPreset(
            name: "FLAC High",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "flac",
            backend: .ffmpeg,
            audioCodec: .flac,
            quality: .high
        )
        let argsHigh = backend.buildFFmpegArguments(sourceURL: src, destURL: dst, preset: presetHigh)
        if let idx = argsHigh.firstIndex(of: "-compression_level") {
            XCTAssertEqual(argsHigh[idx + 1], "8")
        }

        // Bitrate is NOT present for FLAC
        XCTAssertFalse(argsHigh.contains("-b:a"))
    }

    func testRelaxedSplitDurationValidation() {
        var preset = ConversionPreset(
            name: "MP3 Split",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "mp3"
        )
        preset.audioSplitDurationSeconds = 1 // 1 second is now valid
        XCTAssertTrue(PresetValidator.validationErrors(for: preset).isEmpty)

        preset.audioSplitDurationSeconds = 5 // 5 seconds is valid
        XCTAssertTrue(PresetValidator.validationErrors(for: preset).isEmpty)

        preset.audioSplitDurationSeconds = 100_000 // > 24 hours is valid
        XCTAssertTrue(PresetValidator.validationErrors(for: preset).isEmpty)

        preset.audioSplitDurationSeconds = 0 // 0 seconds is invalid
        XCTAssertTrue(PresetValidator.validationErrors(for: preset).contains { $0.contains("at least 1 second") })
    }
}
