import XCTest
@testable import FileConverterCore
import FileConverterExternalBackends

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
}
