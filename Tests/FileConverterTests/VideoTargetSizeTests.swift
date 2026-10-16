import XCTest
@testable import FileConverterCore
@testable import FileConverterExternalBackends

final class VideoTargetSizeTests: XCTestCase {
    private func executable(_ name: String) -> String? {
        ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func run(_ path: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(path) \(arguments.joined(separator: " "))")
        return data
    }

    func testPlanShrinksThePictureAsTheBitrateDrops() throws {
        let roomy = try XCTUnwrap(FFmpegBackend.videoSizePlan(targetBytes: 50_000_000, durationSeconds: 60))
        XCTAssertEqual(roomy.resolution, .hd1080p)
        XCTAssertEqual(roomy.audioKbps, 128)

        let tight = try XCTUnwrap(FFmpegBackend.videoSizePlan(targetBytes: 10_000_000, durationSeconds: 120))
        XCTAssertEqual(tight.resolution, .sd480p)
        let total = tight.videoKbps + tight.audioKbps
        XCTAssertLessThan(Double(total) * 1_000 / 8 * 120, 10_000_000, "planned bitrates leave room for the container")

        XCTAssertNil(FFmpegBackend.videoSizePlan(targetBytes: 10_000_000, durationSeconds: 3_600),
                     "an hour does not fit in 10 MB at a watchable quality")
    }

    func testBuiltInSizePresetsAreValid() throws {
        for key in ["video.fit-10mb", "video.fit-25mb", "video.fit-50mb"] {
            let preset = try BackendHarness.builtIn(key)
            XCTAssertEqual(PresetValidator.validationErrors(for: preset), [], key)
        }
    }

    func testVideoFitsTheSizeLimitAndStillPlays() async throws {
        guard let ffmpeg = executable("ffmpeg"), let ffprobe = executable("ffprobe") else {
            throw XCTSkip("ffmpeg or ffprobe not installed on this system")
        }
        let directory = try BackendHarness.makeTempDirectory("VideoTargetSize")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Noisy video is hard to compress, so the limit has to do real work.
        let source = directory.appendingPathComponent("clip.mov")
        _ = try run(ffmpeg, [
            "-y", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=12,noise=alls=40:allf=t",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=12",
            "-c:v", "libx264", "-crf", "12", "-c:a", "aac", "-shortest", source.path,
        ])
        XCTAssertGreaterThan(FileAccessManager.shared.fileSize(at: source), 2_400_000)

        var preset = try BackendHarness.builtIn("video.fit-10mb")
        preset.videoTargetFileSizeBytes = 1_200_000
        let output = directory.appendingPathComponent("clip-small.mp4")
        let job = ConversionJob(sourceURL: source, preset: preset)
        _ = try await FFmpegBackend().convert(
            job: job,
            outputs: [PlannedConversionOutput(finalURL: output, temporaryURL: output)],
            progressHandler: { _ in }
        )

        let size = FileAccessManager.shared.fileSize(at: output)
        XCTAssertGreaterThan(size, 0)
        XCTAssertLessThanOrEqual(size, 1_200_000)

        let json = try run(ffprobe, [
            "-v", "error", "-show_entries", "stream=codec_name,height:format=duration", "-of", "json", output.path,
        ])
        let probe = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let streams = try XCTUnwrap(probe["streams"] as? [[String: Any]])
        let video = try XCTUnwrap(streams.first { $0["codec_name"] as? String == "h264" })
        XCTAssertLessThanOrEqual(video["height"] as? Int ?? .max, 480, "a tight limit lowers the picture size")
        XCTAssertTrue(streams.contains { $0["codec_name"] as? String == "aac" }, "the sound is kept")
        let duration = Double((probe["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
        XCTAssertEqual(duration, 12, accuracy: 0.5)
    }
}
