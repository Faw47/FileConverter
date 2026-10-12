import XCTest
import Foundation
@testable import FileConverterCore
@testable import FileConverterContracts
@testable import FileConverterExternalBackends

final class PresetCorruptionAndRecoveryTests: XCTestCase {

    private func makeIsolatedDirectory() throws -> (URL, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CorruptionTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("presets.json")
        return (fileURL, tempDir)
    }

    // MARK: - TASK-007 / REQ-001: Availability States & Byte-for-Byte Preservation

    func testPresetStoreInitialLoadingAndReadyState() throws {
        let (fileURL, tempDir) = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = PresetStore(storageURL: fileURL, postsDarwinNotifications: false)
        XCTAssertTrue(store.state.isReady)
        XCTAssertFalse(store.state.isRecoveryRequired)
        XCTAssertTrue(store.lastSaveSucceeded)
        XCTAssertGreaterThan(store.presets.count, 0)
    }

    func testCorruptJSONEntersRecoveryRequiredStateAndPreservesFileByteForByte() throws {
        let (fileURL, tempDir) = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let corruptContent = "{\"schemaVersion\": 2, \"presets\": [{\"name\": \"broken\", \"invalid\": ]}"
        let corruptData = Data(corruptContent.utf8)
        try corruptData.write(to: fileURL)

        let store = PresetStore(storageURL: fileURL, postsDarwinNotifications: false)

        // Store must fail closed
        XCTAssertTrue(store.state.isRecoveryRequired)
        XCTAssertFalse(store.state.isReady)
        XCTAssertFalse(store.lastSaveSucceeded)
        guard let context = store.state.recoveryContext else {
            XCTFail("Expected recoveryContext to be present")
            return
        }
        XCTAssertFalse(context.errorDescription.isEmpty)
        XCTAssertEqual(context.sourceFileURL.path, fileURL.path)

        // Critical data-safety invariant: Corrupt file must NOT be overwritten
        let dataOnDisk = try Data(contentsOf: fileURL)
        XCTAssertEqual(dataOnDisk, corruptData, "Corrupt presets.json must be preserved byte-for-byte on disk")
    }

    // MARK: - TASK-008 / GUD-005: Mutations Throw & Fail Closed in Recovery State

    func testMutationsAreBlockedDuringRecoveryRequired() throws {
        let (fileURL, tempDir) = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let corruptData = Data("{ NOT VALID JSON }".utf8)
        try corruptData.write(to: fileURL)

        let store = PresetStore(storageURL: fileURL, postsDarwinNotifications: false)
        XCTAssertTrue(store.state.isRecoveryRequired)

        let dummyPreset = ConversionPreset(name: "Test", category: .custom, sourceFormats: ["*"], destinationFormat: "mp4")

        // Every mutating method must throw recoveryRequired
        XCTAssertThrowsError(try store.addPreset(dummyPreset)) { error in
            guard case PresetStoreError.recoveryRequired = error else {
                XCTFail("Expected PresetStoreError.recoveryRequired, got \(error)")
                return
            }
        }

        XCTAssertThrowsError(try store.updatePreset(dummyPreset)) { error in
            guard case PresetStoreError.recoveryRequired = error else {
                XCTFail("Expected PresetStoreError.recoveryRequired, got \(error)")
                return
            }
        }

        XCTAssertThrowsError(try store.deletePreset(withID: dummyPreset.id)) { error in
            guard case PresetStoreError.recoveryRequired = error else {
                XCTFail("Expected PresetStoreError.recoveryRequired, got \(error)")
                return
            }
        }

        XCTAssertThrowsError(try store.duplicatePreset(withID: dummyPreset.id)) { error in
            guard case PresetStoreError.recoveryRequired = error else {
                XCTFail("Expected PresetStoreError.recoveryRequired, got \(error)")
                return
            }
        }

        XCTAssertThrowsError(try store.resetToDefaults()) { error in
            guard case PresetStoreError.recoveryRequired = error else {
                XCTFail("Expected PresetStoreError.recoveryRequired, got \(error)")
                return
            }
        }

        XCTAssertThrowsError(try store.savePresets([dummyPreset])) { error in
            guard case PresetStoreError.recoveryRequired = error else {
                XCTFail("Expected PresetStoreError.recoveryRequired, got \(error)")
                return
            }
        }

        XCTAssertThrowsError(try store.reorderPresets(withIDs: [dummyPreset.id])) { error in
            guard case PresetStoreError.recoveryRequired = error else {
                XCTFail("Expected PresetStoreError.recoveryRequired, got \(error)")
                return
            }
        }

        XCTAssertThrowsError(try store.importPresetsJSON(Data("{}".utf8))) { error in
            guard case PresetStoreError.recoveryRequired = error else {
                XCTFail("Expected PresetStoreError.recoveryRequired, got \(error)")
                return
            }
        }

        // Corrupt file must still be byte-for-byte identical after all mutation attempts
        let dataOnDisk = try Data(contentsOf: fileURL)
        XCTAssertEqual(dataOnDisk, corruptData, "Disk content must not be modified by blocked mutations")
    }

    func testExportDamagedDataReturnsExactBytes() throws {
        let (fileURL, tempDir) = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let corruptContent = "SOME_CORRUPTED_BYTES_HERE_12345"
        let corruptData = Data(corruptContent.utf8)
        try corruptData.write(to: fileURL)

        let store = PresetStore(storageURL: fileURL, postsDarwinNotifications: false)
        XCTAssertTrue(store.state.isRecoveryRequired)

        let exported = try store.exportDamagedData()
        XCTAssertEqual(exported, corruptData)
    }

    // MARK: - TASK-009 / SEC-004: Backup Discovery & Explicit Recovery

    func testBackupCandidatesDiscovery() throws {
        let (fileURL, tempDir) = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a valid backup at backup.1
        let validPresets = BuiltInPresets.makeDefaultPresets()
        let encoder = JSONEncoder()
        struct Doc: Codable { let schemaVersion: Int; let presets: [ConversionPreset] }
        let validData = try encoder.encode(Doc(schemaVersion: 2, presets: validPresets))
        let backup1URL = tempDir.appendingPathComponent("presets.backup.1.json")
        try validData.write(to: backup1URL)

        // Create an invalid backup at backup.2
        let backup2URL = tempDir.appendingPathComponent("presets.backup.2.json")
        try Data("bad json".utf8).write(to: backup2URL)

        // Corrupt primary presets.json
        try Data("corrupt".utf8).write(to: fileURL)

        let store = PresetStore(storageURL: fileURL, postsDarwinNotifications: false)
        XCTAssertTrue(store.state.isRecoveryRequired)

        guard let candidates = store.state.recoveryContext?.backupCandidates else {
            XCTFail("Expected backup candidates in recovery context")
            return
        }

        XCTAssertEqual(candidates.count, 2)
        let candidate1 = candidates.first { $0.backupNumber == 1 }
        XCTAssertNotNil(candidate1)
        XCTAssertTrue(candidate1?.isValid == true)
        XCTAssertGreaterThan(candidate1?.presetCount ?? 0, 0)

        let candidate2 = candidates.first { $0.backupNumber == 2 }
        XCTAssertNotNil(candidate2)
        XCTAssertFalse(candidate2?.isValid == true)
        XCTAssertEqual(candidate2?.presetCount, 0)
    }

    func testRestoreFromValidBackupPreservesDamagedFileAsArchiveAndRestoresState() throws {
        let (fileURL, tempDir) = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fm = FileManager.default

        // Valid backup
        let validPresets = BuiltInPresets.makeDefaultPresets()
        let encoder = JSONEncoder()
        struct Doc: Codable { let schemaVersion: Int; let presets: [ConversionPreset] }
        let validData = try encoder.encode(Doc(schemaVersion: 2, presets: validPresets))
        let backup1URL = tempDir.appendingPathComponent("presets.backup.1.json")
        try validData.write(to: backup1URL)

        // Corrupt primary
        let corruptData = Data("DAMAGED_USER_LIBRARY".utf8)
        try corruptData.write(to: fileURL)

        let store = PresetStore(storageURL: fileURL, postsDarwinNotifications: false)
        XCTAssertTrue(store.state.isRecoveryRequired)

        // Restore from backup
        try store.restoreFromBackup(url: backup1URL)

        // Store is now recovered and ready
        XCTAssertTrue(store.state.isReady)
        XCTAssertGreaterThan(store.presets.count, 0)

        // Damaged file must have been archived to presets.corrupt.<timestamp>.json
        let dirContents = try fm.contentsOfDirectory(atPath: tempDir.path)
        let archivedFiles = dirContents.filter { $0.hasPrefix("presets.corrupt.") }
        XCTAssertEqual(archivedFiles.count, 1, "Damaged file must be preserved in a timestamped archive")
        if let archivedName = archivedFiles.first {
            let archivedData = try Data(contentsOf: tempDir.appendingPathComponent(archivedName))
            XCTAssertEqual(archivedData, corruptData, "Archived file must contain exact damaged bytes")
        }
    }

    func testRestoreFromCorruptBackupFailsWithoutOverwritingPrimary() throws {
        let (fileURL, tempDir) = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let corruptBackupURL = tempDir.appendingPathComponent("presets.backup.1.json")
        try Data("NOT_A_VALID_BACKUP".utf8).write(to: corruptBackupURL)

        let primaryCorruptData = Data("PRIMARY_CORRUPT".utf8)
        try primaryCorruptData.write(to: fileURL)

        let store = PresetStore(storageURL: fileURL, postsDarwinNotifications: false)
        XCTAssertTrue(store.state.isRecoveryRequired)

        XCTAssertThrowsError(try store.restoreFromBackup(url: corruptBackupURL)) { error in
            guard case PresetStoreError.backupCorrupted = error else {
                XCTFail("Expected backupCorrupted, got \(error)")
                return
            }
        }

        // Primary corrupt data must still be preserved
        let currentPrimary = try Data(contentsOf: fileURL)
        XCTAssertEqual(currentPrimary, primaryCorruptData)
    }

    func testStartFreshPreservesDamagedFileAsArchiveAndResetsToDefaults() throws {
        let (fileURL, tempDir) = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fm = FileManager.default
        let damagedData = Data("DAMAGED_DATA_FOR_START_FRESH".utf8)
        try damagedData.write(to: fileURL)

        let store = PresetStore(storageURL: fileURL, postsDarwinNotifications: false)
        XCTAssertTrue(store.state.isRecoveryRequired)

        try store.startFresh()

        XCTAssertTrue(store.state.isReady)
        XCTAssertEqual(store.presets.count, BuiltInPresets.makeDefaultPresets().count)

        // Damaged file must have been archived
        let dirContents = try fm.contentsOfDirectory(atPath: tempDir.path)
        let archivedFiles = dirContents.filter { $0.hasPrefix("presets.corrupt.") }
        XCTAssertEqual(archivedFiles.count, 1)
        if let archivedName = archivedFiles.first {
            let archivedData = try Data(contentsOf: tempDir.appendingPathComponent(archivedName))
            XCTAssertEqual(archivedData, damagedData)
        }
    }

    // MARK: - TASK-010 / TASK-011: Opaque Fields & Backend Options Allowlist

    func testOpaqueFieldsInertRoundTripping() throws {
        let jsonWithOpaque = """
        {
          "schemaVersion": 1,
          "presets": [
            {
              "id": "11111111-2222-3333-4444-555555555555",
              "name": "Forward Compatible Preset",
              "menuName": "Forward",
              "category": "audio",
              "sourceFormats": ["audio"],
              "destinationFormat": "mp3",
              "futureFeatureFlag": true,
              "newMetadata": {
                "tag": "experimental"
              }
            }
          ]
        }
        """

        let imported = try PresetExchange.importPresets(from: Data(jsonWithOpaque.utf8))
        XCTAssertEqual(imported.count, 1)
        let preset = imported[0]

        // Opaque fields captured
        XCTAssertNotNil(preset.opaqueFields)
        XCTAssertNotNil(preset.opaqueFields?["futureFeatureFlag"])
        XCTAssertNotNil(preset.opaqueFields?["newMetadata"])

        // Unknown keys must NOT be placed into extraBackendOptions
        XCTAssertNil(preset.extraBackendOptions["futureFeatureFlag"])
        XCTAssertNil(preset.extraBackendOptions["newMetadata"])
        XCTAssertNil(preset.extraBackendOptions["__unrecognizedJSON"])

        // Round-trip export preserves opaque fields
        let exportedData = try PresetExchange.exportSingle(preset: preset)
        let exportedJSON = try JSONSerialization.jsonObject(with: exportedData) as? [String: Any]
        let exportedPresets = exportedJSON?["presets"] as? [[String: Any]]
        let exportedDict = exportedPresets?.first

        XCTAssertEqual(exportedDict?["futureFeatureFlag"] as? Bool, true)
        let exportedMeta = exportedDict?["newMetadata"] as? [String: Any]
        XCTAssertEqual(exportedMeta?["tag"] as? String, "experimental")
    }

    func testAllowlistedFFmpegOptionValidation() throws {
        var preset = ConversionPreset(
            name: "Allowlist Test",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4"
        )

        // Allowlisted options
        preset.extraBackendOptions = [
            "preset": "slow",
            "tune": "film",
            "crf": "22",
            "threads": "4"
        ]
        let allowlistedErrors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(allowlistedErrors.isEmpty, "Allowlisted options should produce no errors: \(allowlistedErrors)")

        // Prohibited option name
        preset.extraBackendOptions = [
            "arbitrary_flag": "some_value"
        ]
        let prohibitedErrors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(prohibitedErrors.contains { $0.contains("Unsupported backend option 'arbitrary_flag'") })

        // Shell metacharacters injection attempt
        preset.extraBackendOptions = [
            "preset": "slow; rm -rf /"
        ]
        let injectionErrors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(injectionErrors.contains { $0.contains("prohibited shell metacharacters") })

        // Control characters injection attempt
        preset.extraBackendOptions = [
            "preset": "slow\n-i badfile"
        ]
        let controlErrors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(controlErrors.contains { $0.contains("prohibited control characters") })
    }

    // MARK: - TASK-012: Output Container & PDF Compatibility Validation

    func testOutputContainerValidation() {
        var preset = ConversionPreset(
            name: "Container Test",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4"
        )

        preset.container = "mkv"
        XCTAssertTrue(PresetValidator.validationErrors(for: preset).isEmpty)

        preset.container = "nonexistent_container_xyz"
        let errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Unknown output container .nonexistent_container_xyz.") })
    }

    func testPDFCompatibilityLevelValidation() {
        var preset = ConversionPreset(
            name: "PDF Compat Test",
            category: .document,
            sourceFormats: ["pdf"],
            destinationFormat: "pdf"
        )

        preset.processingOptions = ConversionProcessingOptions(pdfCompatibilityLevel: "1.5")
        XCTAssertTrue(PresetValidator.validationErrors(for: preset).isEmpty)

        preset.processingOptions = ConversionProcessingOptions(pdfCompatibilityLevel: "2.0")
        let errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Unsupported PDF compatibility level '2.0'") })
    }

    // MARK: - TASK-013 / SEC-003: Privacy-Preserving Export by Default

    func testPrivacyPreservingExportByDefault() throws {
        let (fileURL, tempDir) = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = PresetStore(storageURL: fileURL, postsDarwinNotifications: false)
        let privatePath = "/Users/secretuser/Desktop/ConfidentialFolder"
        let fakeBookmark = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let customPreset = ConversionPreset(
            id: UUID(),
            name: "Secret Folder Preset",
            menuName: "Secret",
            category: .document,
            sourceFormats: ["pdf"],
            destinationFormat: "pdf",
            outputDirectoryPolicy: .customFolder(bookmarkData: fakeBookmark, displayPath: privatePath)
        )
        try store.addPreset(customPreset)

        // Default export: includeLocalPaths = false
        let defaultExportData = try store.exportPresetJSON(withID: customPreset.id)
        let defaultJSONString = String(decoding: defaultExportData, as: UTF8.self)

        XCTAssertFalse(defaultJSONString.contains("secretuser"), "Default export must NOT contain user home directory paths")
        XCTAssertFalse(defaultJSONString.contains("ConfidentialFolder"), "Default export must NOT contain custom local paths")
        XCTAssertFalse(defaultJSONString.contains(fakeBookmark.base64EncodedString()), "Default export must NOT contain bookmark blobs")
        XCTAssertTrue(defaultJSONString.contains("\"type\" : \"sameAsSource\"") || defaultJSONString.contains("\"type\": \"sameAsSource\""), "Default export should map custom folders to sameAsSource")

        // Explicit export with local paths
        let pathExportData = try store.exportPresetJSON(withID: customPreset.id, includeLocalPaths: true)
        let pathJSONString = String(decoding: pathExportData, as: UTF8.self)
        XCTAssertTrue(pathJSONString.contains("ConfidentialFolder"), "Explicit local export should include the folder path")
    }

    // MARK: - Reviewer Regression Tests (Defects 1 - 11)

    func testPresetValidatorRejectsOptionValueHyphenPrefixAndDoubleHyphenKey() {
        var preset = ConversionPreset(
            name: "Injection Test",
            category: .video,
            sourceFormats: ["mp4"],
            destinationFormat: "mp4"
        )

        // Hyphen-prefixed value (argument injection)
        preset.extraBackendOptions = ["preset": "-b:v 1000k"]
        var errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("value cannot start with a prohibited prefix ('-')") })

        // Double-hyphen option key
        preset.extraBackendOptions = ["--preset": "medium"]
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("contains a prohibited prefix ('--')") })
    }

    func testPresetValidatorEnumAndRangeValidation() {
        var preset = ConversionPreset(
            name: "Enum and Range Test",
            category: .video,
            sourceFormats: ["mp4"],
            destinationFormat: "mp4"
        )

        // Invalid preset enum
        preset.extraBackendOptions = ["preset": "turbocharged"]
        var errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Invalid FFmpeg preset value 'turbocharged'") })

        // Valid preset enum
        preset.extraBackendOptions = ["preset": "medium"]
        XCTAssertTrue(PresetValidator.validationErrors(for: preset).isEmpty)

        // Invalid tune enum
        preset.extraBackendOptions = ["tune": "magic"]
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Invalid FFmpeg tune value 'magic'") })

        // Invalid profile:v
        preset.extraBackendOptions = ["profile:v": "superhigh"]
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Invalid video profile 'superhigh'") })

        // Invalid pix_fmt
        preset.extraBackendOptions = ["pix_fmt": "yuv999p"]
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Invalid pixel format 'yuv999p'") })

        // Invalid movflags
        preset.extraBackendOptions = ["movflags": "arbitrary_flag"]
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Invalid movflags value 'arbitrary_flag'") })

        // CRF range: 0...63
        preset.extraBackendOptions = ["crf": "64"]
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("CRF must be an integer between 0 and 63") })

        preset.extraBackendOptions = ["crf": "not_a_number"]
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("CRF must be a numeric integer value") })

        // Threads range: 0...64
        preset.extraBackendOptions = ["threads": "65"]
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Threads must be an integer between 0 and 64") })

        // fpsmax range: 1...240
        preset.extraBackendOptions = ["fpsmax": "300"]
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("fpsmax must be a number between 1 and 240") })

        // Sample rate ar: 8000...384000
        preset.extraBackendOptions = ["ar": "4000"]
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Audio sample rate (ar) must be between 8000 and 384000 Hz") })

        // Audio channels ac: 1...8
        preset.extraBackendOptions = ["ac": "9"]
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Audio channels (ac) must be between 1 and 8") })

        // Quality scale qscale:v: 0...31
        preset.extraBackendOptions = ["qscale:v": "32"]
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Quality scale 'qscale:v' must be an integer between 0 and 31") })

        // Boolean option vn: must be true, false, 1, 0, or empty
        preset.extraBackendOptions = ["vn": "yes"]
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Boolean option 'vn' must be true, false, 1, 0, or empty") })
    }

    func testBuildFFmpegArgumentsBooleanOptionsHandling() {
        let backend = FFmpegBackend()
        let sourceURL = URL(fileURLWithPath: "/tmp/input.mp4")
        let destURL = URL(fileURLWithPath: "/tmp/output.mp4")

        var preset = ConversionPreset(
            name: "Bool Option Test",
            category: .video,
            sourceFormats: ["mp4"],
            destinationFormat: "mp4"
        )

        // vn = "true", an = "1", sn = "false"
        preset.extraBackendOptions = [
            "vn": "true",
            "an": "1",
            "sn": "false"
        ]

        let args = backend.buildFFmpegArguments(sourceURL: sourceURL, destURL: destURL, preset: preset)

        // -vn and -an should be flags only, without appending "true" or "1"
        XCTAssertTrue(args.contains("-vn"))
        XCTAssertFalse(args.contains("true"))
        XCTAssertTrue(args.contains("-an"))
        XCTAssertFalse(args.contains("1"))
        // sn: "false" should be omitted
        XCTAssertFalse(args.contains("-sn"))
        XCTAssertFalse(args.contains("false"))
    }

    func testFFmpegBackendConvertThrowsOnInvalidOptionAtExecutionBoundary() async {
        let backend = FFmpegBackend()
        let sourceURL = URL(fileURLWithPath: "/tmp/input.mp4")
        let destURL = URL(fileURLWithPath: "/tmp/output.mp4")

        var preset = ConversionPreset(
            name: "Evil Option Preset",
            category: .video,
            sourceFormats: ["mp4"],
            destinationFormat: "mp4"
        )
        // Option starting with hyphen
        preset.extraBackendOptions = ["preset": "-b:v 1000k"]

        let job = ConversionJob(
            sourceURL: sourceURL,
            destinationURL: destURL,
            preset: preset
        )

        do {
            try await backend.convert(job: job) { _ in }
            XCTFail("Execution boundary should throw ConversionError.invalidPreset on injected option value")
        } catch let error as ConversionError {
            guard case .invalidPreset(let reason) = error else {
                XCTFail("Expected ConversionError.invalidPreset, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("hyphen"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Unallowlisted option
        var unallowlistedPreset = ConversionPreset(
            name: "Unallowlisted Preset",
            category: .video,
            sourceFormats: ["mp4"],
            destinationFormat: "mp4"
        )
        unallowlistedPreset.extraBackendOptions = ["filter_complex": "scale=1280:720"]
        let unallowlistedJob = ConversionJob(
            sourceURL: sourceURL,
            destinationURL: destURL,
            preset: unallowlistedPreset
        )
        do {
            try await backend.convert(job: unallowlistedJob) { _ in }
            XCTFail("Execution boundary should throw ConversionError.invalidPreset on unallowlisted option")
        } catch let error as ConversionError {
            guard case .invalidPreset(let reason) = error else {
                XCTFail("Expected ConversionError.invalidPreset, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("Unsupported backend option"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPresetValidatorControlCharactersInAllFields() {
        // Filename pattern with control character
        var preset = ConversionPreset(
            name: "Valid Name",
            category: .document,
            sourceFormats: ["pdf"],
            destinationFormat: "pdf"
        )
        preset.filenamePattern = "output\u{1F}{name}"
        var errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Filename pattern contains prohibited control characters") })

        // Destination format with control character
        preset.filenamePattern = "{name}"
        preset.destinationFormat = "pdf\u{09}"
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Destination format contains prohibited control characters") })

        // Source format with control character
        preset.destinationFormat = "pdf"
        preset.sourceFormats = ["pdf\u{07}"]
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Source format 'pdf\u{07}' contains prohibited control characters") })

        // Output directory subfolder with control character
        preset.sourceFormats = ["pdf"]
        preset.outputDirectoryPolicy = .sourceSubfolder(subfolderName: "sub\u{0A}folder")
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Subfolder name contains prohibited control characters") })

        // Output directory custom folder with control character
        preset.outputDirectoryPolicy = .customFolder(bookmarkData: Data(), displayPath: "/path/\u{00}/test")
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Custom folder path contains prohibited control characters") })

        // Container with control character
        preset.outputDirectoryPolicy = .sameAsSource
        preset.container = "mp4\u{1B}"
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Output container contains prohibited control characters") })

        // PDF options with control characters
        preset.container = nil
        preset.processingOptions = ConversionProcessingOptions(pdfPageRanges: "1-5\u{0D}")
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("PDF page ranges contain prohibited control characters") })
    }

    func testPresetValidatorOutputContainerValidation() {
        var preset = ConversionPreset(
            name: "Container Test",
            category: .audio,
            sourceFormats: ["wav"],
            destinationFormat: "mp3"
        )

        // Unknown container format
        preset.container = "unknown_format_xyz"
        var errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("Unknown output container .unknown_format_xyz") })

        // Input-only container format (e.g. avi)
        preset.container = "avi"
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("is input-only and does not support output") })

        // Incompatible category container (e.g. png for audio destination)
        preset.container = "png"
        errors = PresetValidator.validationErrors(for: preset)
        XCTAssertTrue(errors.contains { $0.contains("is incompatible with destination") })
    }

    func testArchiveCorruptPrimaryFileCollisionResistance() throws {
        let (fileURL, tempDir) = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let corruptContent1 = "{\"schemaVersion\": 2, \"broken\": 1}"
        try Data(corruptContent1.utf8).write(to: fileURL)

        let store = PresetStore(storageURL: fileURL, postsDarwinNotifications: false)
        XCTAssertTrue(store.state.isRecoveryRequired)

        // Create a pre-existing corrupt archive with the expected timestamp
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let baseTimestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let existingArchiveURL = tempDir.appendingPathComponent("presets.corrupt.\(baseTimestamp).json")
        let priorArchiveContent = "{\"prior\": \"archive\"}"
        try Data(priorArchiveContent.utf8).write(to: existingArchiveURL)

        // Now trigger startFresh, which archives the primary file
        try store.startFresh()

        // Verify startFresh created new defaults
        XCTAssertTrue(store.state.isReady)

        // Verify the pre-existing archive was NOT deleted/overwritten
        let preExistingData = try Data(contentsOf: existingArchiveURL)
        XCTAssertEqual(String(decoding: preExistingData, as: UTF8.self), priorArchiveContent)

        // Verify the collision-resistant secondary archive exists
        let collisionArchiveURL = tempDir.appendingPathComponent("presets.corrupt.\(baseTimestamp)-1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: collisionArchiveURL.path), "Collision-resistant archive should be created")
        let collisionData = try Data(contentsOf: collisionArchiveURL)
        XCTAssertEqual(String(decoding: collisionData, as: UTF8.self), corruptContent1)
    }

    func testRestoreFromBackupRejectsPathTraversal() throws {
        let (fileURL, tempDir) = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = PresetStore(storageURL: fileURL, postsDarwinNotifications: false)

        // Backup outside the store directory (path traversal attempt)
        let outsideDir = FileManager.default.temporaryDirectory.appendingPathComponent("Outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }

        let evilBackupURL = outsideDir.appendingPathComponent("presets.backup.traversal.json")
        let validPresetsDoc = "{\"schemaVersion\": 2, \"presets\": []}"
        try Data(validPresetsDoc.utf8).write(to: evilBackupURL)

        XCTAssertThrowsError(try store.restoreFromBackup(url: evilBackupURL)) { error in
            guard case PresetStoreError.backupCorrupted(_, let reason) = error else {
                XCTFail("Expected backupCorrupted error, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("not an authorized File Converter backup"))
        }
    }

    func testPresetStoreDecodesSchemaVersion1DocumentAndRejectsFutureVersions() throws {
        let (fileURL, tempDir) = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Schema version 1 document
        let docV1 = """
        {
            "schemaVersion": 1,
            "presets": [
                {
                    "id": "\(UUID().uuidString)",
                    "name": "V1 Test Preset",
                    "menuName": "V1",
                    "category": "document",
                    "sourceFormats": ["pdf"],
                    "destinationFormat": "pdf",
                    "outputDirectoryPolicy": { "type": "sameAsSource" }
                }
            ]
        }
        """
        try Data(docV1.utf8).write(to: fileURL)

        let storeV1 = PresetStore(storageURL: fileURL, postsDarwinNotifications: false)
        XCTAssertTrue(storeV1.state.isReady, "Schema version 1 should be successfully loaded")
        XCTAssertTrue(storeV1.presets.contains { $0.name == "V1 Test Preset" })

        // Future schema version (> 2) should enter recovery required
        let docV99 = """
        {
            "schemaVersion": 99,
            "presets": []
        }
        """
        try Data(docV99.utf8).write(to: fileURL)

        let storeV99 = PresetStore(storageURL: fileURL, postsDarwinNotifications: false)
        XCTAssertTrue(storeV99.state.isRecoveryRequired, "Future schema version must enter recovery required")
    }

    func testPrivacyPreservingExportFiltersOpaqueFields() throws {
        var preset = ConversionPreset(
            name: "Opaque Privacy Test",
            category: .video,
            sourceFormats: ["mp4"],
            destinationFormat: "mp4"
        )
        preset.opaqueFields = PresetOpaqueFields(fields: [
            "localFolderPath": AnyCodableValue("/Users/secretuser/Movies"),
            "customBookmarkURL": AnyCodableValue("file:///Users/secretuser/private"),
            "nonSensitiveInfo": AnyCodableValue("safeValue")
        ])

        // Default export: includeLocalPaths = false
        let defaultData = try PresetExchange.exportSingle(preset: preset, includeLocalPaths: false)
        let defaultJSON = String(decoding: defaultData, as: UTF8.self)

        XCTAssertFalse(defaultJSON.contains("secretuser"), "Default export must strip local paths in opaque fields")
        XCTAssertFalse(defaultJSON.contains("localFolderPath"), "Default export must strip path keys")
        XCTAssertFalse(defaultJSON.contains("customBookmarkURL"), "Default export must strip URL keys")
        XCTAssertTrue(defaultJSON.contains("nonSensitiveInfo"), "Default export should keep non-sensitive opaque fields")

        // Explicit export: includeLocalPaths = true
        let fullData = try PresetExchange.exportSingle(preset: preset, includeLocalPaths: true)
        let fullJSON = String(decoding: fullData, as: UTF8.self)

        XCTAssertTrue(fullJSON.contains("secretuser"), "Explicit export with local paths should retain opaque paths")
        XCTAssertTrue(fullJSON.contains("localFolderPath"))
    }

    func testRestoreBuiltInThrowsTypedErrorForNonExistentOrCustomPreset() throws {
        let (fileURL, tempDir) = try makeIsolatedDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = PresetStore(storageURL: fileURL, postsDarwinNotifications: false)

        // Non-existent UUID
        XCTAssertThrowsError(try store.restoreBuiltIn(withID: UUID())) { error in
            guard case PresetStoreError.invalidPreset(let reason) = error else {
                XCTFail("Expected invalidPreset error, got \(error)")
                return
            }
            XCTAssertEqual(reason, "Preset not found.")
        }

        // Custom preset (not built-in)
        let customPreset = ConversionPreset(
            name: "Custom Non-BuiltIn",
            category: .custom,
            sourceFormats: ["txt"],
            destinationFormat: "txt"
        )
        try store.addPreset(customPreset)

        XCTAssertThrowsError(try store.restoreBuiltIn(withID: customPreset.id)) { error in
            guard case PresetStoreError.invalidPreset(let reason) = error else {
                XCTFail("Expected invalidPreset error, got \(error)")
                return
            }
            XCTAssertEqual(reason, "Preset is not a restorable built-in preset.")
        }
    }
}
