import XCTest
@testable import FileConverterCore
@testable import FileConverterExternalBackends

final class SourceFingerprintTests: XCTestCase {
    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SourceFingerprintTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testSourceFingerprintMatchesUnmodifiedFile() throws {
        let file = tempDirectory.appendingPathComponent("test.txt")
        try "Hello World".write(to: file, atomically: true, encoding: .utf8)

        let fingerprint = SourceFingerprint(url: file)
        XCTAssertTrue(fingerprint.exists)
        XCTAssertFalse(fingerprint.isDirectory)
        XCTAssertEqual(fingerprint.fileSize, 11)
        XCTAssertTrue(fingerprint.matchesCurrentState())
    }

    func testSourceFingerprintDetectsContentMutation() throws {
        let file = tempDirectory.appendingPathComponent("mutate.txt")
        try "Original".write(to: file, atomically: true, encoding: .utf8)

        let initial = SourceFingerprint(url: file)
        XCTAssertTrue(initial.matchesCurrentState())

        // Mutate content by appending bytes
        try "Original and Extended Content".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertFalse(initial.matchesCurrentState())
    }

    func testSourceFingerprintDetectsDeletion() throws {
        let file = tempDirectory.appendingPathComponent("delete_me.txt")
        try "Temp".write(to: file, atomically: true, encoding: .utf8)

        let fingerprint = SourceFingerprint(url: file)
        XCTAssertTrue(fingerprint.matchesCurrentState())

        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(fingerprint.matchesCurrentState())
    }

    func testDetectionSnapshotCachesAndInvalidatesOnMutation() throws {
        let file = tempDirectory.appendingPathComponent("sample.bin")
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try pngHeader.write(to: file)

        let snapshot = FormatDetector.snapshot(for: file)
        XCTAssertTrue(snapshot.isValid)
        XCTAssertEqual(snapshot.result.format?.id, "png")

        // Mutate into JPEG bytes
        let jpgHeader = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
        try jpgHeader.write(to: file)

        XCTAssertFalse(snapshot.isValid)

        let redetected = FormatDetector.detect(url: file)
        XCTAssertEqual(redetected.format?.id, "jpeg")
    }

    func testMediaProbeCacheHitAndEvictionOnMutation() async throws {
        let file = tempDirectory.appendingPathComponent("media.mp3")
        try "audio bytes".write(to: file, atomically: true, encoding: .utf8)

        await MediaProbeCache.shared.update(for: file) { metadata in
            metadata.duration = 42.0
            metadata.audioCodec = "mp3"
        }

        let cached = await MediaProbeCache.shared.metadata(for: file)
        XCTAssertEqual(cached?.duration, 42.0)
        XCTAssertEqual(cached?.audioCodec, "mp3")

        // Mutate the file
        try "longer audio bytes to change file size".write(to: file, atomically: true, encoding: .utf8)

        // Mutated file must invalidate cache
        let afterMutation = await MediaProbeCache.shared.metadata(for: file)
        XCTAssertNil(afterMutation)
    }

    func testMediaProbeCacheExplicitEvictAndClear() async throws {
        let file = tempDirectory.appendingPathComponent("sound.wav")
        try "wav".write(to: file, atomically: true, encoding: .utf8)

        await MediaProbeCache.shared.update(for: file) { metadata in
            metadata.duration = 10.5
        }
        let beforeEvict = await MediaProbeCache.shared.metadata(for: file)
        XCTAssertNotNil(beforeEvict)

        await MediaProbeCache.shared.evict(for: file)
        let afterEvict = await MediaProbeCache.shared.metadata(for: file)
        XCTAssertNil(afterEvict)
    }
}
