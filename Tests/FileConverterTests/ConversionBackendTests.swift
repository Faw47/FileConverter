import XCTest
import CoreGraphics
import AppKit
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

    func testBackendResolverNativeFirst() throws {
        let resolver = BackendResolver(backends: NativeBackendCatalog.makeBackends())
        let pngURL = tempDirectory.appendingPathComponent("sample.png")
        let jpegPreset = BuiltInPresets.makeDefaultPresets().first { $0.menuName == "JPEG" }!

        let imageJob = ConversionJob(sourceURL: pngURL, preset: jpegPreset)
        let resolved = try resolver.resolveBackend(for: imageJob)
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
