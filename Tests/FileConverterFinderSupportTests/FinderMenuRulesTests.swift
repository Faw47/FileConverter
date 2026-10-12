import XCTest
import FileConverterContracts
@testable import FileConverterFinderSupport

final class FinderMenuRulesTests: XCTestCase {
    private var directory: URL!
    private var snapshotURL: URL!

    private let mp4ID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let mp3ID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    private let jpegID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinderMenuRules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        snapshotURL = directory.appendingPathComponent(FinderMenuSnapshot.fileName)
        let snapshot = FinderMenuSnapshot(
            edition: .native,
            formats: [
                FinderInputFormatRecord(id: "mov", extensions: ["mov"], utTypeIdentifiers: ["com.apple.quicktime-movie"], category: "video"),
                FinderInputFormatRecord(id: "png", extensions: ["png"], utTypeIdentifiers: ["public.png"], category: "image"),
                FinderInputFormatRecord(id: "wav", extensions: ["wav"], utTypeIdentifiers: ["com.microsoft.waveform-audio"], category: "audio")
            ],
            presets: [
                FinderPresetRecord(id: mp4ID, title: "MP4", sectionIdentifier: "video", sectionTitle: "Video", sectionOrder: 0, sortOrder: 0, compatibleFormatIDs: ["mov"]),
                FinderPresetRecord(id: mp3ID, title: "MP3 – 320 kbps", sectionIdentifier: "audio", sectionTitle: "Audio", sectionOrder: 1, sortOrder: 10, compatibleFormatIDs: ["mov", "wav"]),
                FinderPresetRecord(id: jpegID, title: "JPEG", sectionIdentifier: "image", sectionTitle: "Image", sectionOrder: 2, sortOrder: 20, compatibleFormatIDs: ["png"])
            ]
        )
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var catalog: FinderMenuCatalog {
        FinderMenuCatalog(snapshotURL: snapshotURL, expectedEdition: .native)
    }

    func testAudioPresetsOnVideoAreGroupedAsExtractAudio() {
        let sections = catalog.sections(for: [URL(fileURLWithPath: "/tmp/clip.mov")])
        XCTAssertEqual(sections.map(\.title), ["Video", "Extract Audio"])
    }

    func testAudioPresetsOnAudioKeepTheirSection() {
        let sections = catalog.sections(for: [URL(fileURLWithPath: "/tmp/song.wav")])
        XCTAssertEqual(sections.map(\.title), ["Audio"])
    }

    func testPartialSelectionOffersPresetsForSomeFiles() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.png"),
            URL(fileURLWithPath: "/tmp/b.png"),
            URL(fileURLWithPath: "/tmp/song.wav")
        ]
        let titles = catalog.sections(for: urls).flatMap(\.entries).map(\.title)
        XCTAssertTrue(titles.contains("JPEG (2 of 3 files)"), "\(titles)")
        XCTAssertTrue(titles.contains("MP3 – 320 kbps (1 of 3 files)"), "\(titles)")
        XCTAssertEqual(catalog.compatibleURLs(for: jpegID, among: urls).map(\.lastPathComponent), ["a.png", "b.png"])
    }

    func testUnsupportedAndFolderSelectionsGetNoMenu() {
        XCTAssertTrue(catalog.sections(for: [URL(fileURLWithPath: "/tmp/notes.xyz")]).isEmpty)
        XCTAssertTrue(catalog.sections(for: [directory]).isEmpty)
    }

    func testUnknownFilesDoNotHideRecipesForTheRest() {
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/readme.xyz")]
        let titles = catalog.sections(for: urls).flatMap(\.entries).map(\.title)
        XCTAssertEqual(titles, ["JPEG (1 of 2 files)"])
    }

    func testSelectionLimitIsOneThousand() {
        XCTAssertEqual(ConversionRequestLimits.finderSelectionLimit, 1_000)
        let many = (0..<1_000).map { URL(fileURLWithPath: "/tmp/\($0).png") }
        XCTAssertFalse(catalog.sections(for: many).isEmpty)
        let tooMany = (0..<1_001).map { URL(fileURLWithPath: "/tmp/\($0).png") }
        XCTAssertTrue(catalog.sections(for: tooMany).isEmpty)
    }
}
