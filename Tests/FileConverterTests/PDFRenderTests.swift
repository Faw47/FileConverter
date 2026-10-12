import PDFKit
import XCTest
@testable import FileConverterCore
@testable import FileConverterNativeBackends

final class PDFRenderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try BackendHarness.makeTempDirectory("PDFRender")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPDFToPNGUsesCropBoxAt300DPI() async throws {
        let source = try TestFixtures.makeTextLinksOutlinePDF(in: directory)
        let preset = try BackendHarness.builtIn("image.pdf-to-png")
        let (outputs, _) = try await BackendHarness.convert(backend: PDFKitBackend(), source: source, preset: preset, into: directory)
        let info = try ImageAssertions.info(try XCTUnwrap(outputs.first))
        // Crop box 540×720 pt at 300 dpi.
        XCTAssertEqual(info.width, 2250)
        XCTAssertEqual(info.height, 3000)
    }

    func testDPISettingIsHonored() async throws {
        let source = try TestFixtures.makeTextLinksOutlinePDF(in: directory)
        var preset = try BackendHarness.builtIn("image.pdf-to-jpg")
        XCTAssertEqual(PDFKitBackend.renderDPI(for: preset), 200)
        var options = preset.processingOptions ?? ConversionProcessingOptions()
        options.pdfDPI = 72
        preset.processingOptions = options
        let (outputs, _) = try await BackendHarness.convert(backend: PDFKitBackend(), source: source, preset: preset, into: directory)
        XCTAssertEqual(try ImageAssertions.info(try XCTUnwrap(outputs.first)).width, 540)
    }

    private func compressPreset(flatten: Bool) throws -> ConversionPreset {
        var preset = try BackendHarness.builtIn("document.pdf-compressed")
        preset.backend = .pdfKit
        var options = preset.processingOptions ?? ConversionProcessingOptions()
        options.pdfCompressionProfile = "ebook"
        options.pdfFlattenToImages = flatten
        preset.processingOptions = options
        return preset
    }

    func testNativeCompressionKeepsTextLinksAndOutline() async throws {
        let source = try TestFixtures.makeTextLinksOutlinePDF(in: directory)
        let (outputs, result) = try await BackendHarness.convert(
            backend: PDFKitBackend(), source: source, preset: try compressPreset(flatten: false), into: directory
        )
        let output = try XCTUnwrap(outputs.first)
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertTrue(document.string?.contains("Page 1 searchable text") == true)
        XCTAssertEqual(document.outlineRoot?.numberOfChildren, 1)
        XCTAssertEqual(document.page(at: 0)?.annotations.filter { $0.type == "Link" }.count, 1)
        XCTAssertLessThan(FileAccessManager.shared.fileSize(at: output), FileAccessManager.shared.fileSize(at: source))
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
    }

    func testFlattenedCompressionStaysSearchable() async throws {
        let source = try TestFixtures.makeTextLinksOutlinePDF(in: directory)
        let (outputs, _) = try await BackendHarness.convert(
            backend: PDFKitBackend(), source: source, preset: try compressPreset(flatten: true), into: directory
        )
        let document = try XCTUnwrap(PDFDocument(url: try XCTUnwrap(outputs.first)))
        XCTAssertEqual(document.pageCount, 3)
        let text = document.string ?? ""
        XCTAssertTrue(text.localizedCaseInsensitiveContains("searchable"), "OCR text expected, got: \(text.prefix(80))")
    }

    @MainActor
    func testCompressionThatDoesNotShrinkSavesNothing() async throws {
        // An already-compressed PDF cannot shrink further.
        let original = try TestFixtures.makeTextLinksOutlinePDF(in: directory)
        let (once, _) = try await BackendHarness.convert(
            backend: PDFKitBackend(), source: original, preset: try compressPreset(flatten: false),
            into: directory, baseName: "already-small"
        )
        let source = try XCTUnwrap(once.first)
        BackendResolver.shared.configure(backends: NativeBackendCatalog.makeBackends())
        let queue = ConversionQueue()
        queue.addJobs([ConversionJob(sourceURL: source, preset: try compressPreset(flatten: false))])
        for _ in 0..<200 where !(queue.jobs.first?.state.isTerminal ?? false) {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .skipped(let reason) = try XCTUnwrap(queue.jobs.first).state else {
            return XCTFail("expected skipped, got \(String(describing: queue.jobs.first?.state))")
        }
        XCTAssertTrue(reason.contains("not smaller"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("already-small-") }
        XCTAssertEqual(leftovers, [], "nothing should be saved when compression does not help")
    }
}
