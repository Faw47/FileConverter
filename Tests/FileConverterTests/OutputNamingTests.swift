import XCTest
@testable import FileConverterCore

final class OutputNamingTests: XCTestCase {

    func testMultiOutputSequenceNamesSortNaturallyBeyondThreeDigits() {
        let audioParts = (1...1_001).map {
            ConversionOutputSequence.suffix(prefix: "part", index: $0, totalCount: 1_001)
        }
        XCTAssertEqual(audioParts, audioParts.sorted())
        XCTAssertEqual(audioParts[998], "part-0999")
        XCTAssertEqual(audioParts[999], "part-1000")

        let pdfPages = (1...1_001).map {
            ConversionOutputSequence.suffix(
                prefix: "page",
                index: $0,
                totalCount: 1_001,
                minimumWidth: 3
            )
        }
        XCTAssertEqual(pdfPages, pdfPages.sorted())
        XCTAssertEqual(pdfPages[998], "page-0999")
        XCTAssertEqual(pdfPages[999], "page-1000")
    }

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

    func testExtensionTokenUsesTheDestinationExtension() {
        let sourceURL = tempDirectory.appendingPathComponent("My Vacation Video.mov")
        var preset = BuiltInPresets.makeDefaultPresets().first { $0.menuName == "MP4" }!
        preset.filenamePattern = "{name}_{ext}"

        let formatted = OutputNamingEngine.generateFormattedFilename(
            sourceURL: sourceURL,
            preset: preset,
            targetExtension: "mp4"
        )

        XCTAssertEqual(formatted, "My Vacation Video_mp4.mp4")
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

    func testMultiOutputFinalizationRollsBackPriorReplacementWhenLaterCommitFails() throws {
        let firstFinalURL = tempDirectory.appendingPathComponent("first.txt")
        let firstTemporaryURL = tempDirectory.appendingPathComponent(".first.converting.txt")
        let secondTemporaryURL = tempDirectory.appendingPathComponent(".second.converting.txt")
        let secondFinalURL = tempDirectory
            .appendingPathComponent("missing-parent", isDirectory: true)
            .appendingPathComponent("second.txt")
        try Data("original".utf8).write(to: firstFinalURL)
        try Data("replacement".utf8).write(to: firstTemporaryURL)
        try Data("second output".utf8).write(to: secondTemporaryURL)

        XCTAssertThrowsError(try OutputNamingEngine.finalizeConversionOutputs([
            PlannedConversionOutput(finalURL: firstFinalURL, temporaryURL: firstTemporaryURL),
            PlannedConversionOutput(finalURL: secondFinalURL, temporaryURL: secondTemporaryURL)
        ]))

        XCTAssertEqual(try Data(contentsOf: firstFinalURL), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondFinalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondTemporaryURL.path))
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

    func testAskPolicyStopsAtExistingOutputDuringPreflight() throws {
        let sourceURL = tempDirectory.appendingPathComponent("source.jpg")
        let destinationURL = tempDirectory.appendingPathComponent("source.png")
        try Data("source".utf8).write(to: sourceURL)
        try Data("existing".utf8).write(to: destinationURL)

        var preset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "image.png" }
        )
        preset.overwritePolicy = .ask

        XCTAssertThrowsError(try OutputNamingEngine.resolveFinalDestinationURL(
            sourceURL: sourceURL,
            preset: preset
        )) { error in
            XCTAssertEqual(error as? ConversionError, .outputCollision(path: destinationURL.path))
        }
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("existing".utf8))
    }

    func testMultiOutputSuffixIsDeterministic() throws {
        let sourceURL = tempDirectory.appendingPathComponent("document.pdf")
        let preset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "image.pdf-to-png" }
        )

        XCTAssertEqual(
            OutputNamingEngine.generateFormattedFilename(
                sourceURL: sourceURL,
                preset: preset,
                targetExtension: "png",
                suffix: "page-003"
            ),
            "document-page-003.png"
        )
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
