import XCTest
@testable import FileConverterCore
@testable import FileConverterExternalBackends

final class ColdStartAdmissionTests: XCTestCase {
    func testGateWaitsUntilDiscoveryFinishes() async {
        let gate = BackendReadinessGate()
        XCTAssertTrue(gate.ready, "the gate starts open so non-app contexts never block")
        gate.markNotReady()

        let waiter = Task { await gate.waitUntilReady(timeout: .seconds(5)) }
        try? await Task.sleep(for: .milliseconds(50))
        gate.markReady()
        let opened = await waiter.value
        XCTAssertTrue(opened)
    }

    func testGateTimesOutWhenDiscoveryNeverFinishes() async {
        let gate = BackendReadinessGate()
        gate.markNotReady()
        let opened = await gate.waitUntilReady(timeout: .milliseconds(50))
        XCTAssertFalse(opened)
    }

    func testFFmpegCapabilitiesSurviveRelaunch() throws {
        guard TestFixtures.ffmpegPath != nil else { throw XCTSkip("FFmpeg is not installed.") }
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caps-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let firstLaunch = ExternalToolDiscovery(capabilitiesCacheURL: cacheURL)
        XCTAssertNil(firstLaunch.cachedAvailableFFmpegEncoders(), "no probe has run yet")
        firstLaunch.refreshAllTools(force: true)
        let probed = try XCTUnwrap(firstLaunch.cachedAvailableFFmpegEncoders())
        XCTAssertTrue(probed.contains("aac"))
        XCTAssertNotNil(firstLaunch.cachedFFmpegFilters())

        let secondLaunch = ExternalToolDiscovery(capabilitiesCacheURL: cacheURL)
        XCTAssertEqual(secondLaunch.cachedAvailableFFmpegEncoders(), probed,
                       "encoders must be known immediately on the next launch")
    }

    func testCustomToolPathMustBeAnExecutableFile() throws {
        let suite = "ToolPaths-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let discovery = ExternalToolDiscovery(capabilitiesCacheURL: nil, defaults: defaults)

        XCTAssertFalse(discovery.setPathOverride("/tmp", for: "ffmpeg"), "a folder is not a tool")
        XCTAssertFalse(discovery.setPathOverride("/etc/hosts", for: "ffmpeg"), "a non-executable file is not a tool")
        XCTAssertTrue(discovery.setPathOverride("/bin/ls", for: "ffmpeg"))
        XCTAssertEqual(discovery.pathOverride(for: "ffmpeg"), "/bin/ls")
        XCTAssertTrue(discovery.setPathOverride(nil, for: "ffmpeg"))
        XCTAssertNil(discovery.pathOverride(for: "ffmpeg"))
    }

    @MainActor
    func testRejectedRequestBecomesAFailedQueueRow() throws {
        let queue = ConversionQueue()
        let preset = try BackendHarness.builtIn("audio.mp3-320")
        queue.recordRejectedRequest(
            sources: [(displayName: "song.wav", path: "/tmp/song.wav"), (displayName: "b.wav", path: "/tmp/b.wav")],
            preset: preset,
            reason: "MP3 needs FFmpeg."
        )
        XCTAssertEqual(queue.jobs.count, 2)
        XCTAssertEqual(queue.failedCount, 2)
        XCTAssertEqual(Set(queue.jobs.map(\.batchID)).count, 1)
        guard case .failed(let error) = queue.jobs[0].state else { return XCTFail("expected failure") }
        XCTAssertEqual(error.localizedDescription, "MP3 needs FFmpeg.")
    }
}
