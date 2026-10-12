import XCTest
@testable import FileConverterCore
import FileConverterNativeBackends

/// Two sources that map to one output name must not fail: the second waits
/// for the first, then the collision policy applies to the real file.
@MainActor
final class DestinationReservationTests: XCTestCase {
    private var directory: URL!
    private var trash: URL!
    private var suiteName: String!
    private var previousStore: UserDefaults!
    private var previousTrash: URL?

    override func setUp() async throws {
        directory = try BackendHarness.makeTempDirectory("Reservation")
        trash = try BackendHarness.makeTempDirectory("ReservationTrash")
        suiteName = "DestinationReservationTests-\(UUID().uuidString)"
        previousStore = ConversionDefaults.store
        ConversionDefaults.store = UserDefaults(suiteName: suiteName)!
        previousTrash = ReplacedFileTrash.directoryOverride
        ReplacedFileTrash.directoryOverride = trash
        BackendResolver.shared.configure(backends: NativeBackendCatalog.makeBackends())
    }

    override func tearDown() async throws {
        ConversionDefaults.store.removePersistentDomain(forName: suiteName)
        ConversionDefaults.store = previousStore
        ReplacedFileTrash.directoryOverride = previousTrash
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: trash)
    }

    private func run(policy: OverwritePolicy) async throws -> ConversionQueue {
        ConversionDefaults.store.set(policy.rawValue, forKey: ConversionDefaults.Keys.overwritePolicy)
        let heic = try TestFixtures.copy("same_name/photo.heic", to: directory)
        let png = try TestFixtures.copy("same_name/photo.png", to: directory)
        let queue = ConversionQueue()
        queue.setMaxConcurrency(2)
        let preset = try BackendHarness.builtIn("image.jpeg")
        queue.addJobs([
            ConversionJob(sourceURL: heic, preset: preset),
            ConversionJob(sourceURL: png, preset: preset)
        ])
        for _ in 0..<300 where !queue.jobs.allSatisfy({ $0.state.isTerminal || $0.state == .awaitingCollision }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        return queue
    }

    func testReplacePolicyWaitsThenReplacesAndTrashesThePrevious() async throws {
        let queue = try await run(policy: .overwrite)
        XCTAssertEqual(queue.jobs.map(\.state), [.completed, .completed], "\(queue.jobs.map(\.state))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("photo.jpg").path))
        let trashed = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        XCTAssertEqual(trashed.count, 1, "the first output must go to the Trash, not disappear")
        XCTAssertTrue(trashed.first?.contains("photo (replaced ") == true, "\(trashed)")
    }

    func testSkipPolicyWaitsThenSkipsTheSecond() async throws {
        let queue = try await run(policy: .skip)
        let states = queue.jobs.map(\.state)
        XCTAssertEqual(states.filter { $0 == .completed }.count, 1, "\(states)")
        XCTAssertEqual(states.filter { if case .skipped = $0 { return true }; return false }.count, 1, "\(states)")
        XCTAssertFalse(states.contains { if case .failed = $0 { return true }; return false })
    }

    func testAskPolicyWaitsThenAsksAboutTheRealFile() async throws {
        let queue = try await run(policy: .ask)
        let states = queue.jobs.map(\.state)
        XCTAssertEqual(states.filter { $0 == .completed }.count, 1, "\(states)")
        XCTAssertEqual(states.filter { $0 == .awaitingCollision }.count, 1, "\(states)")
        let conflict = try XCTUnwrap(queue.pendingCollisions.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: conflict.destinationURL.path))
        queue.cancelAll()
    }
}
