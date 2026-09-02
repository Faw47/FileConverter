import XCTest
@testable import FileConverterCore
import FileConverterExternalBackends
import FileConverterNativeBackends

final class QTAFormatTests: XCTestCase {
    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("QTATests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testQTADetectionByExtension() {
        let qtaURL = URL(fileURLWithPath: "/tmp/VoiceMemoRecording.qta")
        let result = FormatDetector.detect(url: qtaURL)

        XCTAssertNotNil(result.format)
        XCTAssertEqual(result.format?.id, "qta")
        XCTAssertEqual(result.format?.category, .audio)
    }

    func testQTACompatiblePresets() {
        let qtaURL = URL(fileURLWithPath: "/Users/test/Desktop/meeting_audio.qta")
        let presets = PresetValidator.compatiblePresets(
            forURLs: [qtaURL],
            from: BuiltInPresets.makeDefaultPresets(),
            resolver: BackendResolver(
                backends: NativeBackendCatalog.makeBackends() + ExternalBackendCatalog.makeBackends()
            )
        )

        XCTAssertFalse(presets.isEmpty, "QTA files must have compatible audio conversion presets")

        let menuNames = Set(presets.map { $0.menuName })
        XCTAssertTrue(menuNames.contains("MP3"), "QTA should be convertible to MP3")
        XCTAssertTrue(menuNames.contains("AAC"), "QTA should be convertible to AAC")
        XCTAssertTrue(menuNames.contains("FLAC"), "QTA should be convertible to FLAC")
        XCTAssertTrue(menuNames.contains("WAV"), "QTA should be convertible to WAV")
        XCTAssertTrue(menuNames.contains("ALAC"), "QTA should be convertible to ALAC")
        XCTAssertTrue(menuNames.contains("QTA"), "QTA output preset should be present")

        // Should NOT include image presets
        XCTAssertFalse(menuNames.contains("JPEG"))
        XCTAssertFalse(menuNames.contains("PNG"))
    }

    func testQTABackendSupport() {
        let backend = AVFoundationBackend()
        let qtaFormat = FormatRegistry.shared.format(forID: "qta")!
        let m4aFormat = FormatRegistry.shared.format(forID: "m4a")!
        let wavFormat = FormatRegistry.shared.format(forID: "wav")!

        let m4aPreset = BuiltInPresets.makeDefaultPresets().first { $0.menuName == "M4A" }!
        let wavPreset = BuiltInPresets.makeDefaultPresets().first { $0.menuName == "WAV" }!
        let qtaPreset = BuiltInPresets.makeDefaultPresets().first { $0.menuName == "QTA" }!

        XCTAssertTrue(backend.supports(sourceFormat: qtaFormat, destinationFormat: m4aFormat, preset: m4aPreset))
        XCTAssertTrue(backend.supports(sourceFormat: qtaFormat, destinationFormat: wavFormat, preset: wavPreset))
        XCTAssertTrue(backend.supports(sourceFormat: qtaFormat, destinationFormat: qtaFormat, preset: qtaPreset))
    }

    func testQTAToMP3BackendResolution() throws {
        let qtaURL = tempDirectory.appendingPathComponent("recording.qta")
        try "dummy audio content".data(using: .utf8)?.write(to: qtaURL)

        let mp3Preset = BuiltInPresets.makeDefaultPresets().first { $0.menuName == "MP3" }!
        let job = ConversionJob(sourceURL: qtaURL, preset: mp3Preset)

        let resolver = BackendResolver(
            backends: NativeBackendCatalog.makeBackends() + ExternalBackendCatalog.makeBackends()
        )
        let backend = try resolver.resolveBackend(for: job)
        XCTAssertEqual(backend.backendType, .ffmpeg, "QTA to MP3 should resolve to FFmpeg backend")
    }

    func testFFmpegQTAArguments() {
        let ffmpeg = FFmpegBackend()
        let qtaURL = URL(fileURLWithPath: "/path/to/voice.qta")
        let destURL = URL(fileURLWithPath: "/path/to/voice.mp3")
        let mp3Preset = BuiltInPresets.makeDefaultPresets().first { $0.menuName == "MP3" }!

        let args = ffmpeg.buildFFmpegArguments(sourceURL: qtaURL, destURL: destURL, preset: mp3Preset)
        XCTAssertTrue(args.contains("-f"), "Must include -f flag for QTA container input")
        XCTAssertTrue(args.contains("mov"), "Must force mov container demuxer for QTA")
        XCTAssertTrue(args.contains("libmp3lame"), "Must use libmp3lame for MP3 encoding")
    }

    func testPresetStoreContainsQTA() {
        let storageURL = tempDirectory.appendingPathComponent("presets.json")
        let store = PresetStore(storageURL: storageURL, postsDarwinNotifications: false)

        let presets = store.presets
        XCTAssertTrue(presets.contains { $0.destinationFormat == "qta" || $0.menuName == "QTA" })
    }
}
