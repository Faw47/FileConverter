import XCTest
@testable import FileConverterCore
@testable import FileConverterNativeBackends
@testable import FileConverterExternalBackends

final class ImageOutputTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try BackendHarness.makeTempDirectory("ImageOutput")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func convert(_ fixture: String, _ preset: ConversionPreset, backend: any ConversionBackend = ImageIOBackend()) async throws -> URL {
        let source = try TestFixtures.copy(fixture, to: directory)
        let (outputs, _) = try await BackendHarness.convert(
            backend: backend, source: source, preset: preset, into: directory,
            baseName: "out-\(UUID().uuidString.prefix(6))"
        )
        return try XCTUnwrap(outputs.first)
    }

    // TEST-018

    func testJPEGWebShrinksLargeImagesToTheirLongestSide() async throws {
        let output = try await convert("huge_12000x10000.png", try BackendHarness.builtIn("image.jpeg-web"))
        let info = try ImageAssertions.info(output)
        XCTAssertEqual(max(info.width, info.height), 2048)
        XCTAssertEqual(Double(info.width) / Double(info.height), 1.2, accuracy: 0.01)
    }

    func testSmallImagesAreNeverEnlarged() async throws {
        let output = try await convert("transparent_256.png", try BackendHarness.builtIn("image.jpeg-web"))
        XCTAssertEqual(try ImageAssertions.info(output).width, 256)
    }

    func testOneHundredTwentyMegapixelsConvertsAtFullSize() async throws {
        let output = try await convert("huge_12000x10000.png", try BackendHarness.builtIn("image.jpeg"))
        XCTAssertEqual(try ImageAssertions.info(output).width, 12_000, "was rejected over 100 MP before")
    }

    func testOversizedFullSizeConversionExplainsTheLimit() {
        let error = ConversionError.imageTooLarge(width: 20_000, height: 15_000, limitMegapixels: 250)
        XCTAssertTrue(error.localizedDescription.contains("300 MP"))
        XCTAssertTrue(error.localizedDescription.contains("size limit"))
    }

    func testImageMagickResizesToo() async throws {
        guard ExternalToolDiscovery.shared.executablePath(for: "magick") != nil else {
            throw XCTSkip("ImageMagick is not installed.")
        }
        var preset = try BackendHarness.builtIn("image.webp")
        preset.resolution = .custom(width: 1000, height: 1000)
        let output = try await convert("huge_12000x10000.png", preset, backend: ImageMagickBackend())
        XCTAssertEqual(max(try ImageAssertions.info(output).width, try ImageAssertions.info(output).height), 1000)
    }

    // TEST-019

    func testTransparencyBecomesWhiteInJPEG() async throws {
        for key in ["image.jpeg", "image.jpeg-web"] {
            var preset = try BackendHarness.builtIn(key)
            preset.preserveMetadata = false
            let output = try await convert("transparent_256.png", preset)
            let corner = try ImageAssertions.pixel(output, x: 2, y: 2)
            XCTAssertGreaterThan(corner.r, 240, key)
            XCTAssertGreaterThan(corner.g, 240, key)
            XCTAssertGreaterThan(corner.b, 240, key)
        }
    }

    // TEST-020

    func testLocationIsRemovedByDefaultButOtherMetadataStays() async throws {
        let preset = try BackendHarness.builtIn("image.png")
        XCTAssertNil(preset.removeLocationData, "nil means remove")
        let output = try await convert("gps.jpg", preset)
        XCTAssertFalse(try ImageAssertions.info(output).hasGPS)
    }

    func testLocationIsKeptWhenAsked() async throws {
        var preset = try BackendHarness.builtIn("image.png")
        preset.removeLocationData = false
        let output = try await convert("gps.jpg", preset)
        XCTAssertTrue(try ImageAssertions.info(output).hasGPS)
    }

    func testMetadataOffReallyStripsMetadata() async throws {
        var preset = try BackendHarness.builtIn("image.jpeg")
        preset.preserveMetadata = false
        preset.removeLocationData = false
        let output = try await convert("gps.jpg", preset)
        XCTAssertFalse(try ImageAssertions.info(output).hasGPS, "metadata off must not copy EXIF/GPS")
    }

    func testResizedOutputDropsLocationToo() async throws {
        let output = try await convert("gps.jpg", try BackendHarness.builtIn("image.jpeg-web"))
        XCTAssertFalse(try ImageAssertions.info(output).hasGPS)
    }
}

final class VideoLocationTests: XCTestCase {
    private func hasLocation(_ url: URL) throws -> Bool {
        let tags = try MediaAssertions.probe(url).formatTags
        return tags.keys.contains { $0.lowercased().contains("location") }
    }

    func testFixtureHasLocation() throws {
        XCTAssertTrue(try hasLocation(try TestFixtures.url("gps_video.mov")))
    }

    func testNativeAndFFmpegOutputsDropLocationByDefault() async throws {
        let directory = try BackendHarness.makeTempDirectory("VideoLocation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try TestFixtures.copy("gps_video.mov", to: directory)
        var preset = try BackendHarness.builtIn("video.mp4-balanced")

        preset.backend = .avFoundation
        let native = try await BackendHarness.convert(backend: AVFoundationBackend(), source: source, preset: preset, into: directory, baseName: "native")
        XCTAssertFalse(try hasLocation(try XCTUnwrap(native.outputs.first)))

        guard TestFixtures.ffmpegPath != nil else { return }
        preset.backend = .ffmpeg
        let ffmpeg = try await BackendHarness.convert(backend: FFmpegBackend(), source: source, preset: preset, into: directory, baseName: "ffmpeg")
        XCTAssertFalse(try hasLocation(try XCTUnwrap(ffmpeg.outputs.first)))

        preset.removeLocationData = false
        let kept = try await BackendHarness.convert(backend: FFmpegBackend(), source: source, preset: preset, into: directory, baseName: "kept")
        XCTAssertTrue(try hasLocation(try XCTUnwrap(kept.outputs.first)))
    }
}
