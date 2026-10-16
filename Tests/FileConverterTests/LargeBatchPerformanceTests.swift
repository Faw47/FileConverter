import Foundation
import XCTest
@testable import FileConverterCore

/// Large drops (folders allow up to 10,000 files) must not make the preset
/// picker redo format detection on every redraw or keystroke.
final class LargeBatchPerformanceTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LargeBatchPerformanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FormatDetector.clearCache()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        FormatDetector.clearCache()
    }

    private func makeJPEGs(_ count: Int) throws -> [URL] {
        let header = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])
        return try (0..<count).map { index in
            let url = folder.appendingPathComponent("photo-\(index).jpg")
            try header.write(to: url)
            return url
        }
    }

    func testPickerPassOverTwoThousandFilesIsFastAfterFirstPass() throws {
        let urls = try makeJPEGs(2_000)
        let cache = SourceBatchCache()
        let presets = PresetStore.shared.enabledPresets

        // What one picker redraw reads.
        func pass() {
            let analysis = cache.analysis(for: urls)
            _ = analysis.unsupported.count
            _ = analysis.groups.count
            _ = cache.compatiblePresets(forURLs: analysis.recognized, from: presets)
            _ = cache.value("canCombine") { analysis.recognized.count >= 2 }
        }

        pass()
        XCTAssertEqual(cache.analysis(for: urls).recognized.count, 2_000)

        let start = Date()
        for _ in 0..<10 { pass() }
        let perPass = Date().timeIntervalSince(start) / 10
        XCTAssertLessThan(perPass, 0.05, "Picker pass took \(Int(perPass * 1000)) ms")
    }

    func testDetectionCacheKeepsBatchesLargerThanFiveHundred() throws {
        let urls = try makeJPEGs(1_200)
        urls.forEach { _ = FormatDetector.detect(url: $0) }
        let storage = DetectionSnapshotStorage(capacity: 20_000)
        for url in urls { storage.set(FormatDetector.snapshot(for: url), for: url) }
        XCTAssertEqual(storage.count, 1_200)
        XCTAssertNotNil(storage.get(for: urls[0]))
    }

    func testDetectionCacheEvictsLeastRecentlyUsed() throws {
        let urls = try makeJPEGs(8)
        let storage = DetectionSnapshotStorage(capacity: 4)
        for url in urls.prefix(4) { storage.set(FormatDetector.snapshot(for: url), for: url) }
        _ = storage.get(for: urls[0])
        storage.set(FormatDetector.snapshot(for: urls[4]), for: urls[4])
        XCTAssertNotNil(storage.get(for: urls[0]), "Recently used entry was evicted")
        XCTAssertNil(storage.get(for: urls[1]), "Oldest entry was kept")
        XCTAssertEqual(storage.count, 4)
    }
}
