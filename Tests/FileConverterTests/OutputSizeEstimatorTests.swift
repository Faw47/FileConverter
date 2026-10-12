import XCTest
@testable import FileConverterCore

final class OutputSizeEstimatorTests: XCTestCase {
    private func format(_ id: String) throws -> FormatDefinition {
        try XCTUnwrap(FormatRegistry.shared.format(forID: id))
    }

    func testPCMEstimateIsExact() throws {
        var preset = try BackendHarness.builtIn("audio.wav-pcm")
        preset.audioSampleRate = 48_000
        preset.audioChannels = 2
        preset.audioBitDepth = .bit16
        let bytes = OutputSizeEstimator.estimate(
            preset: preset,
            destination: try format("wav"),
            source: .init(fileSize: 500_000, duration: 10),
            outputCount: 1
        )
        XCTAssertEqual(Double(bytes), 1_920_000, accuracy: 1_920_000 * 0.01)
    }

    func testLargeVideoNoLongerNeedsFourTimesItsSize() throws {
        let preset = try BackendHarness.builtIn("video.mp4-balanced")
        let oneGigabyte: Int64 = 1_000_000_000
        let bytes = OutputSizeEstimator.estimate(
            preset: preset,
            destination: try format("mp4"),
            source: .init(fileSize: oneGigabyte, duration: 600),
            outputCount: 1
        )
        XCTAssertLessThan(bytes, oneGigabyte * 2, "was 4 GB before")
        XCTAssertGreaterThan(bytes, 0)
    }

    func testLossyAudioUsesBitrate() throws {
        let preset = try BackendHarness.builtIn("audio.mp3-128")
        let bytes = OutputSizeEstimator.estimate(
            preset: preset,
            destination: try format("mp3"),
            source: .init(fileSize: 50_000_000, duration: 60),
            outputCount: 1
        )
        XCTAssertEqual(Double(bytes), 60 * 128_000 / 8, accuracy: 60 * 128_000 / 8 * 0.1)
    }

    func testMeasuresMediaDurationAndImageSize() async throws {
        let video = try TestFixtures.url("small_640x360_h264.mp4")
        let videoMeasure = await OutputSizeEstimator.measure(video, category: .video, formatID: "mp4")
        XCTAssertEqual(try XCTUnwrap(videoMeasure.duration), 2, accuracy: 0.2)

        let image = try TestFixtures.url("transparent_256.png")
        let imageMeasure = await OutputSizeEstimator.measure(image, category: .image, formatID: "png")
        XCTAssertEqual(imageMeasure.pixelWidth, 256)
    }
}
