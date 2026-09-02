import XCTest
import PDFKit
@testable import FileConverterCore
import FileConverterNativeBackends

final class PDFKitBackendTextRenderingTests: XCTestCase {
    func testPlainTextToPDFPreservesText() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("plain-text.txt")
        let destinationURL = temporaryDirectory.appendingPathComponent("plain-text.pdf")
        let marker = "Plain text PDF rendering marker"
        try marker.write(to: sourceURL, atomically: true, encoding: .utf8)

        try await convertToPDF(sourceURL: sourceURL, destinationURL: destinationURL)

        let document = try XCTUnwrap(PDFDocument(url: destinationURL))
        XCTAssertGreaterThan(document.pageCount, 0)
        XCTAssertTrue(document.string?.contains(marker) == true)
    }

    func testRTFToPDFPreservesText() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("rich-text.rtf")
        let destinationURL = temporaryDirectory.appendingPathComponent("rich-text.pdf")
        let marker = "Rich text PDF rendering marker"
        let rtf = "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs28 \(marker)\\par}"
        try Data(rtf.utf8).write(to: sourceURL, options: .atomic)

        try await convertToPDF(sourceURL: sourceURL, destinationURL: destinationURL)

        let document = try XCTUnwrap(PDFDocument(url: destinationURL))
        XCTAssertGreaterThan(document.pageCount, 0)
        XCTAssertTrue(document.string?.contains(marker) == true)
    }

    private func convertToPDF(sourceURL: URL, destinationURL: URL) async throws {
        let preset = ConversionPreset(
            name: "PDF Document",
            category: .document,
            sourceFormats: ["document"],
            destinationFormat: "pdf",
            backend: .pdfKit
        )
        let job = ConversionJob(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            preset: preset
        )

        try await PDFKitBackend().convert(job: job) { _ in }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFKitBackendTextRenderingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
