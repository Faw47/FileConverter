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

final class WatchFolderCatchUpTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CatchUp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Converted/Sub"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func make(_ name: String, created: Date, in dir: URL? = nil) throws {
        let url = (dir ?? folder).appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: created], ofItemAtPath: url.path)
    }

    func testOnlyNewUnconvertedTopLevelFilesAreCaughtUp() throws {
        let checked = Date()
        // Added-to-folder dates are always "now", so judge against a future checkpoint
        // for old files and the past for new ones.
        try make("new.png", created: checked.addingTimeInterval(60))
        try make("done.png", created: checked.addingTimeInterval(60))
        try make("done.jpg", created: checked.addingTimeInterval(60), in: folder.appendingPathComponent("Converted"))
        try make(".hidden.png", created: checked.addingTimeInterval(60))
        try make("deep.png", created: checked.addingTimeInterval(60), in: folder.appendingPathComponent("Converted/Sub"))

        let names = WatchFolder.filesToCatchUp(in: folder, since: checked.addingTimeInterval(-1)).map(\.lastPathComponent)
        XCTAssertEqual(names, ["new.png"])
    }

    func testFilesFromBeforeTheLastCheckAreLeftAlone() throws {
        try make("old.png", created: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(WatchFolder.filesToCatchUp(in: folder, since: Date().addingTimeInterval(60)), [])
    }

    func testLastCheckedRoundTripsAndOldDataStillDecodes() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WatchFolderCatchUp-\(UUID().uuidString)"))
        let old = #"[{"id":"\#(UUID().uuidString)","path":"/tmp/x","presetID":"\#(UUID().uuidString)","isEnabled":true}]"#
        defaults.set(Data(old.utf8), forKey: "fc.watchFolders")
        XCTAssertNil(WatchFolderStore.load(defaults: defaults).first?.lastChecked)
        let date = Date(timeIntervalSince1970: 1_000)
        WatchFolderStore.save([WatchFolder(path: "/tmp/x", presetID: UUID(), lastChecked: date)], defaults: defaults)
        XCTAssertEqual(WatchFolderStore.load(defaults: defaults).first?.lastChecked, date)
    }
}
