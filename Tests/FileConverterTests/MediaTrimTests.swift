import XCTest
@testable import FileConverterCore
@testable import FileConverterExternalBackends
@testable import FileConverterNativeBackends

/// Trimming, saving a video frame, and evening out loudness: the preset
/// fields, their validation, import/export, and what each backend produces.
final class MediaTrimTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try BackendHarness.makeTempDirectory("MediaTrim")
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func format(_ id: String) throws -> FormatDefinition {
        try XCTUnwrap(FormatRegistry.shared.format(forID: id), "missing format \(id)")
    }

    // MARK: - Time text

    func testParsesAndFormatsTimes() {
        XCTAssertEqual(MediaTrim.parseTime("90"), 90)
        XCTAssertEqual(MediaTrim.parseTime("1:30"), 90)
        XCTAssertEqual(MediaTrim.parseTime("1:30.5"), 90.5)
        XCTAssertEqual(MediaTrim.parseTime("1:02:03"), 3_723)
        XCTAssertEqual(MediaTrim.parseTime(" 0:05 "), 5)
        XCTAssertNil(MediaTrim.parseTime(""))
        XCTAssertNil(MediaTrim.parseTime("-5"))
        XCTAssertNil(MediaTrim.parseTime("1:75"))
        XCTAssertNil(MediaTrim.parseTime("1.5:30"))
        XCTAssertNil(MediaTrim.parseTime("abc"))
        XCTAssertNil(MediaTrim.parseTime("1:2:3:4"))

        XCTAssertEqual(MediaTrim.formatTime(0), "0:00")
        XCTAssertEqual(MediaTrim.formatTime(90), "1:30")
        XCTAssertEqual(MediaTrim.formatTime(90.5), "1:30.5")
        XCTAssertEqual(MediaTrim.formatTime(3_723), "1:02:03")
        XCTAssertEqual(MediaTrim.formatTime(59.999), "1:00")
        for seconds in [0, 5, 90.5, 3_723.25] {
            XCTAssertEqual(MediaTrim.parseTime(MediaTrim.formatTime(seconds)), seconds)
        }
    }

    func testKeptDuration() {
        var preset = ConversionPreset(name: "T", category: .video, sourceFormats: ["video"], destinationFormat: "mp4")
        XCTAssertEqual(MediaTrim.keptDuration(totalSeconds: 10, preset: preset), 10)
        preset.trimStartSeconds = 2
        XCTAssertEqual(MediaTrim.keptDuration(totalSeconds: 10, preset: preset), 8)
        preset.trimEndSeconds = 5
        XCTAssertEqual(MediaTrim.keptDuration(totalSeconds: 10, preset: preset), 3)
        preset.trimEndSeconds = 50
        XCTAssertEqual(MediaTrim.keptDuration(totalSeconds: 10, preset: preset), 8, "an end past the file stops at the end")
        preset.trimStartSeconds = 20
        XCTAssertEqual(MediaTrim.keptDuration(totalSeconds: 10, preset: preset), 0)
    }

    // MARK: - Backward compatibility

    func testProcessingOptionsWithoutNewKeysDecodeUnchanged() throws {
        let json = #"{"audioSplitDurationSeconds":300,"splitPDFIntoPages":false,"pdfMergeSplitOutputs":false}"#
        let options = try JSONDecoder().decode(ConversionProcessingOptions.self, from: Data(json.utf8))
        XCTAssertEqual(options.audioSplitDurationSeconds, 300)
        XCTAssertNil(options.trimStartSeconds)
        XCTAssertNil(options.trimEndSeconds)
        XCTAssertNil(options.frameTimeSeconds)
        XCTAssertFalse(options.normalizeLoudness)
        XCTAssertEqual(options, ConversionProcessingOptions(audioSplitDurationSeconds: 300))
    }

    func testStoredPresetsFromBeforeTheseSettingsDecodeUnchanged() throws {
        for preset in BuiltInPresets.makeDefaultPresets() {
            let data = try JSONEncoder().encode(preset)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            // What an older build wrote: no new keys anywhere.
            if var options = object["processingOptions"] as? [String: Any] {
                for key in ["trimStartSeconds", "trimEndSeconds", "frameTimeSeconds", "normalizeLoudness"] {
                    options.removeValue(forKey: key)
                }
                object["processingOptions"] = options
            }
            let old = try JSONSerialization.data(withJSONObject: object)
            let decoded = try JSONDecoder().decode(ConversionPreset.self, from: old)
            XCTAssertEqual(decoded, preset, preset.builtInKey ?? preset.name)
            XCTAssertFalse(decoded.isTrimmed)
            XCTAssertFalse(decoded.normalizeLoudness)
        }
    }

    func testNewSettingsRoundTripThroughStorage() throws {
        var preset = ConversionPreset(name: "Clip", category: .audio, sourceFormats: ["audio"], destinationFormat: "mp3", audioCodec: .mp3)
        preset.trimStartSeconds = 1.5
        preset.trimEndSeconds = 30
        preset.normalizeLoudness = true
        let decoded = try JSONDecoder().decode(ConversionPreset.self, from: JSONEncoder().encode(preset))
        XCTAssertEqual(decoded, preset)
        XCTAssertEqual(decoded.trimStartSeconds, 1.5)
        XCTAssertEqual(decoded.trimEndSeconds, 30)
        XCTAssertTrue(decoded.normalizeLoudness)

        // Clearing every new setting leaves no processing options behind.
        preset.trimStartSeconds = nil
        preset.trimEndSeconds = nil
        preset.normalizeLoudness = false
        XCTAssertNil(preset.processingOptions)
    }

    func testStoredBuiltInsKeepTheirSettingsAfterUpgrade() {
        for factory in BuiltInPresets.makeDefaultPresets() {
            var stored = factory
            stored.factoryRevision = 4
            let upgraded = BuiltInPresetUpgrades.upgrade(stored)
            XCTAssertEqual(upgraded.processingOptions, factory.processingOptions, factory.builtInKey ?? "")
        }
    }

    // MARK: - Import and export

    func testExportWritesMediaSectionOnlyWhenUsed() throws {
        let plain = try BackendHarness.builtIn("audio.mp3-320")
        let plainJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: PresetExchange.exportSingle(preset: plain)) as? [String: Any])
        let plainPreset = try XCTUnwrap((plainJSON["presets"] as? [[String: Any]])?.first)
        XCTAssertNil(plainPreset["media"])

        var trimmed = plain
        trimmed.trimStartSeconds = 10
        trimmed.trimEndSeconds = 70.5
        trimmed.normalizeLoudness = true
        let data = try PresetExchange.exportSingle(preset: trimmed)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"media\""))
        let imported = try XCTUnwrap(PresetExchange.importPresets(from: data).first)
        XCTAssertEqual(imported.trimStartSeconds, 10)
        XCTAssertEqual(imported.trimEndSeconds, 70.5)
        XCTAssertTrue(imported.normalizeLoudness)
        XCTAssertNil(imported.frameTimeSeconds)
    }

    func testImportOfOlderFileHasNoMediaSettings() throws {
        let json = """
        {"schemaVersion": 1, "presets": [{
            "name": "Old MP3", "menuTitle": "Old MP3", "category": "audio", "enabled": true,
            "sources": ["audio"],
            "output": {"extension": "mp3"},
            "conversion": {"backend": "ffmpeg", "audioCodec": "mp3", "quality": "high"},
            "split": {"enabled": false}, "targetFileSize": {"enabled": false}
        }]}
        """
        let imported = try XCTUnwrap(PresetExchange.importPresets(from: Data(json.utf8)).first)
        XCTAssertFalse(imported.isTrimmed)
        XCTAssertNil(imported.frameTimeSeconds)
        XCTAssertFalse(imported.normalizeLoudness)
        XCTAssertNil(imported.processingOptions)
        XCTAssertNil(imported.opaqueFields)
    }

    func testImportRejectsBadMediaSettings() throws {
        let preset = try BackendHarness.builtIn("audio.mp3-320")
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: PresetExchange.exportSingle(preset: preset)) as? [String: Any])

        func importing(_ media: [String: Any]) throws -> [ConversionPreset] {
            var document = base
            var presets = try XCTUnwrap(document["presets"] as? [[String: Any]])
            presets[0]["media"] = media
            document["presets"] = presets
            return try PresetExchange.importPresets(from: JSONSerialization.data(withJSONObject: document))
        }

        XCTAssertThrowsError(try importing(["trimStartSeconds": 10, "trimEndSeconds": 5]))
        XCTAssertThrowsError(try importing(["trimStartSeconds": -1]))
        XCTAssertThrowsError(try importing(["trimEndSeconds": "soon"]))
        XCTAssertThrowsError(try importing(["frameTimeSeconds": true]))
        XCTAssertEqual(try importing(["trimEndSeconds": 1]).first?.trimEndSeconds, 1)
    }

    // MARK: - Validation

    func testValidatorRequiresEndAfterStart() {
        var preset = ConversionPreset(name: "Clip", category: .video, sourceFormats: ["video"], destinationFormat: "mp4", videoCodec: .h264, audioCodec: .aac)
        preset.trimStartSeconds = 10
        preset.trimEndSeconds = 5
        XCTAssertTrue(PresetValidator.validationErrors(for: preset).contains("The end time must be after the start time."))
        preset.trimEndSeconds = 10
        XCTAssertTrue(PresetValidator.validationErrors(for: preset).contains("The end time must be after the start time."))
        preset.trimEndSeconds = 12
        XCTAssertEqual(PresetValidator.validationErrors(for: preset), [])
        preset.trimStartSeconds = -1
        XCTAssertTrue(PresetValidator.validationErrors(for: preset).contains("The start time can't be negative."))
    }

    func testValidatorRejectsMismatchedMediaSettings() throws {
        var image = try BackendHarness.builtIn("image.jpeg")
        image.trimStartSeconds = 1
        XCTAssertTrue(PresetValidator.validationErrors(for: image).contains("Only video and audio presets can trim."))

        var video = try BackendHarness.builtIn("video.mp4-balanced")
        video.normalizeLoudness = true
        XCTAssertTrue(PresetValidator.validationErrors(for: video).contains("Evening out loudness needs an audio preset."))

        var nativeAudio = try BackendHarness.builtIn("audio.aac-256")
        nativeAudio.backend = .avFoundation
        nativeAudio.normalizeLoudness = true
        XCTAssertTrue(PresetValidator.validationErrors(for: nativeAudio).contains { $0.contains("needs FFmpeg") })

        var split = try BackendHarness.builtIn("audio.split-mp3-5min")
        split.trimEndSeconds = 60
        XCTAssertTrue(PresetValidator.validationErrors(for: split).contains("Choose either trimming or splitting into parts, not both."))

        var frame = try BackendHarness.builtIn("video.frame-jpeg")
        frame.trimStartSeconds = 1
        XCTAssertFalse(PresetValidator.validationErrors(for: frame).isEmpty)

        var notFrame = try BackendHarness.builtIn("video.mp4-balanced")
        notFrame.frameTimeSeconds = 2
        XCTAssertTrue(PresetValidator.validationErrors(for: notFrame).contains("A frame time needs a video preset that saves an image."))
    }

    func testBuiltInFramePresetsAreValid() throws {
        for key in ["video.frame-jpeg", "video.frame-png"] {
            var preset = try BackendHarness.builtIn(key)
            XCTAssertTrue(preset.isVideoFrameExport)
            XCTAssertEqual(PresetValidator.validationErrors(for: preset), [], key)
            preset.frameTimeSeconds = 12.5
            XCTAssertEqual(PresetValidator.validationErrors(for: preset), [], key)
        }
        var loud = try BackendHarness.builtIn("audio.mp3-320")
        loud.normalizeLoudness = true
        XCTAssertEqual(PresetValidator.validationErrors(for: loud), [])
    }

    // MARK: - Backend choice

    func testFramePresetsRunNativelyAndLoudnessNeedsFFmpeg() throws {
        let mp4 = try format("mp4")
        let frame = try BackendHarness.builtIn("video.frame-jpeg")
        XCTAssertTrue(AVFoundationBackend().supports(sourceFormat: mp4, destinationFormat: try format("jpg"), preset: frame))
        XCTAssertTrue(AVFoundationBackend().supports(sourceFormat: mp4, destinationFormat: try format("png"), preset: try BackendHarness.builtIn("video.frame-png")))
        XCTAssertFalse(FFmpegBackend(executablePathProvider: { _ in nil }).supports(sourceFormat: mp4, destinationFormat: try format("jpg"), preset: frame))

        var loud = try BackendHarness.builtIn("audio.aac-256")
        loud.normalizeLoudness = true
        XCTAssertFalse(AVFoundationBackend().supports(sourceFormat: try format("wav"), destinationFormat: try format("m4a"), preset: loud))
    }

    // MARK: - FFmpeg arguments

    func testFFmpegSeeksBeforeTheInput() throws {
        var preset = try BackendHarness.builtIn("video.mp4-balanced")
        preset.backend = .ffmpeg
        preset.trimStartSeconds = 1.25
        preset.trimEndSeconds = 4
        let args = FFmpegBackend(executablePathProvider: { _ in nil }).buildFFmpegArguments(
            sourceURL: URL(fileURLWithPath: "/tmp/in.mp4"),
            destURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            preset: preset,
            availableEncoders: ["libx264", "aac"]
        )
        let input = try XCTUnwrap(args.firstIndex(of: "-i"))
        let ss = try XCTUnwrap(args.firstIndex(of: "-ss"))
        let to = try XCTUnwrap(args.firstIndex(of: "-to"))
        XCTAssertLessThan(ss, input)
        XCTAssertLessThan(to, input)
        XCTAssertEqual(args[ss + 1], "1.250")
        XCTAssertEqual(args[to + 1], "4.000")

        preset.trimStartSeconds = nil
        preset.trimEndSeconds = nil
        let untrimmed = FFmpegBackend(executablePathProvider: { _ in nil }).buildFFmpegArguments(
            sourceURL: URL(fileURLWithPath: "/tmp/in.mp4"),
            destURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            preset: preset,
            availableEncoders: ["libx264", "aac"]
        )
        XCTAssertFalse(untrimmed.contains("-ss"))
        XCTAssertFalse(untrimmed.contains("-to"))
    }

    func testFFmpegLoudnessArguments() throws {
        var preset = try BackendHarness.builtIn("audio.mp3-320")
        preset.normalizeLoudness = true
        let backend = FFmpegBackend(executablePathProvider: { _ in nil })
        let args = backend.buildFFmpegArguments(
            sourceURL: URL(fileURLWithPath: "/tmp/in.flac"),
            destURL: URL(fileURLWithPath: "/tmp/out.mp3"),
            preset: preset,
            availableEncoders: ["libmp3lame"],
            sourceInfo: SourceMediaInfo(audioSampleRate: 44_100)
        )
        let filter = try XCTUnwrap(args.firstIndex(of: "-af"))
        XCTAssertEqual(args[filter + 1], "loudnorm=I=-16:TP=-1.5:LRA=11")
        let rate = try XCTUnwrap(args.firstIndex(of: "-ar"))
        XCTAssertEqual(args[rate + 1], "44100", "loudnorm would otherwise write 192 kHz")

        XCTAssertEqual(FFmpegBackend.loudnormOutputSampleRate(sourceRate: 44_100, targetExt: "opus", audioCodec: .auto), 48_000)
        XCTAssertEqual(FFmpegBackend.loudnormOutputSampleRate(sourceRate: 96_000, targetExt: "mp3", audioCodec: .mp3), 48_000)
        XCTAssertEqual(FFmpegBackend.loudnormOutputSampleRate(sourceRate: nil, targetExt: "m4a", audioCodec: .aac), 48_000)
        XCTAssertEqual(FFmpegBackend.loudnormOutputSampleRate(sourceRate: 96_000, targetExt: "flac", audioCodec: .flac), 96_000)

        preset.normalizeLoudness = false
        XCTAssertFalse(backend.buildFFmpegArguments(
            sourceURL: URL(fileURLWithPath: "/tmp/in.flac"),
            destURL: URL(fileURLWithPath: "/tmp/out.mp3"),
            preset: preset,
            availableEncoders: ["libmp3lame"]
        ).contains("-af"))
    }

    // MARK: - Native output

    private func convertNatively(_ fixture: String, _ preset: ConversionPreset) async throws -> (URL, [String]) {
        let source = try TestFixtures.copy(fixture, to: directory)
        let (outputs, result) = try await BackendHarness.convert(
            backend: AVFoundationBackend(), source: source, preset: preset, into: directory,
            baseName: "native-\(UUID().uuidString.prefix(6))"
        )
        return (try XCTUnwrap(outputs.first), result.warnings)
    }

    func testSavesFirstFrameAsJPEG() async throws {
        let (output, warnings) = try await convertNatively("small_640x360_h264.mp4", try BackendHarness.builtIn("video.frame-jpeg"))
        XCTAssertEqual(output.pathExtension, "jpg")
        let info = try ImageAssertions.info(output)
        XCTAssertEqual(info.width, 640)
        XCTAssertEqual(info.height, 360)
        XCTAssertEqual(info.typeIdentifier, "public.jpeg")
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
    }

    func testSavesChosenFrameAsPNGAndKeepsPortrait() async throws {
        var preset = try BackendHarness.builtIn("video.frame-png")
        preset.frameTimeSeconds = 1
        let (output, _) = try await convertNatively("portrait_1080x1920_h264.mov", preset)
        let info = try ImageAssertions.info(output)
        XCTAssertEqual(info.typeIdentifier, "public.png")
        XCTAssertEqual(info.width, 1080)
        XCTAssertEqual(info.height, 1920)
    }

    func testFrameTimePastTheEndSavesTheLastFrameWithAWarning() async throws {
        var preset = try BackendHarness.builtIn("video.frame-jpeg")
        preset.frameTimeSeconds = 60
        let (output, warnings) = try await convertNatively("small_640x360_h264.mp4", preset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(warnings.contains { $0.contains("last frame") }, "\(warnings)")
    }

    func testNativeVideoTrim() async throws {
        var preset = try BackendHarness.builtIn("video.mp4-balanced")
        preset.backend = .avFoundation
        preset.trimStartSeconds = 0.5
        preset.trimEndSeconds = 1.5
        let (output, _) = try await convertNatively("small_640x360_h264.mp4", preset)
        let duration = try XCTUnwrap(try MediaAssertions.probe(output).duration)
        XCTAssertEqual(duration, 1, accuracy: 0.15, "source is 2 s")
    }

    func testNativeStreamCopyTrim() async throws {
        var preset = try BackendHarness.builtIn("video.mov-to-mp4")
        preset.sourceFormats = ["video"]
        preset.trimStartSeconds = 1
        let (output, _) = try await convertNatively("small_640x360_h264.mp4", preset)
        let duration = try XCTUnwrap(try MediaAssertions.probe(output).duration)
        XCTAssertLessThan(duration, 1.6, "source is 2 s")
    }

    func testNativeAudioTrim() async throws {
        var preset = try BackendHarness.builtIn("audio.aac-256")
        preset.backend = .avFoundation
        preset.trimStartSeconds = 1
        preset.trimEndSeconds = 2.5
        let (output, _) = try await convertNatively("noise_48k_stereo.wav", preset)
        let duration = try XCTUnwrap(try MediaAssertions.probe(output).duration)
        XCTAssertEqual(duration, 1.5, accuracy: 0.1, "source is 4 s")
    }

    func testNativeTrimStartingAfterTheEndFails() async throws {
        var preset = try BackendHarness.builtIn("audio.wav-pcm")
        preset.backend = .avFoundation
        preset.trimStartSeconds = 30
        do {
            _ = try await convertNatively("noise_48k_stereo.wav", preset)
            XCTFail("a start time after the end should fail")
        } catch ConversionError.invalidPreset(let reason) {
            XCTAssertTrue(reason.contains("after the end of this file"), reason)
        }
    }

    // MARK: - FFmpeg output

    private func convertWithFFmpeg(_ fixture: String, _ preset: ConversionPreset) async throws -> URL {
        guard TestFixtures.ffmpegPath != nil, TestFixtures.ffprobePath != nil else {
            throw XCTSkip("FFmpeg is not installed.")
        }
        var preset = preset
        preset.backend = .ffmpeg
        let source = try TestFixtures.copy(fixture, to: directory)
        let (outputs, _) = try await BackendHarness.convert(
            backend: FFmpegBackend(), source: source, preset: preset, into: directory,
            baseName: "ffmpeg-\(UUID().uuidString.prefix(6))"
        )
        return try XCTUnwrap(outputs.first)
    }

    func testFFmpegVideoTrim() async throws {
        var preset = try BackendHarness.builtIn("video.mp4-balanced")
        preset.trimStartSeconds = 0.5
        preset.trimEndSeconds = 1.5
        let output = try await convertWithFFmpeg("small_640x360_h264.mp4", preset)
        let duration = try XCTUnwrap(try MediaAssertions.probe(output).duration)
        XCTAssertEqual(duration, 1, accuracy: 0.15, "source is 2 s")
    }

    func testFFmpegAudioTrim() async throws {
        var preset = try BackendHarness.builtIn("audio.mp3-320")
        preset.trimStartSeconds = 1
        let output = try await convertWithFFmpeg("sine_44k_16bit.flac", preset)
        let duration = try XCTUnwrap(try MediaAssertions.probe(output).duration)
        XCTAssertEqual(duration, 2, accuracy: 0.1, "source is 3 s")
    }

    func testFFmpegLoudnessReachesTargetAndKeepsSampleRate() async throws {
        var preset = try BackendHarness.builtIn("audio.mp3-320")
        preset.normalizeLoudness = true
        let output = try await convertWithFFmpeg("sine_44k_16bit.flac", preset)
        let audio = try XCTUnwrap(try MediaAssertions.probe(output).audioStreams.first)
        XCTAssertEqual(audio.sampleRate, 44_100)
        let loudness = try XCTUnwrap(try integratedLoudness(of: output))
        XCTAssertEqual(loudness, MediaTrim.loudnessTargetLUFS, accuracy: 2, "integrated loudness \(loudness) LUFS")
    }

    /// Integrated loudness (LUFS) measured by FFmpeg's ebur128 filter.
    private func integratedLoudness(of url: URL) throws -> Double? {
        let ffmpeg = try XCTUnwrap(TestFixtures.ffmpegPath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-hide_banner", "-nostats", "-i", url.path, "-af", "ebur128", "-f", "null", "-"]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        // Summary block: "I:         -16.1 LUFS"
        guard let summary = text.range(of: "Summary:") else { return nil }
        for line in text[summary.upperBound...].split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("I:") {
                return Double(trimmed.dropFirst(2).replacingOccurrences(of: "LUFS", with: "").trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}
