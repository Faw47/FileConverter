import XCTest
import CoreGraphics
import AppKit
import Dispatch
import PDFKit
@testable import FileConverterCore
import FileConverterNativeBackends

final class ConversionBackendTests: XCTestCase {
    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("BackendTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testNativeImageIOConversion() async throws {
        // Create a programmatic PNG image fixture
        let srcPNG = tempDirectory.appendingPathComponent("test_image.png")
        createTestPNGImage(at: srcPNG, width: 200, height: 200)
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcPNG.path))

        let backend = ImageIOBackend()
        let jpegPreset = BuiltInPresets.makeDefaultPresets().first { $0.menuName == "JPEG" }!

        let destJPEG = tempDirectory.appendingPathComponent("test_image.jpg")
        let job = ConversionJob(
            sourceURL: srcPNG,
            destinationURL: destJPEG,
            preset: jpegPreset
        )

        let progressTracker = TestProgressTracker()
        try await backend.convert(job: job) { progress in
            progressTracker.add(progress.fractionCompleted)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: destJPEG.path))
        XCTAssertGreaterThan(FileAccessManager.shared.fileSize(at: destJPEG), 0)
        XCTAssertFalse(progressTracker.values.isEmpty)
        XCTAssertEqual(progressTracker.values.last, 1.0)
    }

    func testNativePDFKitImageToPDFConversion() async throws {
        let srcPNG = tempDirectory.appendingPathComponent("test_document.png")
        createTestPNGImage(at: srcPNG, width: 300, height: 300)

        let backend = PDFKitBackend()
        let pdfPreset = BuiltInPresets.makeDefaultPresets().first { $0.menuName == "PDF" }!
        let destPDF = tempDirectory.appendingPathComponent("test_document.pdf")

        let job = ConversionJob(
            sourceURL: srcPNG,
            destinationURL: destPDF,
            preset: pdfPreset
        )

        try await backend.convert(job: job) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: destPDF.path))
        XCTAssertGreaterThan(FileAccessManager.shared.fileSize(at: destPDF), 0)
    }

    func testPDFKitExportsEveryPageWithDeterministicRequirements() async throws {
        let sourcePDF = tempDirectory.appendingPathComponent("two-pages.data")
        let document = PDFDocument()
        for index in 0..<2 {
            let imageURL = tempDirectory.appendingPathComponent("page-\(index).png")
            createTestPNGImage(at: imageURL, width: 120, height: 80)
            let image = try XCTUnwrap(NSImage(contentsOf: imageURL))
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: index)
        }
        XCTAssertTrue(document.write(to: sourcePDF))

        let backend = PDFKitBackend()
        let preset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "image.pdf-to-png" }
        )
        let job = ConversionJob(sourceURL: sourcePDF, preset: preset)
        let requirements = try await backend.outputRequirements(for: job)
        XCTAssertEqual(requirements.map(\.suffix), ["page-001", "page-002"])

        let outputs = requirements.enumerated().map { index, _ in
            PlannedConversionOutput(
                finalURL: tempDirectory.appendingPathComponent("result-page-\(index + 1).png"),
                temporaryURL: tempDirectory.appendingPathComponent(".result-page-\(index + 1).tmp.png")
            )
        }
        _ = try await backend.convert(job: job, outputs: outputs) { _ in }
        XCTAssertTrue(outputs.allSatisfy { FileManager.default.fileExists(atPath: $0.temporaryURL.path) })
        XCTAssertTrue(outputs.allSatisfy { FileAccessManager.shared.fileSize(at: $0.temporaryURL) > 0 })
    }

    func testPDFKitSplitsPDFIntoSinglePagePDFs() async throws {
        let sourcePDF = tempDirectory.appendingPathComponent("source.pdf")
        let document = PDFDocument()
        for index in 0..<3 {
            let imageURL = tempDirectory.appendingPathComponent("split-page-\(index).png")
            createTestPNGImage(at: imageURL, width: 120 + index, height: 80)
            document.insert(try XCTUnwrap(PDFPage(image: try XCTUnwrap(NSImage(contentsOf: imageURL)))), at: index)
        }
        XCTAssertTrue(document.write(to: sourcePDF))

        let backend = PDFKitBackend()
        let preset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "document.pdf-split-pages" }
        )
        let job = ConversionJob(sourceURL: sourcePDF, preset: preset)
        let requirements = try await backend.outputRequirements(for: job)
        XCTAssertEqual(requirements.map(\.extensionName), ["pdf", "pdf", "pdf"])
        XCTAssertEqual(requirements.map(\.suffix), ["page-001", "page-002", "page-003"])

        let outputs = requirements.enumerated().map { index, _ in
            PlannedConversionOutput(
                finalURL: tempDirectory.appendingPathComponent("split-result-\(index + 1).pdf"),
                temporaryURL: tempDirectory.appendingPathComponent(".split-result-\(index + 1).pdf")
            )
        }
        _ = try await backend.convert(job: job, outputs: outputs) { _ in }

        for output in outputs {
            let splitDocument = try XCTUnwrap(PDFDocument(url: output.temporaryURL))
            XCTAssertEqual(splitDocument.pageCount, 1)
        }
    }

    func testPDFPageSplitHonorsBackendCancellationBetweenPages() async throws {
        let sourcePDF = tempDirectory.appendingPathComponent("cancellable-source.pdf")
        let document = PDFDocument()
        for index in 0..<3 {
            let imageURL = tempDirectory.appendingPathComponent("cancellable-page-\(index).png")
            createTestPNGImage(at: imageURL, width: 120 + index, height: 80)
            document.insert(try XCTUnwrap(PDFPage(image: try XCTUnwrap(NSImage(contentsOf: imageURL)))), at: index)
        }
        XCTAssertTrue(document.write(to: sourcePDF))

        let backend = PDFKitBackend()
        let preset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "document.pdf-split-pages" }
        )
        let job = ConversionJob(sourceURL: sourcePDF, preset: preset)
        let requirements = try await backend.outputRequirements(for: job)
        let outputs = requirements.enumerated().map { index, _ in
            PlannedConversionOutput(
                finalURL: tempDirectory.appendingPathComponent("cancelled-result-\(index + 1).pdf"),
                temporaryURL: tempDirectory.appendingPathComponent(".cancelled-result-\(index + 1).pdf")
            )
        }
        let cancellationGate = CancellationGate()

        do {
            _ = try await backend.convert(job: job, outputs: outputs) { _ in
                guard cancellationGate.beginCancellation() else { return }
                Task {
                    await backend.cancel(jobID: job.id)
                    cancellationGate.signalCancellation()
                }
                _ = cancellationGate.waitForCancellation()
            }
            XCTFail("PDF page splitting should stop after backend cancellation")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .cancelled)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputs[0].temporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputs[1].temporaryURL.path))
    }

    func testBackendResolverNativeFirst() throws {
        let resolver = BackendResolver(backends: NativeBackendCatalog.makeBackends())
        let pngURL = tempDirectory.appendingPathComponent("sample.png")
        let jpegPreset = BuiltInPresets.makeDefaultPresets().first { $0.menuName == "JPEG" }!

        let imageJob = ConversionJob(sourceURL: pngURL, preset: jpegPreset)
        let resolved = try resolver.resolveBackend(for: imageJob)
        XCTAssertEqual(resolved.backendType, .imageIO)
    }

    func testBackendResolverUsesContentBeforeMisleadingExtension() throws {
        let resolver = BackendResolver(backends: NativeBackendCatalog.makeBackends())
        let disguisedPNG = tempDirectory.appendingPathComponent("sample.txt")
        createTestPNGImage(at: disguisedPNG, width: 40, height: 40)
        let jpegPreset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "image.jpeg" }
        )

        let resolved = try resolver.resolveBackend(
            for: ConversionJob(sourceURL: disguisedPNG, preset: jpegPreset)
        )

        XCTAssertEqual(resolved.backendType, .imageIO)
    }

    private func createTestPNGImage(at url: URL, width: Int, height: Int) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        if let cgImage = context.makeImage() {
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
            if let tiff = nsImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                try? pngData.write(to: url)
            }
        }
    }
}

private final class TestProgressTracker: @unchecked Sendable {
    private var progressValues: [Double] = []
    private let lock = NSLock()

    func add(_ val: Double) {
        lock.lock()
        progressValues.append(val)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return progressValues
    }
}

private final class CancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var cancellationStarted = false

    func beginCancellation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancellationStarted else { return false }
        cancellationStarted = true
        return true
    }

    func signalCancellation() {
        semaphore.signal()
    }

    func waitForCancellation() -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + 1)
    }
}
