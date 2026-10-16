import XCTest
@testable import FileConverterCore

final class WatchFolderTests: XCTestCase {
    func testFoldersRoundTripThroughSettings() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WatchFolderTests-\(UUID().uuidString)"))
        XCTAssertEqual(WatchFolderStore.load(defaults: defaults), [])
        let folder = WatchFolder(path: "/tmp/Inbox", presetID: UUID(), isEnabled: false)
        WatchFolderStore.save([folder], defaults: defaults)
        XCTAssertEqual(WatchFolderStore.load(defaults: defaults), [folder])
    }

    func testWatchedConversionsAlwaysGoToTheConvertedSubfolder() throws {
        var preset = try BackendHarness.builtIn("image.jpeg")
        preset.outputDirectoryPolicy = .sameAsSource
        let watched = WatchFolderStore.presetForWatching(preset)
        XCTAssertEqual(watched.outputDirectoryPolicy, .sourceSubfolder(subfolderName: "Converted"))
        XCTAssertFalse(watched.resolvedInheritance.outputLocation, "General's save location must not override it")
        let resolved = EffectivePresetResolver.resolve(preset: watched)
        XCTAssertEqual(resolved.outputDirectoryPolicy.value, .sourceSubfolder(subfolderName: "Converted"))
    }
}
