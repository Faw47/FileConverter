import XCTest
import UniformTypeIdentifiers
@testable import FileConverterCore

final class FormatDetectionEdgeCaseTests: XCTestCase {
    var tempDirectory: URL!

    private func ftyp(majorBrand: String, compatibleBrands: [String] = []) -> Data {
        let brands = [majorBrand] + compatibleBrands
        let size = 16 + (compatibleBrands.count * 4)
        var bytes = [UInt8](repeating: 0, count: size)
        bytes[0] = UInt8((size >> 24) & 0xFF)
        bytes[1] = UInt8((size >> 16) & 0xFF)
        bytes[2] = UInt8((size >> 8) & 0xFF)
        bytes[3] = UInt8(size & 0xFF)
        bytes.replaceSubrange(4..<8, with: Array("ftyp".utf8))
        bytes.replaceSubrange(8..<12, with: Array(brands[0].utf8))
        for (index, brand) in brands.dropFirst().enumerated() {
            let start = 16 + (index * 4)
            bytes.replaceSubrange(start..<(start + 4), with: Array(brand.utf8))
        }
        return Data(bytes)
    }

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("DetectionEdgeCaseTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testDirectoryDetection() {
        let subDir = tempDirectory.appendingPathComponent("NestedFolder", isDirectory: true)
        try? FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let result = FormatDetector.detect(url: subDir)
        XCTAssertTrue(result.isDirectory)
        XCTAssertNil(result.format)
    }

    func testZeroByteFileDetection() throws {
        let emptyFile = tempDirectory.appendingPathComponent("empty_file.mp4")
        try Data().write(to: emptyFile)

        let result = FormatDetector.detect(url: emptyFile)
        XCTAssertTrue(result.isZeroByte)
        XCTAssertFalse(result.isDirectory)
        XCTAssertEqual(result.format?.id, "mp4")
    }

    func testPNGMagicByteSniffing() throws {
        let pngFile = tempDirectory.appendingPathComponent("mystery_file")
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try pngHeader.write(to: pngFile)

        let result = FormatDetector.detect(url: pngFile)
        XCTAssertEqual(result.format?.id, "png")
        XCTAssertEqual(result.confidence, .exactMagicBytes)
    }

    func testJPEGMagicByteSniffing() throws {
        let jpgFile = tempDirectory.appendingPathComponent("unnamed_asset")
        let jpgHeader = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])
        try jpgHeader.write(to: jpgFile)

        let result = FormatDetector.detect(url: jpgFile)
        XCTAssertEqual(result.format?.id, "jpeg")
        XCTAssertEqual(result.confidence, .exactMagicBytes)
    }

    func testPDFMagicByteSniffing() throws {
        let pdfFile = tempDirectory.appendingPathComponent("document_without_ext")
        let pdfHeader = "%PDF-1.7\n%Test".data(using: .utf8)!
        try pdfHeader.write(to: pdfFile)

        let result = FormatDetector.detect(url: pdfFile)
        XCTAssertEqual(result.format?.id, "pdf")
        XCTAssertEqual(result.confidence, .exactMagicBytes)
    }

    func testMagicBytesWinOverMisleadingExtension() throws {
        let disguisedPNG = tempDirectory.appendingPathComponent("misleading.mp4")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: disguisedPNG)

        let result = FormatDetector.detect(url: disguisedPNG)

        XCTAssertEqual(result.format?.id, "png")
        XCTAssertEqual(result.confidence, .exactMagicBytes)
    }

    func testQuickTimeAudioExtensionDisambiguatesQuickTimeContainer() throws {
        let qtaFile = tempDirectory.appendingPathComponent("voice-note.qta")
        // QuickTime audio and movie files both use an ftyp/qt container header.
        try Data([0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20]).write(to: qtaFile)

        let result = FormatDetector.detect(url: qtaFile)

        XCTAssertEqual(result.format?.id, "qta")
        XCTAssertEqual(result.format?.category, .audio)
    }

    func testHEICBrandSniffing() throws {
        for brand in ["heic", "heix", "hevc", "hevx", "heim", "heis", "miaf", "MiHB"] {
            let file = tempDirectory.appendingPathComponent("test_\(brand).bin")
            var data = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70])
            data.append(brand.data(using: .utf8)!)
            data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
            data.append("mif1".data(using: .utf8)!)
            data.append("heic".data(using: .utf8)!)
            try data.write(to: file)

            let result = FormatDetector.detect(url: file)
            XCTAssertEqual(result.format?.id, "heic", "Failed for brand \(brand)")
            XCTAssertEqual(result.format?.category, .image)
        }
    }

    func testHEICCompatibleBrandsDetection() throws {
        let file = tempDirectory.appendingPathComponent("generic_heic.bin")
        var data = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70])
        data.append("mif1".data(using: .utf8)!)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        data.append("mif1".data(using: .utf8)!)
        data.append("heix".data(using: .utf8)!)
        try data.write(to: file)

        let result = FormatDetector.detect(url: file)
        XCTAssertEqual(result.format?.id, "heic")
        XCTAssertEqual(result.format?.category, .image)
    }

    func testHEICExtensionNeverDefaultsToMP4() throws {
        let file = tempDirectory.appendingPathComponent("photo.heic")
        var data = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70])
        data.append("isom".data(using: .utf8)!)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        data.append("mp42".data(using: .utf8)!)
        data.append("isom".data(using: .utf8)!)
        try data.write(to: file)

        let result = FormatDetector.detect(url: file)
        XCTAssertEqual(result.format?.id, "heic")
        XCTAssertNotEqual(result.format?.id, "mp4")
    }

    func testGenericMif1AndMsf1BrandsStayUnknown() throws {
        for brand in ["mif1", "msf1"] {
            let file = tempDirectory.appendingPathComponent("generic_(brand).bin")
            try ftyp(majorBrand: brand).write(to: file)

            XCTAssertNil(FormatDetector.detect(url: file).format, "Unexpected guess for (brand)")
        }
    }

    func testAvifExtensionDoesNotTurnIsomOnlyFtypIntoMP4() throws {
        let file = tempDirectory.appendingPathComponent("photo.avif")
        try ftyp(majorBrand: "isom").write(to: file)

        XCTAssertNotEqual(FormatDetector.detect(url: file).format?.id, "mp4")
    }

    func testRandomMP3FrameSyncIsRejected() throws {
        let file = tempDirectory.appendingPathComponent("random-frame")
        try Data([0xFF, 0xE1, 0x90, 0x00]).write(to: file)

        XCTAssertNil(FormatDetector.detect(url: file).format)
    }

    func testOggNonAudioCodecStaysUnknown() throws {
        var theora = Data([0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00, 0x00])
        theora.append("theora".data(using: .utf8)!)
        let theoraURL = tempDirectory.appendingPathComponent("video.ogg.bin")
        try theora.write(to: theoraURL)

        var unknown = Data([0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00, 0x00])
        unknown.append("custom-codec".data(using: .utf8)!)
        let unknownURL = tempDirectory.appendingPathComponent("unknown.ogg.bin")
        try unknown.write(to: unknownURL)

        XCTAssertNil(FormatDetector.detect(url: theoraURL).format)
        XCTAssertNil(FormatDetector.detect(url: unknownURL).format)
    }

    func testTruncatedFtypStaysUnknown() throws {
        let truncated = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])
        let file = tempDirectory.appendingPathComponent("truncated-ftyp.bin")
        try truncated.write(to: file)

        XCTAssertNil(FormatDetector.detect(url: file).format)
    }
}
