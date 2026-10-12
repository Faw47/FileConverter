import XCTest
@testable import FileConverterCore

final class NotificationPolicyTests: XCTestCase {
    func testNoStartedNotificationOneFinishedNotification() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileConverterCore/Conversion/ConversionCoordinator.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("Conversion Started"))
    }

    func testBatchSummaryCountsFailures() {
        let body = ConversionQueue.formatBatchNotificationBody(total: 4, completed: 3, failed: 1, skippedOrCancelled: 0)
        XCTAssertEqual(body, "3 converted, 1 failed.")
    }

    func testActiveBatchProgressCoversOnlyBatchesWithWork() throws {
        let preset = try BackendHarness.builtIn("image.png")
        let doneBatch = UUID(), activeBatch = UUID()
        var finished = ConversionJob(batchID: doneBatch, sourceURL: URL(fileURLWithPath: "/tmp/a.jpg"), preset: preset, state: .completed)
        finished.progress.fractionCompleted = 1
        var half = ConversionJob(batchID: activeBatch, sourceURL: URL(fileURLWithPath: "/tmp/b.jpg"), preset: preset, state: .converting)
        half.progress.fractionCompleted = 0.5
        let done = ConversionJob(batchID: activeBatch, sourceURL: URL(fileURLWithPath: "/tmp/c.jpg"), preset: preset, state: .completed)
        let waiting = ConversionJob(batchID: activeBatch, sourceURL: URL(fileURLWithPath: "/tmp/d.jpg"), preset: preset)

        let progress = try XCTUnwrap(ConversionQueue.activeBatchProgress([finished, half, done, waiting]))
        XCTAssertEqual(progress.remaining, 2)
        XCTAssertEqual(progress.fraction, 0.5, accuracy: 0.001)
        XCTAssertNil(ConversionQueue.activeBatchProgress([finished]))
    }
}
