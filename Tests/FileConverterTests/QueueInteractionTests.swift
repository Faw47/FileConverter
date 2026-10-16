import XCTest
@testable import FileConverterCore
import FileConverterNativeBackends

@MainActor
final class QueueInteractionTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = try BackendHarness.makeTempDirectory("QueueInteraction")
        BackendResolver.shared.configure(backends: NativeBackendCatalog.makeBackends())
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sources(_ count: Int) throws -> [URL] {
        try (1...count).map { try TestFixtures.copy("same_name/photo.png", to: directory, as: "img\($0).png") }
    }

    func testPausedQueueStartsNothingUntilResumed() async throws {
        let queue = ConversionQueue()
        queue.pause()
        queue.addJobs(try sources(2).map { ConversionJob(sourceURL: $0, preset: try BackendHarness.builtIn("image.jpeg")) })
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(queue.jobs.allSatisfy { $0.state == .queued })
        queue.resume()
        for _ in 0..<200 where !queue.jobs.allSatisfy({ $0.state.isTerminal }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(queue.completedCount, 2)
    }

    func testReorderChangesStartOrder() throws {
        let queue = ConversionQueue()
        queue.pause()
        queue.addJobs(try sources(3).map { ConversionJob(sourceURL: $0, preset: try BackendHarness.builtIn("image.jpeg")) })
        let ids = queue.jobs.map(\.id)
        queue.moveQueuedJob(id: ids[2], before: ids[0])
        XCTAssertEqual(queue.jobs.map(\.id), [ids[2], ids[0], ids[1]])
        queue.moveQueuedJob(id: ids[2], before: nil)
        XCTAssertEqual(queue.jobs.map(\.id), [ids[0], ids[1], ids[2]])
        queue.cancelAll()
    }

    private func waitUntilTerminal(_ queue: ConversionQueue) async throws {
        for _ in 0..<200 where !queue.jobs.allSatisfy({ $0.state.isTerminal }) {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testFailedHistoryRowIsRetriedWithItsPresetInANewBatch() async throws {
        let historyURL = directory.appendingPathComponent("history.json")
        let missing = directory.appendingPathComponent("later.png")
        var preset = try BackendHarness.builtIn("image.jpeg")
        preset.quality = .low

        let first = ConversionQueue()
        first.restoreHistory(from: historyURL)
        first.addJobs([ConversionJob(sourceURL: missing, preset: preset)])
        try await waitUntilTerminal(first)
        guard case .failed = try XCTUnwrap(first.jobs.first).state else {
            return XCTFail("a missing source fails")
        }
        // A newer batch the retried row has to move after.
        first.addJobs(try sources(1).map { ConversionJob(sourceURL: $0, preset: try BackendHarness.builtIn("image.jpeg")) })
        try await waitUntilTerminal(first)

        let relaunched = ConversionQueue()
        relaunched.restoreHistory(from: historyURL)
        let restored = try XCTUnwrap(relaunched.jobs.first)
        XCTAssertTrue(restored.isFromHistory)
        XCTAssertTrue(restored.canConvertAgain)
        XCTAssertEqual(restored.preset, preset, "the record keeps the preset exactly as it ran")
        XCTAssertFalse(try XCTUnwrap(relaunched.jobs.last).canConvertAgain, "converted rows are not retried")

        _ = try TestFixtures.copy("same_name/photo.png", to: directory, as: "later.png")
        relaunched.retryJob(id: restored.id)
        let retried = try XCTUnwrap(relaunched.jobs.last)
        XCTAssertEqual(retried.id, restored.id, "a retried history row moves after everything else")
        XCTAssertFalse(retried.isFromHistory)
        XCTAssertNotEqual(retried.batchID, restored.batchID, "it starts a batch of its own")

        try await waitUntilTerminal(relaunched)
        XCTAssertEqual(relaunched.jobs.last?.state, .completed)
        XCTAssertEqual(relaunched.jobs.last?.outputURLs.first?.pathExtension, "jpg")
    }

    func testHistoryRowWithoutStoredPresetIsNotRetried() throws {
        let record = QueueHistoryStore.Record(
            id: UUID(), batchID: UUID(), batchCreatedAt: Date(),
            sourcePath: directory.appendingPathComponent("old.png").path,
            presetName: "JPEG Image", presetMenuName: "JPEG", category: .image, destinationFormat: "jpg",
            outcome: .failed, message: "Conversion failed.", outputPaths: [], startedAt: nil, finishedAt: nil
        )
        let restored = QueueHistoryStore.job(from: record)
        XCTAssertTrue(restored.isFromHistory)
        XCTAssertFalse(restored.canConvertAgain, "older records did not keep the preset")

        let queue = ConversionQueue()
        queue.setJobsForTesting([restored])
        queue.retryJob(id: restored.id)
        guard case .failed = try XCTUnwrap(queue.jobs.first).state else {
            return XCTFail("left as it was")
        }
    }

    func testCancellingWaitingJobsClosesTheirJournalEntries() throws {
        let queue = ConversionQueue()
        queue.pause()
        let jobs = try sources(3).map { ConversionJob(sourceURL: $0, preset: try BackendHarness.builtIn("image.jpeg")) }
        for job in jobs {
            ConversionJournal.shared.recordAdmission(
                jobID: job.id, requestID: UUID(), sourceURL: job.sourceURL,
                bookmarkData: nil, presetID: job.preset.id, presetName: job.preset.name
            )
        }
        queue.addJobs(jobs)

        queue.cancelJob(id: jobs[0].id)
        XCTAssertEqual(ConversionJournal.shared.entry(for: jobs[0].id)?.state, .cancelled)
        queue.cancelAll()
        for job in jobs {
            XCTAssertEqual(ConversionJournal.shared.entry(for: job.id)?.state, .cancelled,
                           "a cancelled waiting job is not reported as interrupted next launch")
        }
    }

    func testHistorySurvivesRelaunchAndConvertedRowsAreNotRetried() async throws {
        let historyURL = directory.appendingPathComponent("history.json")
        let first = ConversionQueue()
        first.restoreHistory(from: historyURL)
        first.addJobs(try sources(1).map { ConversionJob(sourceURL: $0, preset: try BackendHarness.builtIn("image.jpeg")) })
        for _ in 0..<200 where !(first.jobs.first?.state.isTerminal ?? false) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(first.jobs.first?.state, .completed)

        let relaunched = ConversionQueue()
        relaunched.restoreHistory(from: historyURL)
        let restored = try XCTUnwrap(relaunched.jobs.first)
        XCTAssertTrue(restored.isFromHistory)
        XCTAssertEqual(restored.state, .completed)
        XCTAssertEqual(restored.outputURLs, first.jobs.first?.outputURLs)
        XCTAssertEqual(restored.preset.menuName, "JPEG")

        relaunched.retryJob(id: restored.id)
        XCTAssertEqual(relaunched.jobs.first?.state, .completed, "converted history rows are not retried")

        relaunched.clearCompleted()
        XCTAssertTrue(QueueHistoryStore.load(from: historyURL).isEmpty, "clearing also clears history")
    }
}
