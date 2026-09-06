import XCTest
import Foundation
@testable import FileConverterCore
@testable import FileConverterExternalBackends

final class FFmpegBuilderTests: XCTestCase {
    func testFFmpegVideoArgumentConstruction() {
        let backend = FFmpegBackend()
        let srcURL = URL(fileURLWithPath: "/tmp/sample.mkv")
        let dstURL = URL(fileURLWithPath: "/tmp/sample.mp4")

        var preset = BuiltInPresets.makeDefaultPresets().first { $0.menuName == "MP4" }!
        preset.videoCodec = .h264
        preset.audioCodec = .aac
        preset.hardwareAcceleration = .softwareOnly
        preset.crf = 22

        let args = backend.buildFFmpegArguments(sourceURL: srcURL, destURL: dstURL, preset: preset)

        XCTAssertTrue(args.contains("-i"))
        XCTAssertTrue(args.contains("/tmp/sample.mkv"))
        XCTAssertTrue(args.contains("-c:v"))
        XCTAssertTrue(args.contains("libx264"))
        XCTAssertTrue(args.contains("-crf"))
        XCTAssertTrue(args.contains("22"))
        XCTAssertTrue(args.contains("-progress"))
        XCTAssertTrue(args.contains("pipe:1"))
        XCTAssertEqual(args.last, "/tmp/sample.mp4")
    }

    func testFFmpegAudioArgumentConstruction() {
        let backend = FFmpegBackend()
        let srcURL = URL(fileURLWithPath: "/tmp/audio.wav")
        let dstURL = URL(fileURLWithPath: "/tmp/audio.mp3")

        var preset = BuiltInPresets.makeDefaultPresets().first { $0.menuName == "MP3" }!
        preset.category = .audio
        preset.audioCodec = .mp3
        preset.audioBitrateKbps = 320

        let args = backend.buildFFmpegArguments(sourceURL: srcURL, destURL: dstURL, preset: preset)

        XCTAssertTrue(args.contains("-vn"))
        XCTAssertTrue(args.contains("-c:a"))
        XCTAssertTrue(args.contains("libmp3lame"))
        XCTAssertTrue(args.contains("-b:a"))
        XCTAssertTrue(args.contains("320k"))
        XCTAssertEqual(args.last, "/tmp/audio.mp3")
    }

    func testFFmpegAudioSplitArgumentConstructionUsesSegmentMuxer() {
        let backend = FFmpegBackend()
        let srcURL = URL(fileURLWithPath: "/tmp/audio.wav")
        let dstURL = URL(fileURLWithPath: "/tmp/audio-part-%03d.mp3")
        var preset = BuiltInPresets.makeDefaultPresets().first {
            $0.builtInKey == "audio.split-mp3-5min"
        }!
        preset.audioSplitDurationSeconds = 90

        let args = backend.buildFFmpegArguments(sourceURL: srcURL, destURL: dstURL, preset: preset)

        XCTAssertTrue(args.contains("-f"))
        XCTAssertTrue(args.contains("segment"))
        XCTAssertTrue(args.contains("-segment_time"))
        XCTAssertTrue(args.contains("90"))
        XCTAssertTrue(args.contains("-segment_start_number"))
        XCTAssertTrue(args.contains("-reset_timestamps"))
        XCTAssertEqual(args.last, dstURL.path)
    }

    func testSplitStagingNamesRemainInNaturalOrderForLongRecordings() {
        XCTAssertEqual(
            FFmpegBackend.splitStagingFilenamePattern(totalOutputCount: 1_001, extensionName: "mp3"),
            "segment-%06d.mp3"
        )
        XCTAssertEqual(
            FFmpegBackend.splitStagingFilenamePattern(totalOutputCount: 1_000_000, extensionName: "m4a"),
            "segment-%07d.m4a"
        )
    }

    func testAudioSplitStagingUsesTheOutputDirectory() {
        let output = PlannedConversionOutput(
            finalURL: URL(fileURLWithPath: "/Volumes/External Audio/part-001.mp3"),
            temporaryURL: URL(fileURLWithPath: "/Volumes/External Audio/.part-001.mp3")
        )

        let stagingDirectory = FFmpegBackend.splitStagingDirectory(for: output, jobID: UUID())

        XCTAssertEqual(
            stagingDirectory.deletingLastPathComponent(),
            output.temporaryURL.deletingLastPathComponent()
        )
        XCTAssertTrue(stagingDirectory.lastPathComponent.hasPrefix(".FileConverter-AudioSplit-"))
    }

    func testAudioSplitReportsMissingFFprobeInsteadOfMalformedSource() async throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FFmpegBuilderTests-\(UUID().uuidString).wav"
        )
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try Data().write(to: sourceURL)

        let backend = FFmpegBackend(executablePathProvider: { toolName in
            toolName == "ffmpeg" ? "/tmp/fake-ffmpeg" : nil
        })
        let preset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "audio.split-mp3-5min" }
        )
        let job = ConversionJob(sourceURL: sourceURL, preset: preset)

        do {
            _ = try await backend.outputRequirements(for: job)
            XCTFail("Audio splitting should require FFprobe before probing the source")
        } catch let error as ConversionError {
            XCTAssertEqual(
                error,
                .dependencyMissing(
                    dependencyName: "FFprobe (included with FFmpeg)",
                    installCommand: "brew install ffmpeg"
                )
            )
        }
    }

    func testTargetAudioSizeReportsMissingFFprobeBeforeLaunchingFFmpeg() async throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FFmpegBuilderTests-\(UUID().uuidString).wav"
        )
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try Data().write(to: sourceURL)

        let backend = FFmpegBackend(executablePathProvider: { toolName in
            toolName == "ffmpeg" ? "/tmp/fake-ffmpeg" : nil
        })
        let preset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "audio.fit-5mb" }
        )
        let job = ConversionJob(
            sourceURL: sourceURL,
            destinationURL: sourceURL.deletingPathExtension().appendingPathExtension("m4a"),
            preset: preset
        )

        do {
            try await backend.convert(job: job) { _ in }
            XCTFail("Target-size audio should require FFprobe before launching FFmpeg")
        } catch let error as ConversionError {
            XCTAssertEqual(
                error,
                .dependencyMissing(
                    dependencyName: "FFprobe (included with FFmpeg)",
                    installCommand: "brew install ffmpeg"
                )
            )
        }
    }
}
