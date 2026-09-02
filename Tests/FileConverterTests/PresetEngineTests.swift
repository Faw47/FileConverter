import XCTest
@testable import FileConverterCore

final class PresetEngineTests: XCTestCase {
    func testBuiltInPresetsCreation() {
        let presets = BuiltInPresets.makeDefaultPresets()
        XCTAssertGreaterThan(presets.count, 20)

        // Ensure distinct IDs
        let uniqueIDs = Set(presets.map { $0.id })
        XCTAssertEqual(uniqueIDs.count, presets.count)

        // Check key presets exist
        XCTAssertTrue(presets.contains { $0.menuName == "MP4" })
        XCTAssertTrue(presets.contains { $0.menuName == "MP4 - Smaller File" })
        XCTAssertTrue(presets.contains { $0.menuName == "HEVC" })
        XCTAssertTrue(presets.contains { $0.menuName == "ProRes" })
        XCTAssertTrue(presets.contains { $0.menuName == "MP3" })
        XCTAssertTrue(presets.contains { $0.menuName == "AAC" })
        XCTAssertTrue(presets.contains { $0.menuName == "FLAC" })
        XCTAssertTrue(presets.contains { $0.menuName == "PNG" })
        XCTAssertTrue(presets.contains { $0.menuName == "JPEG" })
        XCTAssertTrue(presets.contains { $0.menuName == "HEIC" })
        XCTAssertTrue(presets.contains { $0.menuName == "PDF" })
    }

    func testBuiltInPresetIdentitiesAreStable() {
        let first = BuiltInPresets.makeDefaultPresets()
        let second = BuiltInPresets.makeDefaultPresets()

        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.map(\.builtInKey), second.map(\.builtInKey))
        XCTAssertEqual(Set(first.compactMap(\.builtInKey)).count, first.count)
    }

    func testPresetSerialization() throws {
        let presets = BuiltInPresets.makeDefaultPresets()
        let encoder = JSONEncoder()
        let data = try encoder.encode(presets)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode([ConversionPreset].self, from: data)

        XCTAssertEqual(presets.count, decoded.count)
        XCTAssertEqual(presets.first?.id, decoded.first?.id)
        XCTAssertEqual(presets.first?.name, decoded.first?.name)
    }

    func testCompatibilityFiltering() {
        let presets = BuiltInPresets.makeDefaultPresets()
        guard let pngFormat = FormatRegistry.shared.format(forID: "png"),
              let mkvFormat = FormatRegistry.shared.format(forID: "mkv") else {
            XCTFail("Formats not found")
            return
        }

        // Test single PNG format compatibility
        let pngCompatible = presets.filter { PresetValidator.isPresetCompatible($0, forFormat: pngFormat) }
        XCTAssertTrue(pngCompatible.contains { $0.menuName == "JPEG" })
        XCTAssertTrue(pngCompatible.contains { $0.menuName == "PNG" })
        XCTAssertTrue(pngCompatible.contains { $0.menuName == "HEIC" })
        XCTAssertTrue(pngCompatible.contains { $0.menuName == "PDF" })
        // Video MP4 should NOT be in image conversion
        XCTAssertFalse(pngCompatible.contains { $0.menuName == "MP4" && $0.category == .video })

        // Test single MKV format compatibility
        let mkvCompatible = presets.filter { PresetValidator.isPresetCompatible($0, forFormat: mkvFormat) }
        XCTAssertTrue(mkvCompatible.contains { $0.menuName == "MP4" })
        XCTAssertTrue(mkvCompatible.contains { $0.menuName == "HEVC" })
        XCTAssertTrue(mkvCompatible.contains { $0.menuName == "MP3" }) // Audio extraction
        XCTAssertFalse(mkvCompatible.contains { $0.menuName == "JPEG" })

        // Test QTA audio compatibility
        if let qtaFormat = FormatRegistry.shared.format(forID: "qta") {
            let qtaCompatible = presets.filter { PresetValidator.isPresetCompatible($0, forFormat: qtaFormat) }
            XCTAssertTrue(qtaCompatible.contains { $0.menuName == "MP3" })
            XCTAssertTrue(qtaCompatible.contains { $0.menuName == "AAC" })
            XCTAssertTrue(qtaCompatible.contains { $0.menuName == "FLAC" })
            XCTAssertTrue(qtaCompatible.contains { $0.menuName == "WAV" })
            XCTAssertFalse(qtaCompatible.contains { $0.menuName == "PNG" })
        }
    }

    func testEmptyEnabledPresetListStaysEmpty() {
        let pngURL = URL(fileURLWithPath: "/tmp/example.png")

        XCTAssertTrue(PresetValidator.compatiblePresets(forURLs: [pngURL], from: []).isEmpty)
    }

    func testLegacyBuiltInMigrationPreservesUserStateAndCustomPresets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresetMigrationTests-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("presets.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let defaultPreset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "video.mp4-balanced" }
        )
        var legacyPreset = defaultPreset
        legacyPreset.id = UUID()
        legacyPreset.builtInKey = nil
        legacyPreset.isEnabled = false
        legacyPreset.sortOrder = 777
        legacyPreset.sourceFormats = ["stale-value"]

        let customID = UUID()
        let customPreset = ConversionPreset(
            id: customID,
            name: "My Custom PNG",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "png"
        )

        try JSONEncoder().encode([legacyPreset, customPreset]).write(to: storageURL, options: .atomic)

        let migratedStore = PresetStore(storageURL: storageURL, postsDarwinNotifications: false)
        let migratedPreset = try XCTUnwrap(
            migratedStore.presets.first { $0.builtInKey == "video.mp4-balanced" }
        )
        XCTAssertEqual(migratedPreset.id, defaultPreset.id)
        XCTAssertFalse(migratedPreset.isEnabled)
        XCTAssertEqual(migratedPreset.sortOrder, 777)
        XCTAssertEqual(migratedPreset.sourceFormats, defaultPreset.sourceFormats)
        XCTAssertNotNil(migratedStore.preset(forID: customID))

        let reloadedStore = PresetStore(storageURL: storageURL, postsDarwinNotifications: false)
        let reloadedPreset = try XCTUnwrap(
            reloadedStore.presets.first { $0.builtInKey == "video.mp4-balanced" }
        )
        XCTAssertFalse(reloadedPreset.isEnabled)
        XCTAssertEqual(reloadedPreset.id, defaultPreset.id)
    }

    func testCorruptPresetFileIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresetCorruptionTests-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("presets.json")
        let corruptData = Data("not-json".utf8)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try corruptData.write(to: storageURL)

        let store = PresetStore(storageURL: storageURL, postsDarwinNotifications: false)

        XCTAssertNotNil(store.lastErrorDescription)
        XCTAssertEqual(try Data(contentsOf: storageURL), corruptData)
    }
}
