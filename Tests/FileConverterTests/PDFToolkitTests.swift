import PDFKit
import XCTest
@testable import FileConverterCore
@testable import FileConverterNativeBackends

final class PDFToolkitTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try BackendHarness.makeTempDirectory("PDFToolkit")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCombinesPDFPagesAndImagesInOrder() throws {
        let pdf = try TestFixtures.makeTextLinksOutlinePDF(in: directory)
        let pdfPages = try XCTUnwrap(PDFDocument(url: pdf)).pageCount
        let image = try TestFixtures.copy("transparent_256.png", to: directory)
        XCTAssertTrue(PDFCombiner.canCombine([pdf, image]))
        XCTAssertFalse(PDFCombiner.canCombine([pdf]), "one file is nothing to combine")

        let output = directory.appendingPathComponent("Combined.pdf")
        let pages = try PDFCombiner.combine([image, pdf], into: output)
        XCTAssertEqual(pages, pdfPages + 1)
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, pdfPages + 1)

        // Replacing an existing file works and leaves no temporary files behind.
        try PDFCombiner.combine([pdf, pdf], into: output)
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, pdfPages * 2)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [])
    }

    func testRotatePresetTurnsEveryPage() async throws {
        let pdf = try TestFixtures.makeTextLinksOutlinePDF(in: directory)
        let preset = try BackendHarness.builtIn("document.pdf-rotate-right")
        let output = directory.appendingPathComponent("rotated.pdf")
        var job = ConversionJob(sourceURL: pdf, preset: preset)
        job.destinationURL = output
        job.temporaryOutputURL = output
        _ = try await PDFKitBackend().convert(
            job: job,
            outputs: [PlannedConversionOutput(finalURL: output, temporaryURL: output)],
            progressHandler: { _ in }
        )
        let rotated = try XCTUnwrap(PDFDocument(url: output))
        let original = try XCTUnwrap(PDFDocument(url: pdf))
        for index in 0..<rotated.pageCount {
            XCTAssertEqual(rotated.page(at: index)?.rotation, ((original.page(at: index)?.rotation ?? 0) + 90) % 360)
        }
        XCTAssertEqual(PresetValidator.validationErrors(for: preset), [])
    }
}
