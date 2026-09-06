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
        XCTAssertTrue(presets.contains { $0.menuName == "1080p MP4" })
        XCTAssertTrue(presets.contains { $0.menuName == "720p MP4" })
        XCTAssertTrue(presets.contains { $0.menuName == "HEVC - Smaller File" })
        XCTAssertTrue(presets.contains { $0.menuName == "MP3 (192k)" })
        XCTAssertTrue(presets.contains { $0.menuName == "WAV (CD Quality)" })
        XCTAssertTrue(presets.contains { $0.menuName == "ICO" })
        XCTAssertTrue(presets.contains { $0.menuName == "WebP Lossless" })
        XCTAssertTrue(presets.contains { $0.menuName == "PDF to PNG" })
        XCTAssertTrue(presets.contains { $0.menuName == "HEIC → JPEG" })
        XCTAssertTrue(presets.contains { $0.menuName == "HEIC → PNG" })
        XCTAssertTrue(presets.contains { $0.menuName == "HEIC → WebP" })
        XCTAssertTrue(presets.contains { $0.menuName == "JPEG → HEIC" })
        XCTAssertTrue(presets.contains { $0.menuName == "PNG → JPEG" })
        XCTAssertTrue(presets.contains { $0.menuName == "RAW → JPEG" })
        XCTAssertTrue(presets.contains { $0.menuName == "PDF to TIFF" })
        XCTAssertTrue(presets.contains { $0.menuName == "WAV → MP3" })
        XCTAssertTrue(presets.contains { $0.menuName == "MKV → MP4" })
        XCTAssertTrue(presets.contains { $0.menuName == "DOCX → PDF" })
        XCTAssertTrue(presets.contains { $0.menuName == "Compress PDF" })
        XCTAssertTrue(presets.contains { $0.menuName == "ODT" })
        XCTAssertTrue(presets.contains { $0.menuName == "ODS" })
        XCTAssertTrue(presets.contains { $0.menuName == "ODP" })
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

    func testSpecialWorkflowPresetsAreValidAndInvalidCombinationsAreRejected() throws {
        let presets = BuiltInPresets.makeDefaultPresets()
        for key in [
            "audio.split-mp3-5min",
            "audio.fit-5mb",
            "document.pdf-split-pages",
            "document.epub-to-pdf"
        ] {
            let preset = try XCTUnwrap(presets.first { $0.builtInKey == key })
            XCTAssertTrue(
                PresetValidator.validationErrors(for: preset).isEmpty,
                "Expected \(key) to be valid"
            )
        }

        var invalidPDFSplit = try XCTUnwrap(presets.first { $0.builtInKey == "document.pdf-split-pages" })
        invalidPDFSplit.destinationFormat = "png"
        XCTAssertTrue(PresetValidator.validationErrors(for: invalidPDFSplit).contains {
            $0.contains("Split PDF pages")
        })

        var invalidAudio = try XCTUnwrap(presets.first { $0.builtInKey == "audio.fit-5mb" })
        invalidAudio.audioSplitDurationSeconds = 60
        XCTAssertTrue(PresetValidator.validationErrors(for: invalidAudio).contains {
            $0.contains("either split audio or a target file size")
        })

        var invalidAudioTarget = try XCTUnwrap(presets.first { $0.builtInKey == "audio.fit-5mb" })
        invalidAudioTarget.destinationFormat = "wav"
        XCTAssertTrue(PresetValidator.validationErrors(for: invalidAudioTarget).contains {
            $0.contains("compressed audio output")
        })

        var mismatchedAudioCodec = try XCTUnwrap(presets.first { $0.builtInKey == "audio.fit-5mb" })
        mismatchedAudioCodec.audioCodec = .mp3
        XCTAssertTrue(PresetValidator.validationErrors(for: mismatchedAudioCodec).contains {
            $0.contains("MP3 size targets must use MP3 output")
        })

        var invalidCalibre = try XCTUnwrap(presets.first { $0.builtInKey == "document.epub-to-pdf" })
        invalidCalibre.sourceFormats = ["document"]
        XCTAssertTrue(PresetValidator.validationErrors(for: invalidCalibre).contains {
            $0.contains("Calibre")
        })

        var invalidEPUBPageSplit = try XCTUnwrap(presets.first { $0.builtInKey == "document.epub-to-pdf" })
        invalidEPUBPageSplit.splitPDFIntoPages = true
        XCTAssertFalse(PresetValidator.canSplitPDFPages(invalidEPUBPageSplit))
        XCTAssertTrue(PresetValidator.validationErrors(for: invalidEPUBPageSplit).contains {
            $0.contains("Split PDF pages requires PDF input and PDF output")
        })
    }

    func testPresetStoreRejectsSemanticallyInvalidImportWithoutReplacingCurrentPresets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InvalidPresetImportTests-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("presets.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = PresetStore(storageURL: storageURL, postsDarwinNotifications: false)
        let originalIDs = Set(store.presets.map(\.id))
        let invalidPreset = ConversionPreset(
            name: "Invalid output",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "not-a-format"
        )

        XCTAssertThrowsError(try store.importPresetsJSON(JSONEncoder().encode([invalidPreset]))) { error in
            guard case PresetStoreError.invalidPreset = error else {
                return XCTFail("Expected semantic preset validation error, got \(error)")
            }
        }
        XCTAssertEqual(Set(store.presets.map(\.id)), originalIDs)
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

    func testExplicitImageRecipesMatchOnlyTheirDeclaredSourceFormats() throws {
        let presets = BuiltInPresets.makeDefaultPresets()
        let heic = try XCTUnwrap(FormatRegistry.shared.format(forID: "heic"))
        let png = try XCTUnwrap(FormatRegistry.shared.format(forID: "png"))
        let jpeg = try XCTUnwrap(FormatRegistry.shared.format(forID: "jpeg"))

        let heicCompatible = presets.filter { PresetValidator.isPresetCompatible($0, forFormat: heic) }
        XCTAssertTrue(heicCompatible.contains { $0.menuName == "HEIC → JPEG" })
        XCTAssertTrue(heicCompatible.contains { $0.menuName == "HEIC → PNG" })
        XCTAssertFalse(heicCompatible.contains { $0.menuName == "PNG → JPEG" })

        let pngCompatible = presets.filter { PresetValidator.isPresetCompatible($0, forFormat: png) }
        XCTAssertTrue(pngCompatible.contains { $0.menuName == "PNG → JPEG" })
        XCTAssertTrue(pngCompatible.contains { $0.menuName == "PNG → HEIC" })
        XCTAssertFalse(pngCompatible.contains { $0.menuName == "HEIC → PNG" })

        let jpegCompatible = presets.filter { PresetValidator.isPresetCompatible($0, forFormat: jpeg) }
        XCTAssertTrue(jpegCompatible.contains { $0.menuName == "JPEG → HEIC" })
        XCTAssertFalse(jpegCompatible.contains { $0.menuName == "HEIC → JPEG" })
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

    func testBuiltInEditsDisableAndRestorePersistAcrossLaunches() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresetPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("presets.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PresetStore(storageURL: storageURL, postsDarwinNotifications: false)
        var edited = try XCTUnwrap(
            store.presets.first { $0.builtInKey == "video.mp4-balanced" }
        )
        edited.name = "My Balanced MP4"
        edited.videoBitrateKbps = 5_500
        store.updatePreset(edited)
        XCTAssertTrue(store.lastSaveSucceeded)

        let reloaded = PresetStore(storageURL: storageURL, postsDarwinNotifications: false)
        let persisted = try XCTUnwrap(reloaded.preset(forID: edited.id))
        XCTAssertEqual(persisted.name, "My Balanced MP4")
        XCTAssertEqual(persisted.videoBitrateKbps, 5_500)

        reloaded.deletePreset(withID: edited.id)
        XCTAssertFalse(try XCTUnwrap(reloaded.preset(forID: edited.id)).isEnabled)

        let disabledReload = PresetStore(storageURL: storageURL, postsDarwinNotifications: false)
        XCTAssertFalse(try XCTUnwrap(disabledReload.preset(forID: edited.id)).isEnabled)
        disabledReload.restoreBuiltIn(withID: edited.id)

        let restored = try XCTUnwrap(disabledReload.preset(forID: edited.id))
        let factory = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "video.mp4-balanced" }
        )
        XCTAssertTrue(restored.isEnabled)
        XCTAssertEqual(restored.name, factory.name)
        XCTAssertEqual(restored.videoBitrateKbps, factory.videoBitrateKbps)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("presets.backup.1.json").path
            )
        )
    }

    func testUnsupportedPresetSchemaIsRejectedWithoutOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresetSchemaTests-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("presets.json")
        let futureDocument = Data(#"{"schemaVersion":999,"presets":[]}"#.utf8)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try futureDocument.write(to: storageURL)

        let store = PresetStore(storageURL: storageURL, postsDarwinNotifications: false)

        XCTAssertNotNil(store.lastErrorDescription)
        XCTAssertEqual(try Data(contentsOf: storageURL), futureDocument)
    }
}
