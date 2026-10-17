import XCTest
import PDFKit
import AppKit
@testable import FileConverterCore
@testable import FileConverterNativeBackends

/// "Extract selected pages" and "Protect with a password". Everything is
/// written to a temporary folder, never to Application Support.
final class PDFExtractAndProtectTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = try BackendHarness.makeTempDirectory("pdf-extract-protect")
    }

    override func tearDownWithError() throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        try super.tearDownWithError()
    }

    // MARK: - Extract

    func testPlanExtractMakesOneSortedFileWithoutDuplicates() {
        let plans = PDFPageRangeParser.planOutputs(
            totalPages: 8, splitMode: "extract", pageRanges: nil,
            selectedPages: [6, 2, 4, 2], mergeOutputs: false
        )
        XCTAssertEqual(plans, [PDFSplitOutputPlan(suffix: "extracted", pageIndices: [1, 3, 5])])
    }

    func testPlanExtractRejectsEmptyAndOutOfRangeSelections() {
        XCTAssertTrue(PDFPageRangeParser.planOutputs(totalPages: 5, splitMode: "extract", pageRanges: nil, selectedPages: [], mergeOutputs: false).isEmpty)
        XCTAssertTrue(PDFPageRangeParser.planOutputs(totalPages: 5, splitMode: "extract", pageRanges: nil, selectedPages: [2, 6], mergeOutputs: false).isEmpty)
        XCTAssertTrue(PDFPageRangeParser.planOutputs(totalPages: 5, splitMode: "extract", pageRanges: nil, selectedPages: nil, mergeOutputs: false).isEmpty)
    }

    func testBackendExtractsSelectedPagesIntoOnePDF() async throws {
        let source = try makePDF(named: "report.pdf", pages: 6)
        var preset = try BackendHarness.builtIn("document.pdf-split-pages")
        var options = ConversionProcessingOptions()
        options.pdfSplitMode = "extract"
        options.pdfSelectedPages = [5, 2, 3]
        preset.processingOptions = options

        let (outputs, _) = try await BackendHarness.convert(
            backend: PDFKitBackend(), source: source, preset: preset,
            into: tempDirectory.appendingPathComponent("out"), baseName: "report"
        )

        XCTAssertEqual(outputs.map(\.lastPathComponent), ["report-extracted.pdf"])
        let extracted = try XCTUnwrap(PDFDocument(url: outputs[0]))
        XCTAssertEqual(extracted.pageCount, 3)
        XCTAssertEqual((0..<3).compactMap { extracted.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) },
                       ["Page 2", "Page 3", "Page 5"])
    }

    func testBackendRefusesExtractWithPagesOutsideTheDocument() async throws {
        let source = try makePDF(named: "short.pdf", pages: 2)
        var preset = try BackendHarness.builtIn("document.pdf-split-pages")
        var options = ConversionProcessingOptions()
        options.pdfSplitMode = "extract"
        options.pdfSelectedPages = [1, 3]
        preset.processingOptions = options

        do {
            _ = try await PDFKitBackend().outputRequirements(for: ConversionJob(sourceURL: source, preset: preset))
            XCTFail("Page 3 of a two-page PDF must not be planned")
        } catch let error as ConversionError {
            guard case .malformedSource = error else { return XCTFail("Unexpected error \(error)") }
        }
    }

    // MARK: - Password

    func testProtectRequiresThePasswordToOpen() throws {
        let url = try makePDF(named: "secret.pdf", pages: 2)
        try PDFPasswordProtection.protect(fileAt: url, password: "correct horse")

        let locked = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(locked.isEncrypted)
        XCTAssertTrue(locked.isLocked)
        XCTAssertFalse(locked.unlock(withPassword: "wrong"))
        XCTAssertTrue(locked.unlock(withPassword: "correct horse"))
        XCTAssertEqual(locked.pageCount, 2)
        XCTAssertEqual(locked.page(at: 1)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), "Page 2")

        // Nothing is left beside the file.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        XCTAssertEqual(leftovers, ["secret.pdf"])
    }

    func testProtectRefusesAnEmptyPassword() throws {
        let url = try makePDF(named: "open.pdf", pages: 1)
        XCTAssertThrowsError(try PDFPasswordProtection.protect(fileAt: url, password: ""))
        XCTAssertFalse(try XCTUnwrap(PDFDocument(url: url)).isEncrypted)
    }

    func testVaultKeepsPasswordsOutOfEncodedOptions() throws {
        let vault = PDFPasswordVault()
        let token = vault.store("hunter2-secret")
        XCTAssertEqual(vault.password(for: token), "hunter2-secret")

        var options = ConversionProcessingOptions()
        options.pdfPasswordToken = token
        let encoded = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
        XCTAssertFalse(encoded.contains("hunter2"))
        XCTAssertEqual(try JSONDecoder().decode(ConversionProcessingOptions.self, from: Data(encoded.utf8)).pdfPasswordToken, token)

        vault.remove(token)
        XCTAssertNil(vault.password(for: token))
    }

    func testProtectingWithAForgottenTokenFailsInsteadOfSavingAnOpenPDF() throws {
        let url = try makePDF(named: "later.pdf", pages: 1)
        XCTAssertThrowsError(try PDFPasswordProtection.protect(filesAt: [url], token: "gone", vault: PDFPasswordVault()))
        XCTAssertFalse(try XCTUnwrap(PDFDocument(url: url)).isEncrypted)
    }

    @MainActor
    func testQueueProtectsCompressedPDFEvenWhenItIsNotSmaller() async throws {
        BackendResolver.shared.configure(backends: NativeBackendCatalog.makeBackends())
        let source = try makePDF(named: "contract.pdf", pages: 2)
        var preset = try BackendHarness.builtIn("document.pdf-compressed")
        preset.inheritance = .inheritNone
        preset.filenamePattern = "{name}-protected"
        var options = preset.processingOptions ?? ConversionProcessingOptions()
        options.pdfCompressionProfile = "printer"
        options.pdfPasswordToken = PDFPasswordVault.shared.store("open sesame")
        preset.processingOptions = options

        let queue = ConversionQueue()
        queue.addJobs([ConversionJob(sourceURL: source, preset: preset)])
        for _ in 0..<250 where !queue.jobs.allSatisfy({ $0.state.isTerminal }) {
            try await Task.sleep(for: .milliseconds(20))
        }

        let job = try XCTUnwrap(queue.jobs.first)
        XCTAssertTrue(job.state.isTerminal)
        let output = tempDirectory.appendingPathComponent("contract-protected.pdf")
        let document = try XCTUnwrap(PDFDocument(url: output), "state: \(job.state)")
        XCTAssertTrue(document.isLocked)
        XCTAssertTrue(document.unlock(withPassword: "open sesame"))
        XCTAssertEqual(document.pageCount, 2)
        // The source is untouched.
        XCTAssertFalse(try XCTUnwrap(PDFDocument(url: source)).isEncrypted)
    }

    // MARK: - Helpers

    /// A PDF whose page N contains the text "Page N".
    private func makePDF(named name: String, pages: Int) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        for number in 1...pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: "Page \(number)",
                attributes: [.font: NSFont.systemFont(ofSize: 24)]
            ))
            context.textPosition = CGPoint(x: 40, y: 200)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}
