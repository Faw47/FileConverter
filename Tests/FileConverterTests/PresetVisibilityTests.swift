import XCTest
@testable import FileConverterCore

final class PresetVisibilityTests: XCTestCase {
    private func format(_ id: String) throws -> FormatDefinition {
        try XCTUnwrap(FormatRegistry.shared.format(forID: id))
    }

    func testIdentityConversionsAreHidden() throws {
        let jpeg = try format("jpeg")
        XCTAssertTrue(PresetVisibility.isIdentityTransform(try BackendHarness.builtIn("image.jpeg"), for: jpeg))
        XCTAssertFalse(PresetVisibility.isIdentityTransform(try BackendHarness.builtIn("image.jpeg-web"), for: jpeg), "resizes and has a suffix")
        XCTAssertFalse(PresetVisibility.isIdentityTransform(try BackendHarness.builtIn("image.png"), for: jpeg))
    }

    func testFormatSpecificRecipeReplacesItsGenericTwin() throws {
        let wav = try format("wav")
        let generic = try BackendHarness.builtIn("audio.mp3-320")
        let specific = try BackendHarness.builtIn("audio.wav-to-mp3")
        let variant = try BackendHarness.builtIn("audio.mp3-192")
        let visible = PresetVisibility.visible([generic, specific, variant], for: wav).map(\.builtInKey)
        XCTAssertEqual(visible, ["audio.wav-to-mp3", "audio.mp3-192"], "the 192 kbps variant is different and stays")
    }

    func testRemuxAndReencodeBothStayForMKV() throws {
        let mkv = try format("mkv")
        let visible = PresetVisibility.visible(
            [try BackendHarness.builtIn("video.mp4-balanced"), try BackendHarness.builtIn("video.mkv-to-mp4")],
            for: mkv
        )
        XCTAssertEqual(visible.count, 2)
    }

    func testUsageStoreRemembersPerFormatAndRecents() throws {
        let suite = "Usage-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID(), second = UUID()
        PresetUsageStore.record(presetID: first, sourceFormatIDs: ["png"], defaults: defaults)
        PresetUsageStore.record(presetID: second, sourceFormatIDs: ["mov"], defaults: defaults)
        XCTAssertEqual(PresetUsageStore.lastPresetID(forFormat: "png", defaults: defaults), first)
        XCTAssertEqual(PresetUsageStore.recentPresetIDs(defaults: defaults), [second, first])
        for _ in 0..<20 { PresetUsageStore.record(presetID: UUID(), sourceFormatIDs: ["x"], defaults: defaults) }
        XCTAssertEqual(PresetUsageStore.recentPresetIDs(defaults: defaults).count, PresetUsageStore.recentLimit)
    }

    @MainActor
    func testGroupedRequestsBecomeOneBatch() throws {
        let queue = ConversionQueue()
        queue.pause()
        let preset = try BackendHarness.builtIn("image.png")
        let group = UUID()
        queue.addJobs([ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/1.jpg"), preset: preset)], groupID: group)
        queue.addJobs([ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/2.jpg"), preset: preset)], groupID: group)
        queue.addJobs([ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/3.jpg"), preset: preset)], groupID: UUID())
        queue.addJobs([ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/4.jpg"), preset: preset)])
        let batches = queue.jobs.map(\.batchID)
        XCTAssertEqual(batches[0], batches[1])
        XCTAssertNotEqual(batches[1], batches[2])
        XCTAssertNotEqual(batches[2], batches[3])
        queue.cancelAll()
    }
}
