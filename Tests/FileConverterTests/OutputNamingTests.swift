import XCTest
@testable import FileConverterCore

final class OutputNamingTests: XCTestCase {
    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("NamingTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testPatternFormatting() {
        let sourceURL = tempDirectory.appendingPathComponent("My Vacation Video.mov")
        var preset = BuiltInPresets.makeDefaultPresets().first { $0.menuName == "MP4" }!
        preset.filenamePattern = "{name}_converted"

        let formatted = OutputNamingEngine.generateFormattedFilename(sourceURL: sourceURL, preset: preset, targetExtension: "mp4")
        XCTAssertEqual(formatted, "My Vacation Video_converted.mp4")
    }

    func testUnicodeAndArabicFilenameHandling() {
        let arabicURL = tempDirectory.appendingPathComponent("فيديو العيد ٢٠٢٦.mov")
        let specialURL = tempDirectory.appendingPathComponent("My Video (Final) [4K] #2 & test$?.mov")

        let preset = BuiltInPresets.makeDefaultPresets().first { $0.menuName == "MP4" }!

        let arabicFormatted = OutputNamingEngine.generateFormattedFilename(sourceURL: arabicURL, preset: preset, targetExtension: "mp4")
        XCTAssertTrue(arabicFormatted.contains("فيديو العيد ٢٠٢٦"))
        XCTAssertEqual(arabicFormatted, "فيديو العيد ٢٠٢٦.mp4")

        let specialFormatted = OutputNamingEngine.generateFormattedFilename(sourceURL: specialURL, preset: preset, targetExtension: "mp4")
        XCTAssertFalse(specialFormatted.contains("?"))
        XCTAssertTrue(specialFormatted.hasSuffix(".mp4"))
    }

    func testCollisionNumberAppending() throws {
        let file1 = tempDirectory.appendingPathComponent("movie.mp4")
        try "test data".write(to: file1, atomically: true, encoding: .utf8)

        let resolved1 = OutputNamingEngine.findAvailableNumberedURL(for: file1)
        XCTAssertEqual(resolved1.lastPathComponent, "movie (1).mp4")

        try "test data 2".write(to: resolved1, atomically: true, encoding: .utf8)
        let resolved2 = OutputNamingEngine.findAvailableNumberedURL(for: file1)
        XCTAssertEqual(resolved2.lastPathComponent, "movie (2).mp4")
    }

    func testAtomicFileFinalization() throws {
        let finalURL = tempDirectory.appendingPathComponent("output.mp4")
        let tempURL = OutputNamingEngine.createTemporaryOutputURL(for: finalURL)

        try "temp conversion data".write(to: tempURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

        try OutputNamingEngine.finalizeConversionOutput(temporaryURL: tempURL, finalDestinationURL: finalURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
    }

    func testAtomicReplacementPreservesExistingFileUntilCommit() throws {
        let finalURL = tempDirectory.appendingPathComponent("output.mp4")
        let tempURL = OutputNamingEngine.createTemporaryOutputURL(for: finalURL)
        try Data("existing".utf8).write(to: finalURL)
        try Data("replacement".utf8).write(to: tempURL)

        try OutputNamingEngine.finalizeConversionOutput(
            temporaryURL: tempURL,
            finalDestinationURL: finalURL,
            overwrite: true
        )

        XCTAssertEqual(try Data(contentsOf: finalURL), Data("replacement".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testNonOverwriteFinalizationNeverDestroysRacingOutput() throws {
        let finalURL = tempDirectory.appendingPathComponent("output.mp4")
        let tempURL = OutputNamingEngine.createTemporaryOutputURL(for: finalURL)
        try Data("racing output".utf8).write(to: finalURL)
        try Data("conversion".utf8).write(to: tempURL)

        XCTAssertThrowsError(try OutputNamingEngine.finalizeConversionOutput(
            temporaryURL: tempURL,
            finalDestinationURL: finalURL,
            overwrite: false
        ))
        XCTAssertEqual(try Data(contentsOf: finalURL), Data("racing output".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testNumberingTreatsInFlightDestinationsAsOccupied() {
        let targetURL = tempDirectory.appendingPathComponent("output.mp4")
        let firstReservedURL = tempDirectory.appendingPathComponent("output (1).mp4")

        let result = OutputNamingEngine.findAvailableNumberedURL(
            for: targetURL,
            reservedURLs: [targetURL, firstReservedURL]
        )

        XCTAssertEqual(result.lastPathComponent, "output (2).mp4")
    }

    func testCustomFolderNeverFallsBackToDisplayPath() throws {
        var preset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "image.png" }
        )
        preset.outputDirectoryPolicy = .customFolder(
            bookmarkData: Data("not a bookmark".utf8),
            displayPath: tempDirectory.path
        )

        XCTAssertThrowsError(try OutputNamingEngine.resolveFinalDestinationURL(
            sourceURL: tempDirectory.appendingPathComponent("source.jpg"),
            preset: preset
        )) { error in
            XCTAssertEqual(
                error as? ConversionError,
                .destinationUnavailable(path: self.tempDirectory.path)
            )
        }
    }

    func testSourceSubfolderRejectsPathTraversal() throws {
        let sourceURL = tempDirectory.appendingPathComponent("source.jpg")

        XCTAssertThrowsError(try OutputNamingEngine.resolveDestinationDirectory(
            forSourceURL: sourceURL,
            policy: .sourceSubfolder(subfolderName: "../escaped")
        ))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tempDirectory.deletingLastPathComponent().appendingPathComponent("escaped").path
            )
        )
    }
}
