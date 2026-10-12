import XCTest
@testable import FileConverterCore
@testable import FileConverterNativeBackends

/// Converts fixtures with the native AVFoundation path and inspects results.
final class NativeTranscoderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try BackendHarness.makeTempDirectory("NativeVideo")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func convert(_ fixture: String, _ preset: ConversionPreset) async throws -> (URL, [String]) {
        let source = try TestFixtures.copy(fixture, to: directory)
        var preset = preset
        preset.backend = .avFoundation
        let (outputs, result) = try await BackendHarness.convert(
            backend: AVFoundationBackend(), source: source, preset: preset, into: directory,
            baseName: "out-\(UUID().uuidString.prefix(6))"
        )
        return (try XCTUnwrap(outputs.first), result.warnings)
    }

    func testQualityVariantsDifferOnTheNativePath() async throws {
        let (balanced, _) = try await convert("landscape_1920x1080_h264.mp4", try BackendHarness.builtIn("video.mp4-smaller"))
        let (high, _) = try await convert("landscape_1920x1080_h264.mp4", try BackendHarness.builtIn("video.mp4-high-quality"))
        let small = try XCTUnwrap(try MediaAssertions.probe(balanced).video?.bitRate)
        let large = try XCTUnwrap(try MediaAssertions.probe(high).video?.bitRate)
        XCTAssertLessThan(Double(small), Double(large) * 0.7, "smaller \(small) vs high \(large)")
    }

    func testResolutionPresetScalesLandscape() async throws {
        let (output, _) = try await convert("landscape_1920x1080_h264.mp4", try BackendHarness.builtIn("video.mp4-720p"))
        let size = try XCTUnwrap(try MediaAssertions.probe(output).displaySize)
        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 720)
    }

    func testPortraitStaysPortrait() async throws {
        let (output, _) = try await convert("portrait_1080x1920_h264.mov", try BackendHarness.builtIn("video.mp4-720p"))
        let size = try XCTUnwrap(try MediaAssertions.probe(output).displaySize)
        XCTAssertEqual(size.width, 720)
        XCTAssertEqual(size.height, 1280)
    }

    func testSmallSourceIsNotUpscaled() async throws {
        let (output, _) = try await convert("small_640x360_h264.mp4", try BackendHarness.builtIn("video.mp4-1080p"))
        let size = try XCTUnwrap(try MediaAssertions.probe(output).displaySize)
        XCTAssertEqual(size.width, 640)
        XCTAssertEqual(size.height, 360)
    }

    func testFrameRateOverrideIsHonored() async throws {
        var preset = try BackendHarness.builtIn("video.mp4-balanced")
        preset.framerate = 15
        let (output, _) = try await convert("small_640x360_h264.mp4", preset)
        let fps = try XCTUnwrap(try MediaAssertions.probe(output).video?.averageFrameRate)
        XCTAssertEqual(fps, 15, accuracy: 0.5, "source is 30 fps")
    }

    func testHEVCOutputIsTaggedAndHDRKept() async throws {
        let (output, warnings) = try await convert("hdr_hlg_hevc_10bit.mov", try BackendHarness.builtIn("video.hevc-hardware"))
        let video = try XCTUnwrap(try MediaAssertions.probe(output).video)
        XCTAssertEqual(video.codecName, "hevc")
        XCTAssertEqual(video.codecTag, "hvc1")
        XCTAssertTrue(video.pixelFormat?.contains("10") == true, "\(video.pixelFormat ?? "nil")")
        XCTAssertEqual(video.colorTransfer, "arib-std-b67")
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
    }

    func testHDRToH264IsToneMappedToSDR() async throws {
        let (output, warnings) = try await convert("hdr_hlg_hevc_10bit.mov", try BackendHarness.builtIn("video.mp4-balanced"))
        let video = try XCTUnwrap(try MediaAssertions.probe(output).video)
        XCTAssertEqual(video.codecName, "h264")
        XCTAssertEqual(video.colorTransfer, "bt709")
        XCTAssertTrue(warnings.contains { $0.contains("standard range") })
    }

    func testMOVToMP4PassthroughKeepsTheOriginalStream() async throws {
        let (output, _) = try await convert("portrait_1080x1920_h264.mov", try BackendHarness.builtIn("video.mov-to-mp4"))
        let bytes = try Data(contentsOf: output)
        XCTAssertNotNil(bytes.range(of: Data("x264 - core".utf8)), "MOV → MP4 should not re-encode")
        XCTAssertEqual(output.pathExtension, "mp4")
    }

    func testAudioIsKept() async throws {
        let (output, _) = try await convert("landscape_1920x1080_h264.mp4", try BackendHarness.builtIn("video.mp4-balanced"))
        XCTAssertEqual(try MediaAssertions.probe(output).audioStreams.first?.codecName, "aac")
    }
}
