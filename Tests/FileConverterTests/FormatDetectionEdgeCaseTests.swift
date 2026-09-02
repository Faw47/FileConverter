import XCTest
import UniformTypeIdentifiers
@testable import FileConverterCore

final class FormatDetectionEdgeCaseTests: XCTestCase {
    var tempDirectory: URL!

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
}
