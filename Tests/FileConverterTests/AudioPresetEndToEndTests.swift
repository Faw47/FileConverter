import XCTest
@testable import FileConverterCore
@testable import FileConverterExternalBackends

final class AudioPresetEndToEndTests: XCTestCase {

    private func findExecutable(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func probeAudioFile(at url: URL, ffprobePath: String) throws -> (codec: String, sampleRate: Int, channels: Int, format: String, duration: Double) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=format_name,duration:stream=codec_name,sample_rate,channels",
            "-of", "json",
            url.path
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            XCTFail("ffprobe failed with exit code \(process.terminationStatus)")
            throw NSError(domain: "ffprobe", code: Int(process.terminationStatus))
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]],
              let firstStream = streams.first,
              let formatDict = json["format"] as? [String: Any] else {
            XCTFail("Could not parse ffprobe output: \(String(data: data, encoding: .utf8) ?? "")")
            throw NSError(domain: "ffprobe", code: -1)
        }

        let codec = firstStream["codec_name"] as? String ?? ""
        let sampleRate = Int(firstStream["sample_rate"] as? String ?? "") ?? 0
        let channels = firstStream["channels"] as? Int ?? 0
        let formatName = formatDict["format_name"] as? String ?? ""
        let duration = Double(formatDict["duration"] as? String ?? "") ?? 0.0

        return (codec, sampleRate, channels, formatName, duration)
    }

    func testPCM16kHzMono16Bit15MinSegmentsExportImportConvertAndProbe() async throws {
        guard let ffmpegPath = findExecutable("ffmpeg"),
              let ffprobePath = findExecutable("ffprobe") else {
            throw XCTSkip("ffmpeg or ffprobe not installed on this system")
        }

        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("E2ETest-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        // 1. Generate synthetic source audio: 930 seconds (15 minutes 30 seconds), 44.1 kHz, stereo
        let sourceURL = tempDir.appendingPathComponent("source_44k_stereo.wav")
        let genProcess = Process()
        genProcess.executableURL = URL(fileURLWithPath: ffmpegPath)
        genProcess.arguments = [
            "-f", "lavfi",
            "-i", "sine=frequency=1000:duration=930:sample_rate=44100",
            "-ac", "2",
            "-c:a", "pcm_s16le",
            sourceURL.path,
            "-y"
        ]
        try genProcess.run()
        genProcess.waitUntilExit()
        XCTAssertEqual(genProcess.terminationStatus, 0, "Failed to generate synthetic source audio")

        // 2. Define the preset: PCM WAV, 16 kHz, mono, 16-bit, 15-minute segments
        var originalPreset = ConversionPreset(
            id: UUID(),
            name: "Transcription 16k Mono",
            menuName: "Transcription WAV",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "wav",
            backend: .ffmpeg,
            audioCodec: .wav,
            quality: .high,
            audioSampleRate: 16_000,
            audioChannels: 1,
            audioBitDepth: .bit16
        )
        originalPreset.audioSplitDurationSeconds = 900 // 15 minutes = 900s

        // 3. Export preset to JSON
        let exportedData = try PresetExchange.exportSingle(preset: originalPreset)
        guard let jsonString = String(data: exportedData, encoding: .utf8) else {
            XCTFail("Exported data could not be converted to string")
            return
        }

        // Verify JSON contents adhere to canonical exchange schema
        XCTAssertTrue(jsonString.contains("\"schemaVersion\" : 1"))
        XCTAssertTrue(jsonString.contains("\"minCompatibleVersion\" : 1"))
        XCTAssertTrue(jsonString.contains("\"audioCodec\" : \"pcm_s16le\""))
        XCTAssertTrue(jsonString.contains("\"pcmBitDepth\" : \"16\""))
        XCTAssertTrue(jsonString.contains("\"sampleRate\" : 16000"))
        XCTAssertTrue(jsonString.contains("\"channels\" : 1"))
        XCTAssertTrue(jsonString.contains("\"partLength\" : \"00:15:00.00\""))

        // 4. Import preset into an isolated PresetStore
        let storeFile = tempDir.appendingPathComponent("presets.json")
        let store = PresetStore(storageURL: storeFile, postsDarwinNotifications: false)
        try store.importPresetsJSON(exportedData)

        guard let importedPreset = store.presets.first(where: { $0.id == originalPreset.id }) else {
            XCTFail("Imported preset not found in store")
            return
        }
        XCTAssertEqual(importedPreset.audioCodec, AudioCodecType.wav)
        XCTAssertEqual(importedPreset.audioBitDepth, AudioBitDepth.bit16)
        XCTAssertEqual(importedPreset.audioSampleRate, 16_000)
        XCTAssertEqual(importedPreset.audioChannels, 1)
        XCTAssertEqual(importedPreset.audioSplitDurationSeconds, 900)

        // 5. Run conversion using FFmpegBackend
        let backend = FFmpegBackend()

        var job = ConversionJob(
            sourceURL: sourceURL,
            preset: importedPreset
        )

        let requirements = try await backend.outputRequirements(for: job)
        // 930 seconds split into 900 second chunks -> 2 parts
        XCTAssertEqual(requirements.count, 2)

        let outPart1 = tempDir.appendingPathComponent("output-part-1.wav")
        let outPart2 = tempDir.appendingPathComponent("output-part-2.wav")
        let outputs = [
            PlannedConversionOutput(finalURL: outPart1, temporaryURL: outPart1),
            PlannedConversionOutput(finalURL: outPart2, temporaryURL: outPart2)
        ]

        job.plannedOutputs = outputs
        let _ = try await backend.convert(job: job, outputs: outputs, progressHandler: { _ in })

        XCTAssertTrue(fileManager.fileExists(atPath: outPart1.path), "Output part 1 file must exist")
        XCTAssertTrue(fileManager.fileExists(atPath: outPart2.path), "Output part 2 file must exist")

        // 6. Verify with ffprobe
        let probe1 = try probeAudioFile(at: outPart1, ffprobePath: ffprobePath)
        XCTAssertEqual(probe1.codec, "pcm_s16le", "Part 1 codec must be pcm_s16le")
        XCTAssertEqual(probe1.sampleRate, 16_000, "Part 1 sample rate must be 16,000 Hz")
        XCTAssertEqual(probe1.channels, 1, "Part 1 channels must be 1 (mono)")
        XCTAssertTrue(probe1.format.contains("wav"), "Part 1 format must be wav")
        XCTAssertEqual(probe1.duration, 900.0, accuracy: 1.0, "Part 1 duration must be approximately 900s (15 min)")

        let probe2 = try probeAudioFile(at: outPart2, ffprobePath: ffprobePath)
        XCTAssertEqual(probe2.codec, "pcm_s16le", "Part 2 codec must be pcm_s16le")
        XCTAssertEqual(probe2.sampleRate, 16_000, "Part 2 sample rate must be 16,000 Hz")
        XCTAssertEqual(probe2.channels, 1, "Part 2 channels must be 1 (mono)")
        XCTAssertTrue(probe2.format.contains("wav"), "Part 2 format must be wav")
        XCTAssertEqual(probe2.duration, 30.0, accuracy: 1.0, "Part 2 duration must be approximately 30s (remainder)")
    }

    func testQTAFixtureAAC48kStereoToPCM16kMono15MinSegmentsExportImportConvertAndProbe() async throws {
        guard let ffmpegPath = findExecutable("ffmpeg"),
              let ffprobePath = findExecutable("ffprobe") else {
            throw XCTSkip("ffmpeg or ffprobe not installed on this system")
        }

        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("E2EQTATest-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        // 1. Generate synthetic .qta fixture containing AAC audio at 48 kHz stereo (930 seconds = 15m 30s)
        let qtaURL = tempDir.appendingPathComponent("fixture.qta")
        let genProcess = Process()
        genProcess.executableURL = URL(fileURLWithPath: ffmpegPath)
        genProcess.arguments = [
            "-f", "lavfi",
            "-i", "sine=frequency=1000:duration=930:sample_rate=48000",
            "-c:a", "aac",
            "-ac", "2",
            "-f", "mov",
            qtaURL.path,
            "-y"
        ]
        try genProcess.run()
        genProcess.waitUntilExit()
        XCTAssertEqual(genProcess.terminationStatus, 0, "Failed to generate .qta audio fixture")

        // 2. Validate input fixture with ffprobe
        let inputProbe = try probeAudioFile(at: qtaURL, ffprobePath: ffprobePath)
        XCTAssertEqual(inputProbe.codec, "aac", "Source audio codec must be AAC")
        XCTAssertEqual(inputProbe.sampleRate, 48_000, "Source sample rate must be 48,000 Hz")
        XCTAssertEqual(inputProbe.channels, 2, "Source channels must be 2 (stereo)")
        XCTAssertEqual(qtaURL.pathExtension.lowercased(), "qta")

        // 3. Configure preset: PCM WAV, 16-bit, 16 kHz, mono, 15-minute splitting
        var originalPreset = ConversionPreset(
            id: UUID(),
            name: "Transcription 16k Mono From QTA",
            menuName: "Transcribe QTA",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "wav",
            backend: .ffmpeg,
            audioCodec: .wav,
            quality: .high,
            audioSampleRate: 16_000,
            audioChannels: 1,
            audioBitDepth: .bit16
        )
        originalPreset.audioSplitDurationSeconds = 900 // 15 minutes = 900s

        // 4. Export preset to JSON and verify canonical exchange format
        let exportedData = try PresetExchange.exportSingle(preset: originalPreset)
        guard let jsonString = String(data: exportedData, encoding: .utf8) else {
            XCTFail("Exported data could not be converted to string")
            return
        }
        XCTAssertTrue(jsonString.contains("\"schemaVersion\" : 1"))
        XCTAssertTrue(jsonString.contains("\"minCompatibleVersion\" : 1"))
        XCTAssertTrue(jsonString.contains("\"audioCodec\" : \"pcm_s16le\""))
        XCTAssertTrue(jsonString.contains("\"pcmBitDepth\" : \"16\""))
        XCTAssertTrue(jsonString.contains("\"sampleRate\" : 16000"))
        XCTAssertTrue(jsonString.contains("\"channels\" : 1"))
        XCTAssertTrue(jsonString.contains("\"partLength\" : \"00:15:00.00\""))

        // 5. Import preset into an isolated PresetStore
        let storeFile = tempDir.appendingPathComponent("presets.json")
        let store = PresetStore(storageURL: storeFile, postsDarwinNotifications: false)
        try store.importPresetsJSON(exportedData)

        guard let importedPreset = store.presets.first(where: { $0.id == originalPreset.id }) else {
            XCTFail("Imported preset not found in store")
            return
        }
        XCTAssertEqual(importedPreset.audioCodec, AudioCodecType.wav)
        XCTAssertEqual(importedPreset.audioBitDepth, AudioBitDepth.bit16)
        XCTAssertEqual(importedPreset.audioSampleRate, 16_000)
        XCTAssertEqual(importedPreset.audioChannels, 1)
        XCTAssertEqual(importedPreset.audioSplitDurationSeconds, 900)

        // 6. Convert the .qta file using FFmpegBackend
        let backend = FFmpegBackend()
        var job = ConversionJob(
            sourceURL: qtaURL,
            preset: importedPreset
        )

        let requirements = try await backend.outputRequirements(for: job)
        // 930 seconds split into 900 second chunks -> 2 parts
        XCTAssertEqual(requirements.count, 2)

        let outPart1 = tempDir.appendingPathComponent("qta-output-part-1.wav")
        let outPart2 = tempDir.appendingPathComponent("qta-output-part-2.wav")
        let outputs = [
            PlannedConversionOutput(finalURL: outPart1, temporaryURL: outPart1),
            PlannedConversionOutput(finalURL: outPart2, temporaryURL: outPart2)
        ]

        job.plannedOutputs = outputs
        let _ = try await backend.convert(job: job, outputs: outputs, progressHandler: { _ in })

        XCTAssertTrue(fileManager.fileExists(atPath: outPart1.path), "Output part 1 file must exist")
        XCTAssertTrue(fileManager.fileExists(atPath: outPart2.path), "Output part 2 file must exist")

        // 7. Validate every output part with ffprobe
        let probe1 = try probeAudioFile(at: outPart1, ffprobePath: ffprobePath)
        XCTAssertEqual(probe1.codec, "pcm_s16le", "Part 1 codec must be pcm_s16le")
        XCTAssertEqual(probe1.sampleRate, 16_000, "Part 1 sample rate must be 16,000 Hz")
        XCTAssertEqual(probe1.channels, 1, "Part 1 channels must be 1 (mono)")
        XCTAssertTrue(probe1.format.contains("wav"), "Part 1 format must be wav")
        XCTAssertEqual(probe1.duration, 900.0, accuracy: 1.0, "Part 1 duration must be ~900s")

        let probe2 = try probeAudioFile(at: outPart2, ffprobePath: ffprobePath)
        XCTAssertEqual(probe2.codec, "pcm_s16le", "Part 2 codec must be pcm_s16le")
        XCTAssertEqual(probe2.sampleRate, 16_000, "Part 2 sample rate must be 16,000 Hz")
        XCTAssertEqual(probe2.channels, 1, "Part 2 channels must be 1 (mono)")
        XCTAssertTrue(probe2.format.contains("wav"), "Part 2 format must be wav")
        XCTAssertEqual(probe2.duration, 30.0, accuracy: 1.0, "Part 2 duration must be ~30s")
    }
}
