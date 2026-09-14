import XCTest
import PDFKit
import AppKit
@testable import FileConverterCore
@testable import FileConverterNativeBackends

final class PDFWorkflowTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-workflow-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Range Parser Tests

    func testParseRangesBasicAndWhitespace() {
        let ranges = PDFPageRangeParser.parseRanges("1-3, 5, 8-10", totalPages: 10)
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges[0], 1...3)
        XCTAssertEqual(ranges[1], 5...5)
        XCTAssertEqual(ranges[2], 8...10)
    }

    func testParseRangesEndToken() {
        let ranges = PDFPageRangeParser.parseRanges("3-end", totalPages: 8)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0], 3...8)
    }

    func testParseRangesOutOfBoundsAndInvalidTokens() {
        let ranges = PDFPageRangeParser.parseRanges("0, -5, abc, 2-4, 15-20, 8", totalPages: 10)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0], 2...4)
        XCTAssertEqual(ranges[1], 8...8)
    }

    // MARK: - Plan Outputs Tests

    func testPlanOutputsModeAll() {
        let plans = PDFPageRangeParser.planOutputs(
            totalPages: 4,
            splitMode: "all",
            pageRanges: nil,
            chunkSize: nil,
            selectedPages: nil,
            mergeOutputs: false,
            zeroPadDigits: 3
        )
        XCTAssertEqual(plans.count, 4)
        XCTAssertEqual(plans.map(\.suffix), ["page-001", "page-002", "page-003", "page-004"])
        XCTAssertEqual(plans[0].pageIndices, [0])
        XCTAssertEqual(plans[3].pageIndices, [3])
    }

    func testPlanOutputsModeRangesSeparate() {
        let plans = PDFPageRangeParser.planOutputs(
            totalPages: 10,
            splitMode: "ranges",
            pageRanges: "1-2, 5, 8-9",
            chunkSize: nil,
            selectedPages: nil,
            mergeOutputs: false,
            zeroPadDigits: 2
        )
        XCTAssertEqual(plans.count, 3)
        XCTAssertEqual(plans[0].suffix, "pages-1-2")
        XCTAssertEqual(plans[0].pageIndices, [0, 1])
        XCTAssertEqual(plans[1].suffix, "page-05")
        XCTAssertEqual(plans[1].pageIndices, [4])
        XCTAssertEqual(plans[2].suffix, "pages-8-9")
        XCTAssertEqual(plans[2].pageIndices, [7, 8])
    }

    func testPlanOutputsModeRangesMerged() {
        let plans = PDFPageRangeParser.planOutputs(
            totalPages: 10,
            splitMode: "ranges",
            pageRanges: "1-3, 5",
            chunkSize: nil,
            selectedPages: nil,
            mergeOutputs: true,
            zeroPadDigits: 3
        )
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].suffix, "extracted")
        XCTAssertEqual(plans[0].pageIndices, [0, 1, 2, 4])
    }

    func testPlanOutputsModeChunks() {
        let plans = PDFPageRangeParser.planOutputs(
            totalPages: 7,
            splitMode: "chunks",
            pageRanges: nil,
            chunkSize: 3,
            selectedPages: nil,
            mergeOutputs: false,
            zeroPadDigits: 2
        )
        XCTAssertEqual(plans.count, 3)
        XCTAssertEqual(plans[0].suffix, "part-01")
        XCTAssertEqual(plans[0].pageIndices, [0, 1, 2])
        XCTAssertEqual(plans[1].suffix, "part-02")
        XCTAssertEqual(plans[1].pageIndices, [3, 4, 5])
        XCTAssertEqual(plans[2].suffix, "part-03")
        XCTAssertEqual(plans[2].pageIndices, [6])
    }

    func testPlanOutputsModeEvenOdd() {
        let plans = PDFPageRangeParser.planOutputs(
            totalPages: 4,
            splitMode: "evenOdd",
            pageRanges: nil,
            chunkSize: nil,
            selectedPages: nil,
            mergeOutputs: false
        )
        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(plans[0].suffix, "odd")
        XCTAssertEqual(plans[0].pageIndices, [0, 2]) // Pages 1 and 3
        XCTAssertEqual(plans[1].suffix, "even")
        XCTAssertEqual(plans[1].pageIndices, [1, 3]) // Pages 2 and 4
    }

    func testPlanOutputsModeSelectedMerged() {
        let plans = PDFPageRangeParser.planOutputs(
            totalPages: 6,
            splitMode: "selected",
            pageRanges: nil,
            chunkSize: nil,
            selectedPages: [2, 4, 6],
            mergeOutputs: true
        )
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].suffix, "selected")
        XCTAssertEqual(plans[0].pageIndices, [1, 3, 5])
    }

    // MARK: - Preset & Processing Options Tests

    func testWorkflowConvenienceProperties() {
        let splitPreset = BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "document.pdf-split-pages" }
        XCTAssertNotNil(splitPreset)
        XCTAssertTrue(splitPreset?.isPDFSplitWorkflow == true)
        XCTAssertFalse(splitPreset?.isPDFCompressWorkflow == true)
        XCTAssertTrue(splitPreset?.isInteractiveWorkflow == true)

        let compressPreset = BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "document.pdf-compressed" }
        XCTAssertNotNil(compressPreset)
        XCTAssertTrue(compressPreset?.isPDFCompressWorkflow == true)
        XCTAssertFalse(compressPreset?.isPDFSplitWorkflow == true)
        XCTAssertTrue(compressPreset?.isInteractiveWorkflow == true)
    }

    // MARK: - Backend Split Execution with Custom Options

    func testPDFKitBackendSplitsCustomRanges() async throws {
        let sourcePDF = tempDirectory.appendingPathComponent("custom-ranges-source.pdf")
        let doc = PDFDocument()
        for i in 0..<5 {
            let img = createTestImage(text: "Page \(i + 1)")
            let page = try XCTUnwrap(PDFPage(image: img))
            doc.insert(page, at: i)
        }
        XCTAssertTrue(doc.write(to: sourcePDF))

        var preset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "document.pdf-split-pages" }
        )
        var options = ConversionProcessingOptions()
        options.pdfSplitMode = "ranges"
        options.pdfPageRanges = "1-2, 4"
        options.pdfMergeSplitOutputs = false
        options.pdfZeroPadDigits = 2
        preset.processingOptions = options

        let backend = PDFKitBackend()
        let job = ConversionJob(sourceURL: sourcePDF, preset: preset)
        let requirements = try await backend.outputRequirements(for: job)

        XCTAssertEqual(requirements.count, 2)
        XCTAssertEqual(requirements[0].suffix, "pages-1-2")
        XCTAssertEqual(requirements[1].suffix, "page-04")

        let outputs = requirements.enumerated().map { idx, req in
            PlannedConversionOutput(
                finalURL: tempDirectory.appendingPathComponent("range-result-\(idx).pdf"),
                temporaryURL: tempDirectory.appendingPathComponent(".range-result-\(idx).pdf")
            )
        }

        _ = try await backend.convert(job: job, outputs: outputs) { _ in }

        let doc1 = try XCTUnwrap(PDFDocument(url: outputs[0].temporaryURL))
        XCTAssertEqual(doc1.pageCount, 2)

        let doc2 = try XCTUnwrap(PDFDocument(url: outputs[1].temporaryURL))
        XCTAssertEqual(doc2.pageCount, 1)
    }

    func testPDFKitBackendCompressPDFMultiPageViaOutputs() async throws {
        let sourcePDF = tempDirectory.appendingPathComponent("multi-page-source.pdf")
        let doc = PDFDocument()
        for i in 0..<3 {
            let img = createTestImage(text: "Page \(i + 1)")
            let page = try XCTUnwrap(PDFPage(image: img))
            doc.insert(page, at: i)
        }
        XCTAssertTrue(doc.write(to: sourcePDF))

        let preset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "document.pdf-compressed" }
        )
        let backend = PDFKitBackend()
        let job = ConversionJob(sourceURL: sourcePDF, preset: preset)
        let requirements = try await backend.outputRequirements(for: job)
        XCTAssertEqual(requirements.count, 1)

        let outputURL = tempDirectory.appendingPathComponent("compressed-result.pdf")
        let tempURL = tempDirectory.appendingPathComponent(".compressed-result.pdf")
        let outputs = [PlannedConversionOutput(finalURL: outputURL, temporaryURL: tempURL)]

        _ = try await backend.convert(job: job, outputs: outputs) { _ in }

        let compressedDoc = try XCTUnwrap(PDFDocument(url: tempURL))
        XCTAssertEqual(compressedDoc.pageCount, 3)
    }

    func testPDFKitBackendCompressRotatedPageAndGrayscale() async throws {
        let sourcePDF = tempDirectory.appendingPathComponent("rotated-source.pdf")
        let doc = PDFDocument()
        let img = createTestImage(text: "Rotated Page")
        let page = try XCTUnwrap(PDFPage(image: img))
        page.rotation = 90
        doc.insert(page, at: 0)
        XCTAssertTrue(doc.write(to: sourcePDF))

        var preset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "document.pdf-compressed" }
        )
        var options = ConversionProcessingOptions()
        options.pdfColorMode = "grayscale"
        options.pdfDPI = 150
        options.pdfImageQuality = 0.7
        preset.processingOptions = options

        let backend = PDFKitBackend()
        let job = ConversionJob(sourceURL: sourcePDF, preset: preset)
        let requirements = try await backend.outputRequirements(for: job)
        XCTAssertEqual(requirements.count, 1)

        let tempURL = tempDirectory.appendingPathComponent(".rotated-compressed.pdf")
        let outputs = [PlannedConversionOutput(finalURL: tempURL, temporaryURL: tempURL)]

        _ = try await backend.convert(job: job, outputs: outputs) { _ in }

        let compressedDoc = try XCTUnwrap(PDFDocument(url: tempURL))
        XCTAssertEqual(compressedDoc.pageCount, 1)
        let outPage = try XCTUnwrap(compressedDoc.page(at: 0))
        XCTAssertEqual(outPage.rotation, 90)
        XCTAssertEqual(outPage.bounds(for: .mediaBox), page.bounds(for: .mediaBox))
    }

    func testPDFKitBackendPDFToImageRotated() async throws {
        let sourcePDF = tempDirectory.appendingPathComponent("image-rotated-source.pdf")
        let doc = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 400), for: .mediaBox)
        page.rotation = 90
        let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 30, height: 30), forType: .square, withProperties: nil)
        annotation.color = .black
        page.addAnnotation(annotation)
        doc.insert(page, at: 0)
        XCTAssertTrue(doc.write(to: sourcePDF))

        let preset = ConversionPreset(
            name: "PDF to PNG",
            category: .image,
            sourceFormats: ["pdf"],
            destinationFormat: "png",
            backend: .pdfKit
        )
        let backend = PDFKitBackend()
        let job = ConversionJob(sourceURL: sourcePDF, preset: preset)
        let requirements = try await backend.outputRequirements(for: job)
        XCTAssertEqual(requirements.count, 1)

        let tempURL = tempDirectory.appendingPathComponent(".image-rotated.png")
        let outputs = [PlannedConversionOutput(finalURL: tempURL, temporaryURL: tempURL)]

        _ = try await backend.convert(job: job, outputs: outputs) { _ in }

        let img = try XCTUnwrap(NSImage(contentsOf: tempURL))
        guard let rep = img.representations.first as? NSBitmapImageRep else {
            XCTFail("Could not get bitmap representation")
            return
        }
        // At 2x scale, 400x200 (rotated from 200x400) should be 800 wide by 400 high
        XCTAssertEqual(rep.pixelsWide, 800)
        XCTAssertEqual(rep.pixelsHigh, 400)

        // Verify that the rotated drawing contains rendered pixels
        var nonWhiteFound = false
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let color = rep.colorAt(x: x, y: y),
                   (color.redComponent < 0.9 || color.greenComponent < 0.9 || color.blueComponent < 0.9) {
                    nonWhiteFound = true
                    break
                }
            }
            if nonWhiteFound { break }
        }
        XCTAssertTrue(nonWhiteFound, "Rotated PDF page drawing should contain rendered content")
    }

    func testPDFKitBackendCompressPreservesOrStripsMetadata() async throws {
        let sourcePDF = tempDirectory.appendingPathComponent("meta-source.pdf")
        let doc = PDFDocument()
        let img = createTestImage(text: "Metadata Test")
        let page = try XCTUnwrap(PDFPage(image: img))
        doc.insert(page, at: 0)
        doc.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Test Title",
            PDFDocumentAttribute.authorAttribute: "Test Author"
        ]
        XCTAssertTrue(doc.write(to: sourcePDF))

        let backend = PDFKitBackend()

        // 1. Preserved metadata
        var preservePreset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "document.pdf-compressed" }
        )
        var options = ConversionProcessingOptions()
        options.pdfRemoveMetadata = false
        preservePreset.processingOptions = options

        let tempURL1 = tempDirectory.appendingPathComponent(".meta-preserved.pdf")
        let job1 = ConversionJob(sourceURL: sourcePDF, preset: preservePreset)
        _ = try await backend.convert(job: job1, outputs: [PlannedConversionOutput(finalURL: tempURL1, temporaryURL: tempURL1)]) { _ in }

        let docPreserved = try XCTUnwrap(PDFDocument(url: tempURL1))
        XCTAssertEqual(docPreserved.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Test Title")

        // 2. Stripped metadata
        var stripPreset = preservePreset
        var stripOptions = options
        stripOptions.pdfRemoveMetadata = true
        stripPreset.processingOptions = stripOptions

        let tempURL2 = tempDirectory.appendingPathComponent(".meta-stripped.pdf")
        let job2 = ConversionJob(sourceURL: sourcePDF, preset: stripPreset)
        _ = try await backend.convert(job: job2, outputs: [PlannedConversionOutput(finalURL: tempURL2, temporaryURL: tempURL2)]) { _ in }

        let docStripped = try XCTUnwrap(PDFDocument(url: tempURL2))
        XCTAssertNil(docStripped.documentAttributes?[PDFDocumentAttribute.titleAttribute])
    }

    func testPDFKitBackendDirectPDFToPDFConversion() async throws {
        let sourcePDF = tempDirectory.appendingPathComponent("direct-pdf-source.pdf")
        let doc = PDFDocument()
        for i in 0..<3 {
            let img = createTestImage(text: "Direct Page \(i + 1)")
            let page = try XCTUnwrap(PDFPage(image: img))
            doc.insert(page, at: i)
        }
        XCTAssertTrue(doc.write(to: sourcePDF))

        let preset = ConversionPreset(
            name: "Direct PDF Copy",
            category: .document,
            sourceFormats: ["pdf"],
            destinationFormat: "pdf",
            backend: .pdfKit
        )
        let backend = PDFKitBackend()
        let destPDF = tempDirectory.appendingPathComponent("direct-pdf-result.pdf")
        let job = ConversionJob(sourceURL: sourcePDF, destinationURL: destPDF, preset: preset)

        try await backend.convert(job: job) { _ in }

        let resultDoc = try XCTUnwrap(PDFDocument(url: destPDF))
        XCTAssertEqual(resultDoc.pageCount, 3)
    }

    func testPDFKitBackendCompressRemovesOrPreservesAnnotations() async throws {
        let sourcePDF = tempDirectory.appendingPathComponent("annotation-source.pdf")
        let doc = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 200), for: .mediaBox)
        let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 50, height: 50), forType: .square, withProperties: nil)
        annotation.color = .red
        page.addAnnotation(annotation)
        doc.insert(page, at: 0)
        XCTAssertTrue(doc.write(to: sourcePDF))

        let backend = PDFKitBackend()

        // 1. Remove annotations
        var removePreset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "document.pdf-compressed" }
        )
        var removeOptions = ConversionProcessingOptions()
        removeOptions.pdfRemoveAnnotations = true
        removePreset.processingOptions = removeOptions

        let destRemove = tempDirectory.appendingPathComponent("removed-annotations.pdf")
        let jobRemove = ConversionJob(sourceURL: sourcePDF, destinationURL: destRemove, preset: removePreset)
        try await backend.convert(job: jobRemove) { _ in }

        let docRemove = try XCTUnwrap(PDFDocument(url: destRemove))
        XCTAssertEqual(docRemove.pageCount, 1)

        // 2. Keep annotations
        var keepPreset = removePreset
        var keepOptions = removeOptions
        keepOptions.pdfRemoveAnnotations = false
        keepPreset.processingOptions = keepOptions

        let destKeep = tempDirectory.appendingPathComponent("kept-annotations.pdf")
        let jobKeep = ConversionJob(sourceURL: sourcePDF, destinationURL: destKeep, preset: keepPreset)
        try await backend.convert(job: jobKeep) { _ in }

        let docKeep = try XCTUnwrap(PDFDocument(url: destKeep))
        XCTAssertEqual(docKeep.pageCount, 1)
    }

    func testPDFKitBackendRejectsUnsupportedImageTargets() throws {
        let backend = PDFKitBackend()
        let pdfFormat = try XCTUnwrap(FormatRegistry.shared.format(forID: "pdf"))
        let webpFormat = try XCTUnwrap(FormatRegistry.shared.format(forID: "webp"))
        let pngFormat = try XCTUnwrap(FormatRegistry.shared.format(forID: "png"))

        let presetWebP = ConversionPreset(
            name: "PDF to WebP",
            category: .image,
            sourceFormats: ["pdf"],
            destinationFormat: "webp",
            backend: .pdfKit
        )
        XCTAssertFalse(backend.supports(sourceFormat: pdfFormat, destinationFormat: webpFormat, preset: presetWebP))

        let presetPNG = ConversionPreset(
            name: "PDF to PNG",
            category: .image,
            sourceFormats: ["pdf"],
            destinationFormat: "png",
            backend: .pdfKit
        )
        XCTAssertTrue(backend.supports(sourceFormat: pdfFormat, destinationFormat: pngFormat, preset: presetPNG))
    }

    func testPDFKitBackendCancellationHandling() async throws {
        let sourcePDF = tempDirectory.appendingPathComponent("cancellation-test.pdf")
        let doc = PDFDocument()
        for i in 0..<5 {
            let img = createTestImage(text: "Page \(i + 1)")
            let page = try XCTUnwrap(PDFPage(image: img))
            doc.insert(page, at: i)
        }
        XCTAssertTrue(doc.write(to: sourcePDF))

        let backend = PDFKitBackend()
        let destPDF = tempDirectory.appendingPathComponent("cancellation-result.pdf")
        let preset = ConversionPreset(
            name: "Direct PDF Copy",
            category: .document,
            sourceFormats: ["pdf"],
            destinationFormat: "pdf",
            backend: .pdfKit
        )

        // 1. Pre-conversion cancellation
        let jobPre = ConversionJob(sourceURL: sourcePDF, destinationURL: destPDF, preset: preset)
        await backend.cancel(jobID: jobPre.id)
        do {
            try await backend.convert(job: jobPre) { _ in }
            XCTFail("Should have thrown ConversionError.cancelled")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .cancelled)
        }

        // 2. Active cancellation during split
        var splitPreset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "document.pdf-split-pages" }
        )
        let splitJob = ConversionJob(sourceURL: sourcePDF, preset: splitPreset)
        let reqs = try await backend.outputRequirements(for: splitJob)
        let outputs = reqs.enumerated().map { idx, _ in
            PlannedConversionOutput(
                finalURL: tempDirectory.appendingPathComponent("split-\(idx).pdf"),
                temporaryURL: tempDirectory.appendingPathComponent(".split-\(idx).pdf")
            )
        }
        await backend.cancel(jobID: splitJob.id)
        do {
            _ = try await backend.convert(job: splitJob, outputs: outputs) { _ in }
            XCTFail("Should have thrown ConversionError.cancelled")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    private func createTestImage(text: String) -> NSImage {
        let size = NSSize(width: 200, height: 200)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24),
            .foregroundColor: NSColor.black
        ]
        (text as NSString).draw(at: NSPoint(x: 20, y: 80), withAttributes: attrs)
        image.unlockFocus()
        return image
    }
}
