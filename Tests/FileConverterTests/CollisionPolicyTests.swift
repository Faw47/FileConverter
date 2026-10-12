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

@MainActor
final class CollisionSheetTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var previousStore: UserDefaults!

    override func setUp() async throws {
        directory = try BackendHarness.makeTempDirectory("CollisionSheet")
        suiteName = "CollisionSheetTests-\(UUID().uuidString)"
        previousStore = ConversionDefaults.store
        ConversionDefaults.store = UserDefaults(suiteName: suiteName)!
        ConversionDefaults.store.set(OverwritePolicy.ask.rawValue, forKey: ConversionDefaults.Keys.overwritePolicy)
        BackendResolver.shared.configure(backends: NativeBackendCatalog.makeBackends())
    }

    override func tearDown() async throws {
        ConversionDefaults.store.removePersistentDomain(forName: suiteName)
        ConversionDefaults.store = previousStore
        try? FileManager.default.removeItem(at: directory)
    }

    func testResolvingOneRowChangesOnlyThatJob() async throws {
        let preset = try BackendHarness.builtIn("image.jpeg")
        var jobs: [ConversionJob] = []
        for name in ["a", "b", "c"] {
            let source = try TestFixtures.copy("same_name/photo.png", to: directory, as: "\(name).png")
            try Data("old".utf8).write(to: directory.appendingPathComponent("\(name).jpg"))
            jobs.append(ConversionJob(sourceURL: source, preset: preset))
        }
        let queue = ConversionQueue()
        queue.setMaxConcurrency(3)
        queue.addJobs(jobs)
        for _ in 0..<200 where queue.pendingCollisions.count < 3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(queue.pendingCollisions.count, 3)

        let middle = queue.jobs[1].id
        queue.resolveCollisions(.skip, jobIDs: [middle])
        XCTAssertEqual(Set(queue.pendingCollisions.map(\.jobID)), Set([queue.jobs[0].id, queue.jobs[2].id]))
        guard case .skipped = try XCTUnwrap(queue.jobs.first { $0.id == middle }).state else {
            return XCTFail("the middle job should be skipped")
        }

        // A decision without a target is ignored instead of guessing a row.
        queue.resolveCollisions(.replace)
        XCTAssertEqual(queue.pendingCollisions.count, 2)

        queue.resolveCollisions(.keepBoth, applyToAll: true)
        for _ in 0..<200 where !queue.jobs.allSatisfy({ $0.state.isTerminal }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("a (1).jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("c (1).jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("b (1).jpg").path))
    }

    func testOneBatchWithManyConflictsActivatesTheAppOnce() async throws {
        var activations = 0
        let token = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("FileConverterActivateApp"), object: nil, queue: nil
        ) { _ in activations += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let preset = try BackendHarness.builtIn("image.jpeg")
        var jobs: [ConversionJob] = []
        for name in ["d", "e", "f", "g"] {
            let source = try TestFixtures.copy("same_name/photo.png", to: directory, as: "\(name).png")
            try Data("old".utf8).write(to: directory.appendingPathComponent("\(name).jpg"))
            jobs.append(ConversionJob(sourceURL: source, preset: preset))
        }
        let queue = ConversionQueue()
        queue.setMaxConcurrency(2)
        queue.addJobs(jobs)
        for _ in 0..<200 where queue.pendingCollisions.count < 4 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(queue.pendingCollisions.count, 4)
        XCTAssertEqual(activations, 1)
        queue.cancelAll()
    }
}
