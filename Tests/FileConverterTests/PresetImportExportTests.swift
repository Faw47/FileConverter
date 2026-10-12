import XCTest
import Foundation
@testable import FileConverterCore

final class PresetImportExportTests: XCTestCase {

    // Helper to create an isolated PresetStore with temporary storage
    private func makeIsolatedStore() throws -> (PresetStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PresetTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("presets.json")
        let store = PresetStore(storageURL: fileURL, postsDarwinNotifications: false)
        return (store, tempDir)
    }

    // MARK: - 1. Single Preset Export and Import

    func testSinglePresetExportAndImport() throws {
        let (store, tempDir) = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let presetID = UUID()
        let preset = ConversionPreset(
            id: presetID,
            name: "Voxtral Voice 48k",
            menuName: "Voxtral",
            category: .audio,
            sourceFormats: ["wav", "aiff", "mp3"],
            destinationFormat: "m4a",
            backend: .ffmpeg,
            audioCodec: .aac,
            quality: .high,
            audioBitrateKbps: 256,
            audioSampleRate: 48_000,
            audioChannels: 1
        )
        try store.addPreset(preset)

        // Export single preset
        let data = try store.exportPresetJSON(withID: presetID)
        let jsonString = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(jsonString.contains("\"schemaVersion\" : 1") || jsonString.contains("\"schemaVersion\": 1"))
        XCTAssertTrue(jsonString.contains("Voxtral Voice 48k"))
        XCTAssertTrue(jsonString.contains("48000"))

        // Clear and re-import
        let (importStore, tempDir2) = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: tempDir2) }

        try importStore.importPresetsJSON(data)
        guard let imported = importStore.presets.first(where: { $0.id == presetID }) else {
            XCTFail("Imported preset not found")
            return
        }
        XCTAssertEqual(imported.name, "Voxtral Voice 48k")
        XCTAssertEqual(imported.audioSampleRate, 48_000)
        XCTAssertEqual(imported.audioChannels, 1)
        XCTAssertEqual(imported.audioCodec, .aac)
        XCTAssertEqual(imported.audioBitrateKbps, 256)
    }

    // MARK: - 2. Full Library Export and Import

    func testFullLibraryExportAndImport() throws {
        let (store, tempDir) = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let p1 = ConversionPreset(
            name: "Custom One",
            menuName: "One",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "mp3",
            backend: .ffmpeg,
            audioCodec: .mp3,
            audioBitrateKbps: 320
        )
        let p2 = ConversionPreset(
            name: "Custom Two",
            menuName: "Two",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .ffmpeg,
            videoCodec: .h264
        )
        try store.addPreset(p1)
        try store.addPreset(p2)

        let allData = try store.exportPresetsJSON()
        let (importStore, tempDir2) = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: tempDir2) }

        try importStore.importPresetsJSON(allData)
        XCTAssertTrue(importStore.presets.contains { $0.id == p1.id })
        XCTAssertTrue(importStore.presets.contains { $0.id == p2.id })
    }

    // MARK: - 3. Malformed JSON Rejection

    func testMalformedJSONRejection() throws {
        let (store, tempDir) = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let malformedData = Data("{ not valid json at all ...".utf8)
        XCTAssertThrowsError(try store.importPresetsJSON(malformedData)) { error in
            let desc = error.localizedDescription
            XCTAssertTrue(desc.contains("malformed") || desc.contains("JSON") || desc.contains("corrupt"))
        }
    }

    // MARK: - 4. Missing Required Fields Rejection

    func testMissingRequiredFieldsRejectionWithExactPresetAndField() throws {
        let (store, tempDir) = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // JSON missing "destinationFormat"
        let missingDestJSON = """
        {
          "schemaVersion": 1,
          "presets": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "name": "Missing Dest Preset",
              "menuName": "No Dest",
              "category": "audio",
              "sourceFormats": ["wav"]
            }
          ]
        }
        """

        XCTAssertThrowsError(try store.importPresetsJSON(Data(missingDestJSON.utf8))) { error in
            guard let exchangeError = error as? PresetExchangeError else {
                XCTFail("Expected PresetExchangeError, got: \(error)")
                return
            }
            if case .missingField(let preset, let field) = exchangeError {
                XCTAssertEqual(preset, "Missing Dest Preset")
                XCTAssertEqual(field, "destinationFormat")
            } else {
                XCTFail("Expected .missingField error, got: \(exchangeError)")
            }
        }
    }

    // MARK: - 5. Invalid Enum Values Rejection

    func testInvalidEnumValuesRejectionWithExactPresetAndField() throws {
        let (store, tempDir) = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // JSON with invalid category "telepathy"
        let invalidCategoryJSON = """
        {
          "schemaVersion": 1,
          "presets": [
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "name": "Mind Reader Preset",
              "menuName": "Telepathy",
              "category": "telepathy",
              "sourceFormats": ["audio"],
              "destinationFormat": "mp3"
            }
          ]
        }
        """

        XCTAssertThrowsError(try store.importPresetsJSON(Data(invalidCategoryJSON.utf8))) { error in
            guard let exchangeError = error as? PresetExchangeError else {
                XCTFail("Expected PresetExchangeError, got: \(error)")
                return
            }
            if case .invalidField(let preset, let field, _) = exchangeError {
                XCTAssertEqual(preset, "Mind Reader Preset")
                XCTAssertEqual(field, "category")
            } else {
                XCTFail("Expected .invalidField error, got: \(exchangeError)")
            }
        }
    }

    // MARK: - 6. Incompatible Codec / Container Rejection on Import

    func testIncompatibleCodecContainerCombinationRejectionOnImport() throws {
        let (store, tempDir) = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // AAC codec inside MP3 container
        let incompatibleJSON = """
        {
          "schemaVersion": 1,
          "presets": [
            {
              "id": "33333333-3333-3333-3333-333333333333",
              "name": "Incompatible Audio",
              "menuName": "Bad Format",
              "category": "audio",
              "sourceFormats": ["audio"],
              "destinationFormat": "mp3",
              "audio": {
                "codec": "aac"
              }
            }
          ]
        }
        """

        XCTAssertThrowsError(try store.importPresetsJSON(Data(incompatibleJSON.utf8))) { error in
            guard let exchangeError = error as? PresetExchangeError else {
                XCTFail("Expected PresetExchangeError, got: \(error)")
                return
            }
            if case .incompatibleConfiguration(let preset, let reason) = exchangeError {
                XCTAssertEqual(preset, "Incompatible Audio")
                XCTAssertTrue(reason.contains("cannot contain audio codec"))
            } else {
                XCTFail("Expected .incompatibleConfiguration error, got: \(exchangeError)")
            }
        }
    }

    // MARK: - 7. Duplicate Preset Conflict Detection and Resolution

    func testDuplicateConflictDetection() throws {
        let (store, tempDir) = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let existingID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let existingPreset = ConversionPreset(
            id: existingID,
            name: "Original Podcast",
            menuName: "Original",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "mp3",
            backend: .ffmpeg,
            audioCodec: .mp3
        )
        try store.addPreset(existingPreset)

        let incomingJSON = """
        {
          "schemaVersion": 1,
          "presets": [
            {
              "id": "44444444-4444-4444-4444-444444444444",
              "name": "Original Podcast",
              "menuName": "Updated",
              "category": "audio",
              "sourceFormats": ["audio"],
              "destinationFormat": "mp3",
              "audio": {
                "codec": "mp3",
                "bitrateKbps": 192
              }
            }
          ]
        }
        """

        let conflicts = try store.detectImportConflicts(in: Data(incomingJSON.utf8))
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.conflictReason, .sameIDAndName)
    }

    func testConflictResolutionReplace() throws {
        let (store, tempDir) = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let id = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let existing = ConversionPreset(
            id: id,
            name: "My Preset",
            menuName: "My",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "mp3",
            backend: .ffmpeg,
            audioCodec: .mp3,
            audioBitrateKbps: 128
        )
        try store.addPreset(existing)

        let incomingJSON = """
        {
          "schemaVersion": 1,
          "presets": [
            {
              "id": "55555555-5555-5555-5555-555555555555",
              "name": "My Preset",
              "menuName": "My Updated",
              "category": "audio",
              "sourceFormats": ["audio"],
              "destinationFormat": "mp3",
              "audio": {
                "codec": "mp3",
                "bitrateKbps": 320
              }
            }
          ]
        }
        """

        try store.importPresetsJSON(Data(incomingJSON.utf8), resolutions: [id: .replace])
        guard let updated = store.presets.first(where: { $0.id == id }) else {
            XCTFail("Preset not found")
            return
        }
        XCTAssertEqual(updated.menuName, "My Updated")
        XCTAssertEqual(updated.audioBitrateKbps, 320)
    }

    func testConflictResolutionCopy() throws {
        let (store, tempDir) = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let id = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let existing = ConversionPreset(
            id: id,
            name: "My Preset",
            menuName: "My",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "mp3",
            backend: .ffmpeg,
            audioCodec: .mp3,
            audioBitrateKbps: 128
        )
        try store.addPreset(existing)

        let incomingJSON = """
        {
          "schemaVersion": 1,
          "presets": [
            {
              "id": "66666666-6666-6666-6666-666666666666",
              "name": "My Preset",
              "menuName": "My",
              "category": "audio",
              "sourceFormats": ["audio"],
              "destinationFormat": "mp3",
              "audio": {
                "codec": "mp3",
                "bitrateKbps": 320
              }
            }
          ]
        }
        """

        try store.importPresetsJSON(Data(incomingJSON.utf8), resolutions: [id: .copy])

        // Original remains untouched
        guard let orig = store.presets.first(where: { $0.id == id }) else {
            XCTFail("Original preset missing")
            return
        }
        XCTAssertEqual(orig.audioBitrateKbps, 128)

        // New copy exists with unique name
        let copy = store.presets.first { $0.name.hasPrefix("My Preset (Copy") }
        XCTAssertNotNil(copy)
        XCTAssertNotEqual(copy?.id, id)
        XCTAssertEqual(copy?.audioBitrateKbps, 320)
    }

    func testConflictResolutionSkip() throws {
        let (store, tempDir) = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let id = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let existing = ConversionPreset(
            id: id,
            name: "Skip Target",
            menuName: "Target",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "mp3",
            backend: .ffmpeg,
            audioCodec: .mp3,
            audioBitrateKbps: 128
        )
        try store.addPreset(existing)

        let incomingJSON = """
        {
          "schemaVersion": 1,
          "presets": [
            {
              "id": "77777777-7777-7777-7777-777777777777",
              "name": "Skip Target",
              "menuName": "Ignored",
              "category": "audio",
              "sourceFormats": ["audio"],
              "destinationFormat": "mp3",
              "audio": {
                "codec": "mp3",
                "bitrateKbps": 320
              }
            }
          ]
        }
        """

        try store.importPresetsJSON(Data(incomingJSON.utf8), resolutions: [id: .skip])
        guard let current = store.presets.first(where: { $0.id == id }) else {
            XCTFail("Preset not found")
            return
        }
        XCTAssertEqual(current.menuName, "Target")
        XCTAssertEqual(current.audioBitrateKbps, 128)
    }

    // MARK: - 8. Schema Migration and Multi-format Compatibility

    func testRejectsFutureExchangeSchemaVersion() throws {
        let (store, tempDir) = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let futureJSON = """
        {
          "schemaVersion": 99,
          "presets": [
            {
              "name": "Future Preset",
              "menuName": "Future",
              "category": "audio",
              "sourceFormats": ["audio"],
              "destinationFormat": "mp3"
            }
          ]
        }
        """

        XCTAssertThrowsError(try store.importPresetsJSON(Data(futureJSON.utf8)))
    }

    func testForwardCompatibleSchemaWithUnknownFieldsPreserved() throws {
        let (store, tempDir) = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let forwardCompatibleJSON = """
        {
          "schemaVersion": 2,
          "minCompatibleVersion": 1,
          "presets": [
            {
              "name": "Forward Compatible Preset",
              "menuName": "Forward",
              "category": "audio",
              "sourceFormats": ["audio"],
              "destinationFormat": "mp3",
              "futureAIModel": "gpt-super-audio",
              "newEnhancementFlag": true
            }
          ]
        }
        """

        try store.importPresetsJSON(Data(forwardCompatibleJSON.utf8))
        guard let imported = store.presets.first(where: { $0.name == "Forward Compatible Preset" }) else {
            XCTFail("Forward compatible preset should have imported successfully")
            return
        }

        // Export it back and verify the unknown fields from future schema were preserved!
        let reExportedData = try store.exportPresetJSON(withID: imported.id)
        guard let jsonString = String(data: reExportedData, encoding: .utf8) else {
            XCTFail("Re-exported JSON could not be decoded as UTF8")
            return
        }
        XCTAssertTrue(jsonString.contains("futureAIModel"), "Unknown field 'futureAIModel' must be preserved")
        XCTAssertTrue(jsonString.contains("gpt-super-audio"), "Value of unknown field must be preserved")
    }

    func testImportPortablePresetWithCustomFolderWithoutBookmark() throws {
        let (store, tempDir) = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let customDirPath = tempDir.appendingPathComponent("MyCustomFolder").path
        try FileManager.default.createDirectory(atPath: customDirPath, withIntermediateDirectories: true)

        let portableJSON = """
        {
          "schemaVersion": 1,
          "presets": [
            {
              "name": "Portable Folder Preset",
              "menuName": "Portable",
              "category": "audio",
              "sourceFormats": ["audio"],
              "destinationFormat": "mp3",
              "output": {
                "container": "mp3",
                "extension": "mp3",
                "directory": {
                  "type": "customFolder",
                  "path": "\(customDirPath)"
                }
              }
            }
          ]
        }
        """

        // Must import without requiring opaque base64 bookmark data
        try store.importPresetsJSON(Data(portableJSON.utf8))
        guard let imported = store.presets.first(where: { $0.name == "Portable Folder Preset" }) else {
            XCTFail("Portable preset should import without bookmark data")
            return
        }

        if case .customFolder(let bookmarkData, let displayPath) = imported.outputDirectoryPolicy {
            XCTAssertEqual(displayPath, customDirPath)
            XCTAssertFalse(bookmarkData.isEmpty, "Should generate fresh local bookmark for accessible folder")
        } else {
            XCTFail("Expected .customFolder, got: \(imported.outputDirectoryPolicy)")
        }
    }

    func testImportPortablePresetWithInaccessibleCustomFolderPreservesPathAndRequiresAuthorization() throws {
        let (store, tempDir) = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let remotePath = "/Volumes/ExternalStorage/ArchivedAudio"
        let portableJSON = """
        {
          "schemaVersion": 1,
          "presets": [
            {
              "name": "External Archive Preset",
              "menuName": "Archive",
              "category": "audio",
              "sourceFormats": ["audio"],
              "destinationFormat": "mp3",
              "output": {
                "container": "mp3",
                "extension": "mp3",
                "directory": {
                  "type": "customFolder",
                  "path": "\(remotePath)"
                }
              }
            }
          ]
        }
        """

        try store.importPresetsJSON(Data(portableJSON.utf8))
        guard let imported = store.presets.first(where: { $0.name == "External Archive Preset" }) else {
            XCTFail("Preset should import")
            return
        }

        // Must preserve the intended path
        if case .customFolder(let bookmarkData, let displayPath) = imported.outputDirectoryPolicy {
            XCTAssertEqual(displayPath, remotePath)
            XCTAssertTrue(bookmarkData.isEmpty)
        } else {
            XCTFail("Expected .customFolder to be preserved, got: \(imported.outputDirectoryPolicy)")
        }

        // Must be placed in a disabled state requiring re-authorization
        XCTAssertFalse(imported.isEnabled, "Preset with inaccessible custom folder must be disabled")
        XCTAssertFalse(imported.outputDirectoryPolicy.isCustomFolderAuthorized)

        // Store must record an import warning informing the user
        XCTAssertNotNil(store.lastImportWarning)
        XCTAssertTrue(store.lastImportWarning?.contains(remotePath) == true)
    }

    // MARK: - 9. Round-Trip Equality

    func testExportImportRoundTripEquality() throws {
        let (store, tempDir) = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var originalPreset = ConversionPreset(
            id: UUID(),
            name: "Voxtral Master WAV",
            menuName: "Voxtral WAV",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "wav",
            backend: .ffmpeg,
            audioCodec: .wav,
            quality: .high,
            audioBitrateKbps: nil,
            audioSampleRate: 96_000,
            audioChannels: 2,
            audioBitDepth: .bit24
        )
        originalPreset.audioSplitDurationSeconds = 180
        try store.addPreset(originalPreset)

        let exportedData = try store.exportPresetJSON(withID: originalPreset.id)

        let (destStore, tempDir2) = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: tempDir2) }

        try destStore.importPresetsJSON(exportedData)
        guard let imported = destStore.presets.first(where: { $0.id == originalPreset.id }) else {
            XCTFail("Imported preset not found")
            return
        }

        XCTAssertEqual(imported.name, originalPreset.name)
        XCTAssertEqual(imported.menuName, originalPreset.menuName)
        XCTAssertEqual(imported.category, originalPreset.category)
        XCTAssertEqual(imported.sourceFormats, originalPreset.sourceFormats)
        XCTAssertEqual(imported.destinationFormat, originalPreset.destinationFormat)
        XCTAssertEqual(imported.backend, originalPreset.backend)
        XCTAssertEqual(imported.quality, originalPreset.quality)
        XCTAssertEqual(imported.audioCodec, originalPreset.audioCodec)
        XCTAssertEqual(imported.audioSampleRate, originalPreset.audioSampleRate)
        XCTAssertEqual(imported.audioChannels, originalPreset.audioChannels)
        XCTAssertEqual(imported.audioBitDepth, originalPreset.audioBitDepth)
        XCTAssertEqual(imported.audioSplitDurationSeconds, originalPreset.audioSplitDurationSeconds)
    }
}
