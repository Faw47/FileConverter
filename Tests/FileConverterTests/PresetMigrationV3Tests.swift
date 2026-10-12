import XCTest
@testable import FileConverterCore

final class PresetMigrationV3Tests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try BackendHarness.makeTempDirectory("MigrationV3")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes a schema-2 document the way the previous version stored it:
    /// no inheritance, no factory revision.
    private func writeV2Document(_ presets: [ConversionPreset]) throws -> URL {
        let url = directory.appendingPathComponent("presets.json")
        var stripped = presets
        for index in stripped.indices {
            stripped[index].inheritance = nil
            stripped[index].factoryRevision = nil
            stripped[index].sameFormatSuffix = nil
        }
        let encoder = JSONEncoder()
        let body = try encoder.encode(stripped)
        var json = "{\"schemaVersion\":2,\"presets\":".data(using: .utf8)!
        json.append(body)
        json.append("}".data(using: .utf8)!)
        try json.write(to: url)
        return url
    }

    func testV2DocumentMigratesWithBehaviorPreservingRules() throws {
        var builtIn = try BackendHarness.builtIn("image.png")
        builtIn.outputDirectoryPolicy = .sourceSubfolder(subfolderName: "Mine")

        let custom = ConversionPreset(
            name: "My Export",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "png",
            preserveCreationDate: true,
            outputDirectoryPolicy: .sameAsSource,
            filenamePattern: "{name}_mine",
            overwritePolicy: .ask
        )
        let url = try writeV2Document(BuiltInPresets.makeDefaultPresets().map {
            $0.builtInKey == "image.png" ? builtIn : $0
        } + [custom])

        let store = PresetStore(storageURL: url, postsDarwinNotifications: false)
        store.loadPresets()

        let migratedBuiltIn = try XCTUnwrap(store.presets.first { $0.builtInKey == "image.png" })
        let builtInFlags = try XCTUnwrap(migratedBuiltIn.inheritance)
        XCTAssertFalse(builtInFlags.outputLocation, "an edited built-in keeps its own folder")
        XCTAssertTrue(builtInFlags.collisionPolicy)
        XCTAssertTrue(builtInFlags.creationDate)

        let migratedCustom = try XCTUnwrap(store.presets.first { $0.name == "My Export" })
        let customFlags = try XCTUnwrap(migratedCustom.inheritance)
        XCTAssertTrue(customFlags.outputLocation, "same-folder was the old 'inherit' sentinel")
        XCTAssertFalse(customFlags.filenamePattern)
        XCTAssertTrue(customFlags.collisionPolicy, "Ask was the old 'inherit' sentinel")
        XCTAssertFalse(customFlags.creationDate)
        XCTAssertEqual(migratedCustom.preserveModificationDate, true, "the old single toggle covered both dates")

        // Saved as schema 3 with a one-time backup of the v2 file.
        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(saved.contains("\"schemaVersion\" : 3"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("presets.v2-backup.json").path))
    }

    func testBuiltInsGainFactoryFieldsWithoutLosingEdits() throws {
        var edited = try BackendHarness.builtIn("image.jpeg-web")
        edited.quality = .low
        let url = try writeV2Document(BuiltInPresets.makeDefaultPresets().map {
            $0.builtInKey == "image.jpeg-web" ? edited : $0
        })
        let store = PresetStore(storageURL: url, postsDarwinNotifications: false)
        store.loadPresets()
        let loaded = try XCTUnwrap(store.presets.first { $0.builtInKey == "image.jpeg-web" })
        XCTAssertEqual(loaded.quality, .low)
        XCTAssertEqual(loaded.sameFormatSuffix, "web")
        XCTAssertEqual(loaded.factoryRevision, BuiltInPresetUpgrades.currentRevision)
    }

    func testNewCustomPresetsGetExplicitInheritanceOnSave() throws {
        let url = directory.appendingPathComponent("presets.json")
        let store = PresetStore(storageURL: url, postsDarwinNotifications: false)
        store.loadPresets()
        try store.addPreset(ConversionPreset(
            name: "Fresh",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "wav"
        ))
        let fresh = try XCTUnwrap(store.presets.first { $0.name == "Fresh" })
        XCTAssertNotNil(fresh.inheritance)
    }

    func testFutureSchemaIsRejected() throws {
        let url = directory.appendingPathComponent("presets.json")
        try "{\"schemaVersion\":4,\"presets\":[]}".write(to: url, atomically: true, encoding: .utf8)
        let store = PresetStore(storageURL: url, postsDarwinNotifications: false)
        store.loadPresets()
        XCTAssertTrue(store.state.isRecoveryRequired)
    }
}
