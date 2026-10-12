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

    func testHistorySurvivesRelaunchAndCannotBeRetried() async throws {
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
        XCTAssertEqual(relaunched.jobs.first?.state, .completed, "history rows are not retried")

        relaunched.clearCompleted()
        XCTAssertTrue(QueueHistoryStore.load(from: historyURL).isEmpty, "clearing also clears history")
    }
}
