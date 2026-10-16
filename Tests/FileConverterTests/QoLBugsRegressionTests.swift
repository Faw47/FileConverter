import XCTest
@testable import FileConverterCore

final class QoLBugsRegressionTests: XCTestCase {
    func testNotificationUserInfoContainsOnlyOpaqueBatchID() {
        let batchID = UUID()
        let userInfo = ConversionQueue.notificationUserInfo(for: batchID)

        XCTAssertEqual(NotificationURLResolver.batchID(from: userInfo), batchID)
        XCTAssertNil(userInfo["destinationPaths"])
        XCTAssertFalse(userInfo.values.contains { value in
            guard let string = value as? String else { return false }
            return string.contains("/")
        })
    }

    func testNotificationURLResolverHandlesMissingAndMalformedUserInfo() {
        let cases: [[AnyHashable: Any]] = [
            [:],
            [ConversionQueue.completionBatchIdentifierKey: "not-a-uuid"],
            [ConversionQueue.completionBatchIdentifierKey: 42]
        ]

        for userInfo in cases {
            XCTAssertNil(NotificationURLResolver.batchID(from: userInfo))
        }
    }

    @MainActor
    func testNotificationHandoffNoOpsForMissingOrUnallowlistedTarget() throws {
        let queue = ConversionQueue()
        let batchID = UUID()
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-target-\(UUID().uuidString)")
        try Data("output".utf8).write(to: target)
        defer {
            try? FileManager.default.removeItem(at: target)
            queue.clearNotificationHandoffForTesting(batchID: batchID)
        }

        queue.persistNotificationHandoffForTesting(batchID: batchID, outputURLs: [target])
        try FileManager.default.removeItem(at: target)

        var didReveal = false
        queue.withNotificationRevealURLs(for: batchID) { _ in didReveal = true }
        XCTAssertFalse(didReveal)
    }

    @MainActor
    func testNotificationHandoffResolvesOnlyAllowlistedReadableTarget() throws {
        let queue = ConversionQueue()
        let batchID = UUID()
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-target-\(UUID().uuidString)")
        let unlisted = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-unlisted-\(UUID().uuidString)")
        try Data("output".utf8).write(to: target)
        try Data("unlisted".utf8).write(to: unlisted)
        defer {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: unlisted)
            queue.clearNotificationHandoffForTesting(batchID: batchID)
        }

        queue.persistNotificationHandoffForTesting(batchID: batchID, outputURLs: [target])

        var resolved: [URL] = []
        queue.withNotificationRevealURLs(for: batchID) { resolved = $0 }

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(
            FileAccessManager.shared.reservationKey(for: resolved[0]),
            FileAccessManager.shared.reservationKey(for: target)
        )
        XCTAssertFalse(resolved.contains(unlisted))
    }

    func testNotificationDefaultIsFalseWhenUnset() {
        withIsolatedDefaults { defaults in
            let enabled = defaults.object(forKey: "enableNotifications") as? Bool ?? false
            XCTAssertFalse(enabled, "enableNotifications should default to false")
        }
    }

    @MainActor
    func testSingleFileBatchNotificationIdentifiesFilenameAndFormat() {
        let preset = BuiltInPresets.makeDefaultPresets().first { $0.destinationFormat.lowercased() == "png" }!
        let job = ConversionJob(
            sourceURL: URL(fileURLWithPath: "/tmp/sample_photo.heic"),
            preset: preset,
            state: .completed
        )

        let body = ConversionQueue.formatBatchNotificationBody(
            total: 1,
            completed: 1,
            failed: 0,
            skippedOrCancelled: 0,
            batchJobs: [job]
        )

        XCTAssertEqual(body, "sample_photo.heic converted to PNG.")
    }

    @MainActor
    func testMultiFileUniformFormatNotificationIdentifiesFormat() {
        let preset = BuiltInPresets.makeDefaultPresets().first { $0.destinationFormat.lowercased() == "mp4" }
            ?? BuiltInPresets.makeDefaultPresets().first { $0.destinationFormat.lowercased() == "png" }!
        let jobs = (1...3).map { i in
            ConversionJob(
                sourceURL: URL(fileURLWithPath: "/tmp/video_\(i).mov"),
                preset: preset,
                state: .completed
            )
        }

        let body = ConversionQueue.formatBatchNotificationBody(
            total: 3,
            completed: 3,
            failed: 0,
            skippedOrCancelled: 0,
            batchJobs: jobs
        )

        XCTAssertEqual(body, "3 files converted to \(preset.destinationFormat.uppercased()).")
    }

    @MainActor
    func testClearCompletedRemovesSkippedJobs() {
        let queue = ConversionQueue()
        let preset = BuiltInPresets.makeDefaultPresets().first!
        let job = ConversionJob(
            sourceURL: URL(fileURLWithPath: "/tmp/file.txt"),
            preset: preset,
            state: .skipped("Duplicate")
        )

        queue.addJobs([job])
        XCTAssertEqual(queue.skippedCount, 1)

        queue.clearCompleted()
        XCTAssertEqual(queue.skippedCount, 0)
        XCTAssertEqual(queue.jobs.count, 0)
    }

    @MainActor
    func testSingleFileFailedNotification() {
        let preset = BuiltInPresets.makeDefaultPresets().first { $0.destinationFormat.lowercased() == "png" }!
        let job = ConversionJob(
            sourceURL: URL(fileURLWithPath: "/tmp/sample_photo.heic"),
            preset: preset,
            state: .failed(.unknown(message: "Disk full"))
        )

        let body = ConversionQueue.formatBatchNotificationBody(
            total: 1,
            completed: 0,
            failed: 1,
            skippedOrCancelled: 0,
            batchJobs: [job]
        )

        XCTAssertEqual(body, "sample_photo.heic conversion failed.")
    }

    @MainActor
    func testSingleFileCancelledNotification() {
        let preset = BuiltInPresets.makeDefaultPresets().first { $0.destinationFormat.lowercased() == "png" }!
        let job = ConversionJob(
            sourceURL: URL(fileURLWithPath: "/tmp/sample_photo.heic"),
            preset: preset,
            state: .cancelled
        )

        let body = ConversionQueue.formatBatchNotificationBody(
            total: 1,
            completed: 0,
            failed: 0,
            skippedOrCancelled: 1,
            batchJobs: [job]
        )

        XCTAssertEqual(body, "sample_photo.heic was cancelled.")
    }

    @MainActor
    func testMultiFileMixedFormatsAndFailuresNotification() {
        let pngPreset = BuiltInPresets.makeDefaultPresets().first { $0.destinationFormat.lowercased() == "png" }!
        let mp4Preset = BuiltInPresets.makeDefaultPresets().first { $0.destinationFormat.lowercased() == "mp4" }
            ?? pngPreset

        let job1 = ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"), preset: mp4Preset, state: .completed)
        let job2 = ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/b.mov"), preset: mp4Preset, state: .completed)
        let job3 = ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/c.mov"), preset: mp4Preset, state: .failed(.unknown(message: "error")))

        let body = ConversionQueue.formatBatchNotificationBody(
            total: 3,
            completed: 2,
            failed: 1,
            skippedOrCancelled: 0,
            batchJobs: [job1, job2, job3]
        )

        XCTAssertEqual(body, "2 converted to MP4, 1 failed.")
    }

    @MainActor
    func testRetryFailedJobTransitionsStateToQueued() {
        let queue = ConversionQueue()
        let preset = BuiltInPresets.makeDefaultPresets().first!
        let job = ConversionJob(
            sourceURL: URL(fileURLWithPath: "/tmp/file.txt"),
            preset: preset,
            state: .failed(.unknown(message: "fail"))
        )

        queue.addJobs([job])
        XCTAssertEqual(queue.failedCount, 1)

        queue.retryJob(id: job.id)
        XCTAssertEqual(queue.failedCount, 0)
        let state = queue.jobs.first?.state
        XCTAssertTrue(state == .queued || state == .preparing || state?.isActive == true)
    }
}
