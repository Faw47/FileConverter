import XCTest
@testable import FileConverterCore

final class PresetEditorStateTests: XCTestCase {
    private let controller = PresetEditorStateController()

    func testCodecChangeToDirectStreamCopyClearsAndDisablesParameters() {
        var preset = ConversionPreset(
            name: "AAC Stream",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "m4a",
            backend: .ffmpeg,
            audioCodec: AudioCodecType.aac,
            quality: QualitySetting.high,
            audioBitrateKbps: 256,
            audioSampleRate: 48000,
            audioChannels: 2,
            audioBitDepth: nil,
            hardwareAcceleration: .auto
        )
        preset.audioTargetFileSizeBytes = 10_000_000

        // Transition to Direct Stream Copy
        controller.setAudioCodec(.copy, in: &preset)

        XCTAssertEqual(preset.audioCodec, AudioCodecType.copy)
        XCTAssertNil(preset.audioBitrateKbps)
        XCTAssertNil(preset.audioTargetFileSizeBytes)
        XCTAssertNil(preset.audioBitDepth)

        XCTAssertTrue(controller.isDirectStreamCopy(preset))
        XCTAssertFalse(controller.shouldShowAudioBitrate(for: preset))
        XCTAssertFalse(controller.shouldShowBitDepth(for: preset))
        XCTAssertFalse(controller.isSampleRateEnabled(for: preset))
        XCTAssertFalse(controller.isChannelsEnabled(for: preset))
        XCTAssertFalse(controller.isQualityEnabled(for: preset))
        XCTAssertFalse(controller.isHardwareAccelerationEnabled(for: preset))
        XCTAssertFalse(controller.isTargetFileSizeEnabled(for: preset))
        XCTAssertEqual(controller.qualitySectionSubtitle(for: preset), "Copied unchanged from the original")
    }

    func testCodecChangeToPCMExposesBitDepthAndDefaultsTo16Bit() {
        var preset = ConversionPreset(
            name: "MP3 to WAV",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "mp3",
            backend: .ffmpeg,
            audioCodec: AudioCodecType.mp3,
            audioBitrateKbps: 320
        )

        controller.setDestinationFormat("wav", in: &preset)

        XCTAssertEqual(preset.destinationFormat, "wav")
        XCTAssertEqual(preset.audioCodec, AudioCodecType.wav)
        XCTAssertEqual(preset.audioBitDepth, AudioBitDepth.bit16)
        XCTAssertNil(preset.audioBitrateKbps)

        XCTAssertTrue(controller.isPCMFormat(preset))
        XCTAssertTrue(controller.shouldShowBitDepth(for: preset))
        XCTAssertFalse(controller.shouldShowAudioBitrate(for: preset))
        XCTAssertTrue(controller.isSampleRateEnabled(for: preset))
        XCTAssertTrue(controller.isChannelsEnabled(for: preset))
    }

    func testCodecChangeToFLACHidesBitrateAndExposesCompressionLevels() {
        var preset = ConversionPreset(
            name: "MP3 to FLAC",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "mp3",
            backend: .ffmpeg,
            audioCodec: AudioCodecType.mp3,
            audioBitrateKbps: 320
        )

        controller.setDestinationFormat("flac", in: &preset)

        XCTAssertEqual(preset.destinationFormat, "flac")
        XCTAssertEqual(preset.audioCodec, AudioCodecType.flac)
        XCTAssertNil(preset.audioBitrateKbps)

        XCTAssertTrue(controller.isFLACFormat(preset))
        XCTAssertFalse(controller.shouldShowAudioBitrate(for: preset))
        XCTAssertFalse(controller.shouldShowBitDepth(for: preset))
        XCTAssertEqual(controller.qualitySectionTitle(for: preset), "Compression level")
        XCTAssertEqual(controller.qualityDisplayName(.low, for: preset), "Fast (level 2)")
        XCTAssertEqual(controller.qualityDisplayName(.medium, for: preset), "Standard (level 5)")
        XCTAssertEqual(controller.qualityDisplayName(.high, for: preset), "Smaller (level 8)")
        XCTAssertEqual(controller.qualityDisplayName(.veryHigh, for: preset), "Smallest (level 12)")
        XCTAssertFalse(controller.availableQualities(for: preset).contains(.lossless))
    }

    func testCodecChangeToNoAudioDisablesAllAudioSettings() {
        var preset = ConversionPreset(
            name: "Video No Audio",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .ffmpeg,
            audioCodec: AudioCodecType.aac,
            audioBitrateKbps: 192
        )

        controller.setAudioCodec(.none, in: &preset)

        XCTAssertTrue(controller.isAudioDisabled(preset))
        XCTAssertFalse(controller.shouldShowAudioBitrate(for: preset))
        XCTAssertFalse(controller.isSampleRateEnabled(for: preset))
        XCTAssertFalse(controller.isChannelsEnabled(for: preset))
    }

    func testQualityLosslessResetsWhenSwitchingToLossyCodec() {
        var preset = ConversionPreset(
            name: "Lossless Test",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "wav",
            backend: .ffmpeg,
            audioCodec: AudioCodecType.wav,
            quality: QualitySetting.lossless
        )

        // Switching to lossy MP3 should reset .lossless to .high
        controller.setAudioCodec(.mp3, in: &preset)
        XCTAssertEqual(preset.quality, QualitySetting.high)

        // Reset to lossless for WAV
        preset.quality = QualitySetting.lossless
        // Switching destination format to lossy container "mp3" should reset .lossless
        controller.setDestinationFormat("mp3", in: &preset)
        XCTAssertEqual(preset.quality, QualitySetting.high)

        // Available qualities for lossy codecs must omit .lossless
        let lossyQualities = controller.availableQualities(for: preset)
        XCTAssertFalse(lossyQualities.contains(.lossless))
    }

    func testPartLengthDurationValidationState() {
        var preset = ConversionPreset(
            name: "Duration Test",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "mp3"
        )

        // 15 minutes
        let err1 = controller.setPartLengthText("00:15:00.00", in: &preset)
        XCTAssertNil(err1)
        XCTAssertEqual(preset.audioSplitDurationSeconds, 900)

        // 1 second (valid minimum)
        let err2 = controller.setPartLengthText("00:00:01.00", in: &preset)
        XCTAssertNil(err2)
        XCTAssertEqual(preset.audioSplitDurationSeconds, 1)

        // 0 seconds (invalid)
        let err3 = controller.setPartLengthText("00:00:00.00", in: &preset)
        XCTAssertNotNil(err3)
        XCTAssertTrue(err3?.contains("at least 1 second") == true)

        // Negative (invalid)
        let err4 = controller.setPartLengthText("-00:05:00.00", in: &preset)
        XCTAssertNotNil(err4)
        XCTAssertTrue(err4?.contains("negative") == true)

        // Malformed
        let err5 = controller.setPartLengthText("not-a-duration", in: &preset)
        XCTAssertNotNil(err5)
    }

    func testPresetConflictResolutionWorkflow() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = PresetStore(storageURL: tempDir.appendingPathComponent("presets.json"), postsDarwinNotifications: false)
        let id = UUID()
        let existing = ConversionPreset(
            id: id,
            name: "Podcast Master",
            menuName: "Podcast",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "mp3",
            backend: .ffmpeg,
            audioCodec: AudioCodecType.mp3,
            audioBitrateKbps: 192
        )
        try store.addPreset(existing)

        let incomingJSON = """
        {
          "schemaVersion": 1,
          "presets": [
            {
              "id": "\(id.uuidString)",
              "name": "Podcast Master",
              "menuName": "Podcast Updated",
              "category": "audio",
              "sourceFormats": ["audio"],
              "destinationFormat": "mp3",
              "conversion": {
                "engine": "ffmpeg",
                "audioCodec": "mp3",
                "audioBitrateKbps": 320
              }
            }
          ]
        }
        """

        let conflicts = try store.detectImportConflicts(in: Data(incomingJSON.utf8))
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.id, id)

        // Resolution: Replace
        try store.importPresetsJSON(Data(incomingJSON.utf8), resolutions: [id: .replace])
        let replaced = store.presets.first(where: { $0.id == id })
        XCTAssertEqual(replaced?.menuName, "Podcast Updated")
        XCTAssertEqual(replaced?.audioBitrateKbps, 320)

        // Resolution: Copy
        let newIncomingJSON = """
        {
          "schemaVersion": 1,
          "presets": [
            {
              "id": "\(id.uuidString)",
              "name": "Podcast Master",
              "menuName": "Podcast Copy",
              "category": "audio",
              "sourceFormats": ["audio"],
              "destinationFormat": "mp3",
              "conversion": {
                "engine": "ffmpeg",
                "audioCodec": "mp3"
              }
            }
          ]
        }
        """
        try store.importPresetsJSON(Data(newIncomingJSON.utf8), resolutions: [id: .copy])
        // Should have 2 custom presets now (original replaced one + copied one)
        let customPresets = store.presets.filter { !$0.isBuiltIn }
        XCTAssertEqual(customPresets.count, 2)
        XCTAssertTrue(customPresets.contains { $0.name.contains("(Copy") })
    }

    func testPresetEditorBindingAndExportImportFidelity() throws {
        var draft = ConversionPreset(
            id: UUID(),
            name: "UI Smoke Preset",
            menuName: "UI Smoke",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "mp3",
            backend: .ffmpeg,
            audioCodec: AudioCodecType.mp3,
            audioBitrateKbps: 320
        )

        // 1. Simulate UI user changing destination to WAV
        controller.setDestinationFormat("wav", in: &draft)
        XCTAssertEqual(draft.destinationFormat, "wav")
        XCTAssertEqual(draft.audioCodec, AudioCodecType.wav)
        XCTAssertEqual(draft.audioBitDepth, AudioBitDepth.bit16)
        XCTAssertNil(draft.audioBitrateKbps)
        XCTAssertTrue(controller.isPCMFormat(draft))
        XCTAssertTrue(controller.shouldShowBitDepth(for: draft))
        XCTAssertFalse(controller.shouldShowAudioBitrate(for: draft))

        // 2. Simulate UI user setting sample rate to 16 kHz and channels to Mono
        draft.audioSampleRate = 16_000
        draft.audioChannels = 1
        XCTAssertTrue(controller.isSampleRateEnabled(for: draft))
        XCTAssertTrue(controller.isChannelsEnabled(for: draft))

        // 3. Simulate UI user typing 00:15:00.00 for part length
        let error = controller.setPartLengthText("00:15:00.00", in: &draft)
        XCTAssertNil(error)
        XCTAssertEqual(draft.audioSplitDurationSeconds, 900)

        // 4. Export the draft directly (matching PresetEditorView's export action)
        let exported = try PresetExchange.exportSingle(preset: draft)
        let jsonStr = String(data: exported, encoding: .utf8)!
        XCTAssertTrue(jsonStr.contains("\"audioCodec\" : \"pcm_s16le\""))
        XCTAssertTrue(jsonStr.contains("\"pcmBitDepth\" : \"16\""))
        XCTAssertTrue(jsonStr.contains("\"sampleRate\" : 16000"))
        XCTAssertTrue(jsonStr.contains("\"channels\" : 1"))
        XCTAssertTrue(jsonStr.contains("\"partLength\" : \"00:15:00.00\""))

        // 5. Import into an isolated store and load back into draft
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SmokeTestStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = PresetStore(storageURL: tempDir.appendingPathComponent("presets.json"), postsDarwinNotifications: false)
        try store.importPresetsJSON(exported)

        let loaded = try XCTUnwrap(store.presets.first(where: { $0.id == draft.id }))
        XCTAssertEqual(loaded.destinationFormat, "wav")
        XCTAssertEqual(loaded.audioCodec, AudioCodecType.wav)
        XCTAssertEqual(loaded.audioBitDepth, AudioBitDepth.bit16)
        XCTAssertEqual(loaded.audioSampleRate, 16_000)
        XCTAssertEqual(loaded.audioChannels, 1)
        XCTAssertEqual(loaded.audioSplitDurationSeconds, 900)

        // 6. Verify state controller queries on loaded preset reflect UI expectations
        XCTAssertTrue(controller.isPCMFormat(loaded))
        XCTAssertTrue(controller.shouldShowBitDepth(for: loaded))
        XCTAssertFalse(controller.shouldShowAudioBitrate(for: loaded))
        XCTAssertTrue(controller.isSampleRateEnabled(for: loaded))
        XCTAssertTrue(controller.isChannelsEnabled(for: loaded))

        // 7. Transition loaded preset to FLAC in UI
        var flacDraft = loaded
        controller.setDestinationFormat("flac", in: &flacDraft)
        XCTAssertTrue(controller.isFLACFormat(flacDraft))
        XCTAssertEqual(controller.qualitySectionTitle(for: flacDraft), "Compression level")
        XCTAssertEqual(controller.availableQualities(for: flacDraft), [.low, .medium, .high, .veryHigh])
        XCTAssertFalse(controller.availableQualities(for: flacDraft).contains(.lossless))
        XCTAssertEqual(controller.qualityDisplayName(.high, for: flacDraft), "Smaller (level 8)")

        // 8. Transition to Direct Stream Copy in UI
        controller.setAudioCodec(.copy, in: &flacDraft)
        XCTAssertTrue(controller.isDirectStreamCopy(flacDraft))
        XCTAssertFalse(controller.isSampleRateEnabled(for: flacDraft))
        XCTAssertFalse(controller.isChannelsEnabled(for: flacDraft))
        XCTAssertFalse(controller.shouldShowAudioBitrate(for: flacDraft))
    }
}
