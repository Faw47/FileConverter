import XCTest
@testable import FileConverterCore
import FileConverterNativeBackends

final class FinderMenuTests: XCTestCase {
    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("FinderMenuTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testSingleMP4Selection() throws {
        let mp4File = tempDirectory.appendingPathComponent("video.mp4")
        try "dummy mp4".write(to: mp4File, atomically: true, encoding: .utf8)

        let compatible = PresetValidator.compatiblePresets(
            forURLs: [mp4File],
            from: BuiltInPresets.makeDefaultPresets(),
            resolver: extendedResolver()
        )
        XCTAssertTrue(compatible.contains { $0.menuName == "MP4" })
        XCTAssertTrue(compatible.contains { $0.menuName == "HEVC" })
        XCTAssertTrue(compatible.contains { $0.menuName == "MP3" })
        XCTAssertTrue(compatible.contains { $0.menuName == "AAC" })
        XCTAssertFalse(compatible.contains { $0.menuName == "PNG" })
    }

    func testSinglePNGSelection() throws {
        let pngFile = tempDirectory.appendingPathComponent("image.png")
        try "dummy png".write(to: pngFile, atomically: true, encoding: .utf8)

        let compatible = PresetValidator.compatiblePresets(
            forURLs: [pngFile],
            from: BuiltInPresets.makeDefaultPresets(),
            resolver: extendedResolver()
        )
        XCTAssertTrue(compatible.contains { $0.menuName == "JPEG" })
        XCTAssertTrue(compatible.contains { $0.menuName == "PNG" })
        XCTAssertTrue(compatible.contains { $0.menuName == "HEIC" })
        XCTAssertTrue(compatible.contains { $0.menuName == "PDF" })
        XCTAssertFalse(compatible.contains { $0.menuName == "MP4" && $0.category == .video })
    }

    func testUserPresetsBackwardCompatibility() throws {
        let presets = PresetStore.shared.presets
        XCTAssertFalse(presets.isEmpty)

        let enabledPresets = PresetStore.shared.enabledPresets
        XCTAssertFalse(enabledPresets.isEmpty)

        let heicFile = URL(fileURLWithPath: "/tmp/IMG_8727.HEIC")
        if FileManager.default.fileExists(atPath: heicFile.path) {
            let compatible = PresetValidator.compatiblePresets(
                forURLs: [heicFile],
                from: enabledPresets,
                resolver: extendedResolver()
            )
            XCTAssertTrue(compatible.contains { $0.menuName == "JPEG" })
            XCTAssertTrue(compatible.contains { $0.menuName == "PNG" })
            XCTAssertFalse(compatible.contains { $0.menuName == "HEIC → JPEG" })
            XCTAssertFalse(compatible.contains { $0.menuName == "HEIC → PNG" })
        }
    }

    func testRealHEICToPNGAndJPEGConversion() async throws {
        let heicFile = URL(fileURLWithPath: "/tmp/IMG_8727.HEIC")
        guard FileManager.default.fileExists(atPath: heicFile.path) else { return }

        let backend = ImageIOBackend()
        let presets = PresetStore.shared.enabledPresets

        // 1. Convert to PNG
        if let pngPreset = presets.first(where: { $0.destinationFormat == "png" && ($0.sourceFormats.contains("heic") || $0.category == .image) }) {
            let destPNG = tempDirectory.appendingPathComponent("IMG_8727.png")
            let job = ConversionJob(
                sourceURL: heicFile,
                destinationURL: destPNG,
                preset: pngPreset
            )
            try await backend.convert(job: job) { _ in }
            XCTAssertTrue(FileManager.default.fileExists(atPath: destPNG.path))
            let pngSize = (try? destPNG.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            XCTAssertGreaterThan(pngSize, 1000)
        } else {
            XCTFail("Could not find a compatible PNG preset for HEIC")
        }

        // 2. Convert to JPEG
        if let jpegPreset = presets.first(where: { ($0.destinationFormat == "jpeg" || $0.destinationFormat == "jpg") && ($0.sourceFormats.contains("heic") || $0.category == .image) }) {
            let destJPEG = tempDirectory.appendingPathComponent("IMG_8727.jpg")
            let job = ConversionJob(
                sourceURL: heicFile,
                destinationURL: destJPEG,
                preset: jpegPreset
            )
            try await backend.convert(job: job) { _ in }
            XCTAssertTrue(FileManager.default.fileExists(atPath: destJPEG.path))
            let jpegSize = (try? destJPEG.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            XCTAssertGreaterThan(jpegSize, 1000)
        } else {
            XCTFail("Could not find a compatible JPEG preset for HEIC")
        }
    }

    func testMixedPNGAndJPEGSelection() throws {
        let pngFile = tempDirectory.appendingPathComponent("photo1.png")
        let jpgFile = tempDirectory.appendingPathComponent("photo2.jpg")
        try "1".write(to: pngFile, atomically: true, encoding: .utf8)
        try "2".write(to: jpgFile, atomically: true, encoding: .utf8)

        let compatible = PresetValidator.compatiblePresets(
            forURLs: [pngFile, jpgFile],
            from: BuiltInPresets.makeDefaultPresets(),
            resolver: extendedResolver()
        )
        XCTAssertTrue(compatible.contains { $0.menuName == "JPEG" })
        XCTAssertTrue(compatible.contains { $0.menuName == "PNG" })
        XCTAssertTrue(compatible.contains { $0.menuName == "HEIC" })
        XCTAssertTrue(compatible.contains { $0.menuName == "PDF" })
        XCTAssertFalse(compatible.contains { $0.menuName == "MP4" })
    }

    func testMultipleMKVSelection() throws {
        let mkv1 = tempDirectory.appendingPathComponent("episode1.mkv")
        let mkv2 = tempDirectory.appendingPathComponent("episode2.mkv")
        try "1".write(to: mkv1, atomically: true, encoding: .utf8)
        try "2".write(to: mkv2, atomically: true, encoding: .utf8)

        let compatible = PresetValidator.compatiblePresets(
            forURLs: [mkv1, mkv2],
            from: BuiltInPresets.makeDefaultPresets(),
            resolver: extendedResolver()
        )
        XCTAssertTrue(compatible.contains { $0.menuName == "MP4" })
        XCTAssertTrue(compatible.contains { $0.menuName == "HEVC" })
        XCTAssertTrue(compatible.contains { $0.menuName == "MOV" })
        XCTAssertFalse(compatible.contains { $0.menuName == "JPEG" })
    }

    private func extendedResolver() -> BackendResolver {
        BackendResolver(
            backends: NativeBackendCatalog.makeBackends() + [AvailableMediaBackendStub()]
        )
    }
}
