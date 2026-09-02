import XCTest
import FileConverterContracts
@testable import FileConverterFinderSupport

final class FinderMenuCatalogTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var snapshotURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderMenuCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        snapshotURL = temporaryDirectory.appendingPathComponent(FinderMenuSnapshot.fileName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testCatalogIntersectsPresetsAcrossSelection() throws {
        try writeSnapshot(makeSnapshot())
        let catalog = FinderMenuCatalog(snapshotURL: snapshotURL, expectedEdition: .native)

        let pngSections = catalog.sections(for: [URL(fileURLWithPath: "/tmp/photo.png")])
        XCTAssertEqual(pngSections.map(\.title), ["Image", "Document"])
        XCTAssertEqual(pngSections[0].entries.map(\.title), ["JPEG", "PNG"])

        let mixedSections = catalog.sections(for: [
            URL(fileURLWithPath: "/tmp/photo.png"),
            URL(fileURLWithPath: "/tmp/photo.jpg")
        ])
        XCTAssertEqual(mixedSections.map(\.title), ["Image"])
        XCTAssertEqual(mixedSections[0].entries.map(\.title), ["JPEG"])
    }

    func testCatalogRejectsWrongEdition() throws {
        try writeSnapshot(makeSnapshot())

        let catalog = FinderMenuCatalog(snapshotURL: snapshotURL, expectedEdition: .extended)

        XCTAssertFalse(catalog.hasUsableSnapshot)
        XCTAssertTrue(catalog.sections(for: [URL(fileURLWithPath: "/tmp/photo.png")]).isEmpty)
        XCTAssertNotNil(catalog.lastErrorDescription)
    }

    func testCorruptReloadRetainsLastKnownGoodSnapshot() throws {
        try writeSnapshot(makeSnapshot())
        let catalog = FinderMenuCatalog(snapshotURL: snapshotURL, expectedEdition: .native)
        let before = catalog.sections(for: [URL(fileURLWithPath: "/tmp/photo.png")])

        try Data("not-json".utf8).write(to: snapshotURL, options: .atomic)
        catalog.reload()

        XCTAssertEqual(catalog.sections(for: [URL(fileURLWithPath: "/tmp/photo.png")]), before)
        XCTAssertNotNil(catalog.lastErrorDescription)
    }

    func testDirectorySelectionHasNoMenuEntries() throws {
        try writeSnapshot(makeSnapshot())
        let catalog = FinderMenuCatalog(snapshotURL: snapshotURL, expectedEdition: .native)

        XCTAssertTrue(catalog.sections(for: [temporaryDirectory]).isEmpty)
    }

    func testOversizedReloadRetainsLastKnownGoodSnapshot() throws {
        try writeSnapshot(makeSnapshot())
        let catalog = FinderMenuCatalog(snapshotURL: snapshotURL, expectedEdition: .native)
        let before = catalog.sections(for: [URL(fileURLWithPath: "/tmp/photo.png")])

        try Data(repeating: 0, count: FinderMenuSnapshot.maximumFileSize + 1)
            .write(to: snapshotURL, options: .atomic)
        catalog.reload()

        XCTAssertEqual(catalog.sections(for: [URL(fileURLWithPath: "/tmp/photo.png")]), before)
        XCTAssertNotNil(catalog.lastErrorDescription)
    }

    func testSnapshotValidationRejectsDuplicateAliases() throws {
        let snapshot = FinderMenuSnapshot(
            edition: .native,
            formats: [
                FinderInputFormatRecord(
                    id: "first",
                    extensions: ["duplicate"],
                    utTypeIdentifiers: ["public.first"]
                ),
                FinderInputFormatRecord(
                    id: "second",
                    extensions: ["DUPLICATE"],
                    utTypeIdentifiers: ["public.second"]
                )
            ],
            presets: []
        )

        XCTAssertThrowsError(try snapshot.validate(expectedEdition: .native)) { error in
            XCTAssertEqual(error as? FinderMenuSnapshotError, .duplicateFormatAlias)
        }
    }

    private func writeSnapshot(_ snapshot: FinderMenuSnapshot) throws {
        try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
    }

    private func makeSnapshot() -> FinderMenuSnapshot {
        FinderMenuSnapshot(
            edition: .native,
            formats: [
                FinderInputFormatRecord(
                    id: "png",
                    extensions: ["png"],
                    utTypeIdentifiers: ["public.png"]
                ),
                FinderInputFormatRecord(
                    id: "jpeg",
                    extensions: ["jpg", "jpeg"],
                    utTypeIdentifiers: ["public.jpeg"]
                )
            ],
            presets: [
                FinderPresetRecord(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    title: "JPEG",
                    sectionIdentifier: "image",
                    sectionTitle: "Image",
                    sectionOrder: 0,
                    sortOrder: 0,
                    compatibleFormatIDs: ["png", "jpeg"]
                ),
                FinderPresetRecord(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                    title: "PNG",
                    sectionIdentifier: "image",
                    sectionTitle: "Image",
                    sectionOrder: 0,
                    sortOrder: 10,
                    compatibleFormatIDs: ["png"]
                ),
                FinderPresetRecord(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                    title: "PDF",
                    sectionIdentifier: "document",
                    sectionTitle: "Document",
                    sectionOrder: 1,
                    sortOrder: 20,
                    compatibleFormatIDs: ["png"]
                )
            ]
        )
    }
}
