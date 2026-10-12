import XCTest
@testable import FileConverterCore
import FileConverterNativeBackends

/// General "If a file already exists" must apply to built-in presets the same
/// way it applies to custom ones: Ask pauses, Skip skips, nothing fails.
@MainActor
final class CollisionPolicyTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var previousStore: UserDefaults!

    override func setUp() async throws {
        directory = try BackendHarness.makeTempDirectory("CollisionPolicy")
        suiteName = "CollisionPolicyTests-\(UUID().uuidString)"
        previousStore = ConversionDefaults.store
        ConversionDefaults.store = UserDefaults(suiteName: suiteName)!
        BackendResolver.shared.configure(backends: NativeBackendCatalog.makeBackends())
    }

    override func tearDown() async throws {
        ConversionDefaults.store.removePersistentDomain(forName: suiteName)
        ConversionDefaults.store = previousStore
        try? FileManager.default.removeItem(at: directory)
    }

    private func runJPEGConversion(globalPolicy: OverwritePolicy) async throws -> (ConversionQueue, ConversionJob) {
        ConversionDefaults.store.set(globalPolicy.rawValue, forKey: ConversionDefaults.Keys.overwritePolicy)
        let source = try TestFixtures.copy("same_name/photo.png", to: directory)
        try Data("existing".utf8).write(to: directory.appendingPathComponent("photo.jpg"))

        let queue = ConversionQueue()
        queue.setMaxConcurrency(1)
        let preset = try BackendHarness.builtIn("image.jpeg")
        queue.addJobs([ConversionJob(sourceURL: source, preset: preset)])
        for _ in 0..<200 {
            if let job = queue.jobs.first, job.state.isTerminal || job.state == .awaitingCollision { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return (queue, try XCTUnwrap(queue.jobs.first))
    }

    func testGeneralAskPausesBuiltInPresetInsteadOfFailing() async throws {
        let (queue, job) = try await runJPEGConversion(globalPolicy: .ask)
        XCTAssertEqual(job.state, .awaitingCollision, "got \(job.state)")
        XCTAssertEqual(queue.pendingCollisions.map(\.jobID), [job.id])
        queue.cancelAll()
    }

    func testGeneralSkipSkipsBuiltInPresetInsteadOfFailing() async throws {
        let (_, job) = try await runJPEGConversion(globalPolicy: .skip)
        guard case .skipped = job.state else {
            return XCTFail("expected skipped, got \(job.state)")
        }
        let existing = try String(contentsOf: directory.appendingPathComponent("photo.jpg"), encoding: .utf8)
        XCTAssertEqual(existing, "existing")
    }

    func testGeneralAppendNumberKeepsBoth() async throws {
        let (_, job) = try await runJPEGConversion(globalPolicy: .appendNumber)
        XCTAssertEqual(job.state, .completed, "got \(job.state)")
        XCTAssertEqual(job.destinationURL?.lastPathComponent, "photo (1).jpg")
    }
}
