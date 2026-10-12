import XCTest
@testable import FileConverterCore

final class NamingPreviewParityTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_760_000_000)

    func testPreviewMatchesRealNamingForManyPatterns() throws {
        let patterns = [
            "{name}", "{name}_converted", "{name}-{preset}", "{date}_{name}", "{name} {time}",
            "{preset}", "{name}.{ext}", "{name}_{ext}", "Copy of {name}", "{name}:bad/chars?",
        ]
        let presets = try ["video.mkv-to-mp4", "audio.fit-5mb", "image.jpeg", "document.pdf-compressed"].map(BackendHarness.builtIn)
        for preset in presets {
            for pattern in patterns {
                var custom = preset
                custom.inheritance = .inheritNone
                custom.filenamePattern = pattern
                custom.sameFormatSuffix = nil
                let real = OutputNamingEngine.generateFormattedFilename(
                    sourceURL: URL(fileURLWithPath: "/tmp/Holiday Clip.mov"),
                    preset: custom,
                    targetExtension: preset.destinationFormat,
                    date: date
                )
                let preview = OutputNamingEngine.previewFilename(
                    pattern: pattern,
                    sourceName: "Holiday Clip",
                    sourceExtension: "mov",
                    targetExtension: preset.destinationFormat,
                    presetMenuName: preset.menuName,
                    date: date
                )
                XCTAssertEqual(preview, real, "\(pattern) with \(preset.menuName)")
            }
        }
    }

    func testPresetTokenIsReadable() {
        XCTAssertEqual(OutputNamingEngine.sanitizedPresetToken("MKV → MP4"), "MKV_to_MP4")
        XCTAssertEqual(OutputNamingEngine.sanitizedPresetToken("MP4 – Smaller"), "MP4_-_Smaller")
        XCTAssertEqual(OutputNamingEngine.sanitizedPresetToken("Audio ≤ 5 MB"), "Audio_5_MB")
        XCTAssertEqual(OutputNamingEngine.sanitizedPresetToken("  MP3 (192k) "), "MP3_192k")
    }

    func testSameFormatSuffixAvoidsNumberedCopies() throws {
        let preset = try BackendHarness.builtIn("image.jpeg-web")
        let suite = "Naming-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let name = OutputNamingEngine.generateFormattedFilename(
            sourceURL: URL(fileURLWithPath: "/tmp/photo.jpg"),
            preset: preset,
            targetExtension: "jpg",
            defaults: .load(from: defaults)
        )
        XCTAssertEqual(name, "photo-web.jpg")

        let fromPNG = OutputNamingEngine.generateFormattedFilename(
            sourceURL: URL(fileURLWithPath: "/tmp/photo.png"),
            preset: preset,
            targetExtension: "jpg",
            defaults: .load(from: defaults)
        )
        XCTAssertEqual(fromPNG, "photo.jpg", "a real format change keeps the plain name")
    }

    @MainActor
    func testOneBatchSharesItsTimestamp() throws {
        let queue = ConversionQueue()
        queue.pause()
        let preset = try BackendHarness.builtIn("image.png")
        queue.addJobs((1...3).map { ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/\($0).jpg"), preset: preset) })
        XCTAssertEqual(Set(queue.jobs.map(\.batchCreatedAt)).count, 1)
        queue.cancelAll()
    }
}
