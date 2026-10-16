import XCTest
@testable import FileConverterCore
import FileConverterContracts
import FileConverterNativeBackends

final class FinderMenuRelevanceTests: XCTestCase {
    private func format(_ id: String) throws -> FormatDefinition {
        try XCTUnwrap(FormatRegistry.shared.format(forID: id), "missing format \(id)")
    }

    func testDocumentsOnlyConvertWithinTheirKindOrToPDF() throws {
        let docx = try format("docx"), xlsx = try format("xlsx"), pdf = try format("pdf")
        XCTAssertTrue(PresetVisibility.isSensible(try BackendHarness.builtIn("document.txt"), for: docx))
        XCTAssertTrue(PresetVisibility.isSensible(try BackendHarness.builtIn("document.pdf"), for: docx))
        XCTAssertFalse(PresetVisibility.isSensible(try BackendHarness.builtIn("document.xlsx"), for: docx))
        XCTAssertFalse(PresetVisibility.isSensible(try BackendHarness.builtIn("document.pptx"), for: xlsx))
        XCTAssertTrue(PresetVisibility.isSensible(try BackendHarness.builtIn("document.csv"), for: xlsx))
        XCTAssertFalse(PresetVisibility.isSensible(try BackendHarness.builtIn("document.docx"), for: pdf),
                       "a PDF does not become a useful Word file")
    }

    func testPDFWorkflowsOnlyForPDFs() throws {
        let compress = try BackendHarness.builtIn("document.pdf-compressed")
        XCTAssertTrue(PresetVisibility.isSensible(compress, for: try format("pdf")))
        XCTAssertFalse(PresetVisibility.isSensible(compress, for: try format("docx")))
    }

    func testAnimatedGIFOnlyFromVideoOrAnimatableImages() throws {
        let gif = try BackendHarness.builtIn("video.animated-gif")
        XCTAssertFalse(PresetVisibility.isSensible(gif, for: try format("jpeg")))
        XCTAssertFalse(PresetVisibility.isSensible(gif, for: try format("heic")))
        XCTAssertTrue(PresetVisibility.isSensible(gif, for: try format("gif")))
        XCTAssertTrue(PresetVisibility.isSensible(gif, for: try format("mov")))
    }

    func testSnapshotMarksUncommonBuiltInsAndKeepsOnlyOfferedRecents() throws {
        let resolver = BackendResolver()
        resolver.configure(backends: NativeBackendCatalog.makeBackends())
        let presets = BuiltInPresets.makeDefaultPresets()
        let mp4 = try BackendHarness.builtIn("video.mp4-balanced")
        let prores = try BackendHarness.builtIn("video.prores-editing")
        let unknown = UUID()

        let snapshot = FinderMenuSnapshotWriter.makeSnapshot(
            presets: presets, resolver: resolver, edition: .native, recentPresetIDs: [unknown, mp4.id]
        )
        XCTAssertEqual(snapshot.recentPresetIDs, [mp4.id], "recents the menu cannot offer are left out")
        XCTAssertEqual(snapshot.presets.first { $0.id == mp4.id }?.isSecondary, false)
        if let record = snapshot.presets.first(where: { $0.id == prores.id }) {
            XCTAssertEqual(record.isSecondary, true)
        }
        XCTAssertNoThrow(try snapshot.validate(expectedEdition: .native))
    }

    func testRevision5RenamesOnlyUntouchedFactoryNames() throws {
        var stored = try BackendHarness.builtIn("video.mov-to-mp4")
        stored.factoryRevision = 4
        stored.name = "QuickTime MOV to MP4"
        stored.menuName = "MOV → MP4"
        let upgraded = BuiltInPresetUpgrades.upgrade(stored)
        XCTAssertEqual(upgraded.menuName, "MP4 – Fast")
        XCTAssertEqual(upgraded.name, "MOV to MP4 (No Re-encoding When Possible)")
        XCTAssertEqual(upgraded.factoryRevision, BuiltInPresetUpgrades.currentRevision)

        var edited = stored
        edited.menuName = "My Rewrap"
        XCTAssertEqual(BuiltInPresetUpgrades.upgrade(edited).menuName, "My Rewrap", "user edits are kept")
    }
}
