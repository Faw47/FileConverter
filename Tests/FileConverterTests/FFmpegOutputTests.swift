import XCTest
@testable import FileConverterCore
@testable import FileConverterExternalBackends

/// Converts real fixtures with FFmpeg and inspects the produced files.
final class FFmpegOutputTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        guard TestFixtures.ffmpegPath != nil, TestFixtures.ffprobePath != nil else {
            throw XCTSkip("FFmpeg is not installed.")
        }
        directory = try BackendHarness.makeTempDirectory("FFmpegOutput")
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func convert(_ fixture: String, preset: ConversionPreset, ext: String? = nil) async throws -> (URL, [String]) {
        let source = try TestFixtures.copy(fixture, to: directory)
        var preset = preset
        if let ext { preset.destinationFormat = ext }
        let (outputs, result) = try await BackendHarness.convert(
            backend: FFmpegBackend(), source: source, preset: preset, into: directory,
            baseName: "out-\(UUID().uuidString.prefix(6))"
        )
        return (try XCTUnwrap(outputs.first), result.warnings)
    }

    private func ffmpegPreset(_ key: String) throws -> ConversionPreset {
        var preset = try BackendHarness.builtIn(key)
        preset.backend = .ffmpeg
        return preset
    }

    func testPortraitVideoStaysPortraitAt1080p() async throws {
        let (output, _) = try await convert("portrait_1080x1920_h264.mov", preset: try ffmpegPreset("video.mp4-1080p"))
        let size = try XCTUnwrap(try MediaAssertions.probe(output).displaySize)
        XCTAssertEqual(size.width, 1080, "was 608 with the landscape-only box")
        XCTAssertEqual(size.height, 1920)
    }

    func testSmallVideoIsNotUpscaled() async throws {
        let (output, _) = try await convert("small_640x360_h264.mp4", preset: try ffmpegPreset("video.mp4-720p"))
        let size = try XCTUnwrap(try MediaAssertions.probe(output).displaySize)
        XCTAssertEqual(size.width, 640)
        XCTAssertEqual(size.height, 360)
    }

    func testLargeVideoIsScaledDown() async throws {
        let (output, _) = try await convert("landscape_1920x1080_h264.mp4", preset: try ffmpegPreset("video.mp4-720p"))
        let size = try XCTUnwrap(try MediaAssertions.probe(output).displaySize)
        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 720)
    }

    func testHEVCIsTaggedForAppleAppsAndFastStart() async throws {
        let (output, _) = try await convert("landscape_1920x1080_h264.mp4", preset: try ffmpegPreset("video.hevc-hardware"))
        let video = try XCTUnwrap(try MediaAssertions.probe(output).video)
        XCTAssertEqual(video.codecName, "hevc")
        XCTAssertEqual(video.codecTag, "hvc1", "QuickTime and Photos need hvc1")
        XCTAssertTrue(try MediaAssertions.isFastStart(output))
    }

    func testQualityVariantsProduceDifferentBitrates() async throws {
        let (small, _) = try await convert("landscape_1920x1080_h264.mp4", preset: try ffmpegPreset("video.mp4-smaller"))
        let (high, _) = try await convert("landscape_1920x1080_h264.mp4", preset: try ffmpegPreset("video.mp4-high-quality"))
        let smallSize = FileAccessManager.shared.fileSize(at: small)
        let highSize = FileAccessManager.shared.fileSize(at: high)
        XCTAssertLessThan(Double(smallSize), Double(highSize) * 0.8, "small \(smallSize) vs high \(highSize)")
    }

    func testMKVToMP4CopiesStreamsKeepsAllAudioSubtitlesAndChapters() async throws {
        let source = try MediaAssertions.probe(try TestFixtures.url("multitrack.mkv"))
        let (output, _) = try await convert("multitrack.mkv", preset: try BackendHarness.builtIn("video.mkv-to-mp4"))
        let probe = try MediaAssertions.probe(output)
        XCTAssertEqual(probe.audioStreams.count, 2)
        XCTAssertEqual(probe.subtitleStreams.first?.codecName, "mov_text")
        XCTAssertEqual(probe.chapterCount, source.chapterCount)
        XCTAssertEqual(probe.video?.codecName, "h264")
        // Stream copy keeps the original x264 bitstream (a re-encode with
        // VideoToolbox would not carry x264's encoder banner).
        let bytes = try Data(contentsOf: output)
        XCTAssertNotNil(bytes.range(of: Data("x264 - core".utf8)), "video was re-encoded instead of copied")
    }

    func testHDRKeepsTenBitWhenTargetIsHEVC() async throws {
        let (output, _) = try await convert("hdr_hlg_hevc_10bit.mov", preset: try ffmpegPreset("video.hevc-hardware"))
        let video = try XCTUnwrap(try MediaAssertions.probe(output).video)
        XCTAssertTrue(video.pixelFormat?.contains("10") == true, "\(video.pixelFormat ?? "nil")")
        XCTAssertEqual(video.colorTransfer, "arib-std-b67")
    }

    func testHDRToH264IsHandledDeliberately() async throws {
        let (output, warnings) = try await convert("hdr_hlg_hevc_10bit.mov", preset: try ffmpegPreset("video.mp4-balanced"))
        let video = try XCTUnwrap(try MediaAssertions.probe(output).video)
        XCTAssertEqual(video.pixelFormat, "yuv420p")
        if ExternalToolDiscovery.shared.hasFFmpegFilter("zscale") {
            XCTAssertEqual(video.colorTransfer, "bt709", "tone-mapped to SDR")
        } else {
            XCTAssertEqual(video.colorTransfer, "arib-std-b67", "labels must stay truthful")
            XCTAssertTrue(warnings.contains { $0.contains("HDR") }, "\(warnings)")
        }
    }

    func testGIFOriginalSizeKeepsSourceWidth() async throws {
        var preset = try BackendHarness.builtIn("video.animated-gif")
        preset.resolution = .original
        let (output, _) = try await convert("small_640x360_h264.mp4", preset: preset)
        XCTAssertEqual(try ImageAssertions.info(output).width, 640)
    }

    func testGIFPresetFitsInto480() async throws {
        let (output, _) = try await convert("small_640x360_h264.mp4", preset: try BackendHarness.builtIn("video.animated-gif"))
        XCTAssertEqual(try ImageAssertions.info(output).width, 480)
    }
}
