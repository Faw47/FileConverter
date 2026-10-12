import XCTest
@testable import FileConverterCore

final class AuditFixesRegressionTests: XCTestCase {

    // MARK: - Issue 9: Video Codec Validation
    func testVideoCodecCompatibilityValidation() {
        XCTAssertTrue(PresetValidator.isCodecCompatible(videoCodec: .av1, destinationFormat: "mp4"))
        XCTAssertTrue(PresetValidator.isCodecCompatible(videoCodec: .av1, destinationFormat: "webm"))
        XCTAssertTrue(PresetValidator.isCodecCompatible(videoCodec: .av1, destinationFormat: "mkv"))
        XCTAssertFalse(PresetValidator.isCodecCompatible(videoCodec: .av1, destinationFormat: "mov"))

        XCTAssertTrue(PresetValidator.isCodecCompatible(videoCodec: .h264, destinationFormat: "mp4"))
        XCTAssertTrue(PresetValidator.isCodecCompatible(videoCodec: .h264, destinationFormat: "mov"))
        XCTAssertFalse(PresetValidator.isCodecCompatible(videoCodec: .h264, destinationFormat: "webm"))

        XCTAssertTrue(PresetValidator.isCodecCompatible(videoCodec: .proRes, destinationFormat: "mov"))
        XCTAssertTrue(PresetValidator.isCodecCompatible(videoCodec: .proRes, destinationFormat: "mkv"))
        XCTAssertFalse(PresetValidator.isCodecCompatible(videoCodec: .proRes, destinationFormat: "mp4"))
        XCTAssertFalse(PresetValidator.isCodecCompatible(videoCodec: .proRes, destinationFormat: "webm"))

        XCTAssertTrue(PresetValidator.isCodecCompatible(videoCodec: .vp9, destinationFormat: "webm"))
        XCTAssertFalse(PresetValidator.isCodecCompatible(videoCodec: .vp9, destinationFormat: "mp4"))
        XCTAssertFalse(PresetValidator.isCodecCompatible(videoCodec: .vp9, destinationFormat: "mov"))
    }

    // MARK: - Issue 2: Preset Exchange PDF Options Round-Trip
    func testPDFOptionsExchangeRoundTrip() throws {
        let options = ConversionProcessingOptions(
            splitPDFIntoPages: true,
            pdfSplitMode: "ranges",
            pdfPageRanges: "1-3, 5",
            pdfChunkSize: 2,
            pdfSelectedPages: [1, 2, 5],
            pdfMergeSplitOutputs: true,
            pdfNamingPattern: "{name}_part",
            pdfZeroPadDigits: 3,
            pdfOutputSubfolder: "Sub",
            pdfCompressionProfile: "ebook",
            pdfDPI: 150,
            pdfImageQuality: 0.75,
            pdfColorMode: "grayscale",
            pdfRemoveMetadata: true,
            pdfRemoveAnnotations: true,
            pdfRemoveThumbnails: true,
            pdfLinearize: true,
            pdfCompatibilityLevel: "1.5"
        )

        let preset = ConversionPreset(
            name: "Full PDF Preset",
            menuName: "Full PDF",
            category: .document,
            sourceFormats: ["pdf"],
            destinationFormat: "pdf",
            backend: .pdfKit,
            processingOptions: options
        )

        let exportedData = try PresetExchange.exportSingle(preset: preset)
        let importedPresets = try PresetExchange.importPresets(from: exportedData)
        XCTAssertEqual(importedPresets.count, 1)

        let imported = try XCTUnwrap(importedPresets.first)
        let importedOpts = try XCTUnwrap(imported.processingOptions)

        XCTAssertEqual(importedOpts.splitPDFIntoPages, true)
        XCTAssertEqual(importedOpts.pdfSplitMode, "ranges")
        XCTAssertEqual(importedOpts.pdfPageRanges, "1-3, 5")
        XCTAssertEqual(importedOpts.pdfChunkSize, 2)
        XCTAssertEqual(importedOpts.pdfSelectedPages, [1, 2, 5])
        XCTAssertEqual(importedOpts.pdfMergeSplitOutputs, true)
        XCTAssertEqual(importedOpts.pdfNamingPattern, "{name}_part")
        XCTAssertEqual(importedOpts.pdfZeroPadDigits, 3)
        XCTAssertEqual(importedOpts.pdfOutputSubfolder, "Sub")
        XCTAssertEqual(importedOpts.pdfCompressionProfile, "ebook")
        XCTAssertEqual(importedOpts.pdfDPI, 150)
        XCTAssertEqual(importedOpts.pdfImageQuality, 0.75)
        XCTAssertEqual(importedOpts.pdfColorMode, "grayscale")
        XCTAssertEqual(importedOpts.pdfRemoveMetadata, true)
        XCTAssertEqual(importedOpts.pdfRemoveAnnotations, true)
        XCTAssertEqual(importedOpts.pdfRemoveThumbnails, true)
        XCTAssertEqual(importedOpts.pdfLinearize, true)
        XCTAssertEqual(importedOpts.pdfCompatibilityLevel, "1.5")
    }

    // MARK: - Issue 38: Duplicate Split Ranges Disambiguation
    func testDuplicatePageRangesDisambiguated() {
        let plans = PDFPageRangeParser.planOutputs(
            totalPages: 10,
            splitMode: "ranges",
            pageRanges: "1-3, 1-3",
            mergeOutputs: false
        )

        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(plans[0].suffix, "pages-1-3-1")
        XCTAssertEqual(plans[1].suffix, "pages-1-3-2")
    }

    // MARK: - Issue 24 & 30: Queue Overall Progress Telemetry
    @MainActor
    func testOverallProgressExcludesFailedOrCancelledJobs() {
        let queue = ConversionQueue.shared
        queue.clearCompleted()

        let preset = BuiltInPresets.makeDefaultPresets().first!
        let job1 = ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/1.txt"), preset: preset, state: .completed)
        let job2 = ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/2.txt"), preset: preset, state: .failed(ConversionError.unknown(message: "Failed")))
        let job3 = ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/3.txt"), preset: preset, state: .cancelled)

        queue.setJobsForTesting([job1, job2, job3])

        // 1 completed out of 3 jobs = 1.0 / 3.0 = ~0.333
        XCTAssertEqual(queue.completedCount, 1)
        XCTAssertEqual(queue.failedCount, 1)
        XCTAssertEqual(queue.cancelledCount, 1)
        XCTAssertEqual(queue.overallProgress, 1.0 / 3.0, accuracy: 0.001)

        queue.clearCompleted()
    }

    // MARK: - Issue 25: Remove Individual Job
    @MainActor
    func testRemoveIndividualJob() {
        let queue = ConversionQueue.shared
        queue.clearCompleted()

        let preset = BuiltInPresets.makeDefaultPresets().first!
        let idToRemove = UUID()
        let job1 = ConversionJob(id: idToRemove, sourceURL: URL(fileURLWithPath: "/tmp/remove_me.txt"), preset: preset, state: .completed)
        let job2 = ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/keep_me.txt"), preset: preset, state: .completed)

        queue.setJobsForTesting([job1, job2])
        XCTAssertEqual(queue.jobs.count, 2)

        queue.removeJob(id: idToRemove)
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs.first?.sourceURL.path, "/tmp/keep_me.txt")

        queue.clearCompleted()
    }

    // MARK: - Issue 34: hasClearableJobs
    @MainActor
    func testHasClearableJobs() {
        let queue = ConversionQueue.shared
        queue.clearCompleted()

        XCTAssertFalse(queue.hasClearableJobs)

        let preset = BuiltInPresets.makeDefaultPresets().first!
        let job = ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/done.txt"), preset: preset, state: .skipped("already exists"))
        queue.setJobsForTesting([job])
        XCTAssertTrue(queue.hasClearableJobs)

        queue.clearCompleted()
        XCTAssertFalse(queue.hasClearableJobs)
    }

    // MARK: - Issue 10: Prevent Double Extension
    func testPreventDoubleExtension() {
        let sourceURL = URL(fileURLWithPath: "/tmp/MyVideo.mp4")
        var preset = BuiltInPresets.makeDefaultPresets().first { $0.destinationFormat == "mp4" }!
        // Custom values below are this preset's own, not General settings.
        preset.inheritance = .inheritNone
        preset.filenamePattern = "{name}_{ext}"

        let outputFilename = OutputNamingEngine.generateFormattedFilename(
            sourceURL: sourceURL,
            preset: preset,
            targetExtension: "mp4"
        )

        XCTAssertEqual(outputFilename, "MyVideo_mp4.mp4")
        XCTAssertFalse(outputFilename.hasSuffix(".mp4.mp4"))

        // When pattern already ends with .mp4
        preset.filenamePattern = "{name}.mp4"
        let outputFilename2 = OutputNamingEngine.generateFormattedFilename(
            sourceURL: sourceURL,
            preset: preset,
            targetExtension: "mp4"
        )
        XCTAssertEqual(outputFilename2, "MyVideo.mp4")
        XCTAssertFalse(outputFilename2.hasSuffix(".mp4.mp4"))

        // When pattern ends with .{ext} and a suffix is provided
        preset.filenamePattern = "{name}.{ext}"
        let outputFilename3 = OutputNamingEngine.generateFormattedFilename(
            sourceURL: sourceURL,
            preset: preset,
            targetExtension: "mp4",
            suffix: "part-1"
        )
        XCTAssertEqual(outputFilename3, "MyVideo-part-1.mp4")
        XCTAssertTrue(outputFilename3.hasSuffix(".mp4"))
    }

    // MARK: - Issue 12: Default Filename Pattern Fallback
    func testDefaultFilenamePatternFallback() {
        let sourceURL = URL(fileURLWithPath: "/tmp/Report.docx")
        var preset = BuiltInPresets.makeDefaultPresets().first { $0.destinationFormat == "pdf" }!
        preset.filenamePattern = "{name}"

        let key = "fc.defaultFilenamePattern"
        let oldPattern = UserDefaults.standard.string(forKey: key)
        defer {
            if let oldPattern {
                UserDefaults.standard.set(oldPattern, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.set("{name}_converted", forKey: key)

        let outputFilename = OutputNamingEngine.generateFormattedFilename(
            sourceURL: sourceURL,
            preset: preset,
            targetExtension: "pdf"
        )

        XCTAssertEqual(outputFilename, "Report_converted.pdf")
    }

    // MARK: - Issue 37: WebM Disambiguation from MKV
    func testWebMDisambiguationFromMKV() {
        let webmURL = URL(fileURLWithPath: "/tmp/sample.webm")
        let format = FormatDetector.detect(url: webmURL)
        XCTAssertEqual(format.format?.id, "webm")
    }

    // MARK: - Issue 1: Overwrite Import Preserves Non-Conflicting Custom Presets
    func testOverwriteImportPreservesNonConflictingCustomPresets() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PresetTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("presets.json")
        let store = PresetStore(storageURL: fileURL, postsDarwinNotifications: false)

        let customA = ConversionPreset(
            id: UUID(),
            name: "Custom Preset Alpha",
            menuName: "Alpha",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "mp3",
            backend: .ffmpeg
        )
        try store.addPreset(customA)
        XCTAssertTrue(store.presets.contains(where: { $0.id == customA.id }))

        let customB = ConversionPreset(
            id: UUID(),
            name: "Custom Preset Beta",
            menuName: "Beta",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "png",
            backend: .imageIO
        )
        let docData = try PresetExchange.exportSingle(preset: customB)

        // Import with overwrite = true
        try store.importPresetsJSON(docData, overwrite: true)

        // Verify customA was NOT deleted!
        XCTAssertTrue(store.presets.contains(where: { $0.id == customA.id }), "Existing non-conflicting custom presets must not be purged when overwrite is true")
        XCTAssertTrue(store.presets.contains(where: { $0.id == customB.id }), "Imported preset must be present")
    }

    // MARK: - Issue 33: Numbered URL with Extensionless Target
    func testFindAvailableNumberedURLExtensionlessFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("NumberedURLTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetURL = tempDir.appendingPathComponent("README")
        try "content".write(to: targetURL, atomically: true, encoding: .utf8)

        let resolved = OutputNamingEngine.findAvailableNumberedURL(for: targetURL)
        XCTAssertEqual(resolved.lastPathComponent, "README (1)")
        XCTAssertFalse(resolved.lastPathComponent.hasSuffix("."))
    }

    // MARK: - Issue 24/30: Overall Progress During Preparing and Finalizing
    @MainActor
    func testOverallProgressDuringPreparingAndFinalizing() {
        let queue = ConversionQueue.shared
        queue.clearCompleted()

        let preset = BuiltInPresets.makeDefaultPresets().first!
        var job1 = ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/1.txt"), preset: preset, state: .preparing)
        job1.progress.fractionCompleted = 0.1
        var job2 = ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/2.txt"), preset: preset, state: .finalizing)
        job2.progress.fractionCompleted = 0.95

        queue.setJobsForTesting([job1, job2])

        // Overall progress should be (0.1 + 0.95) / 2 = 0.525, NOT 0.0!
        XCTAssertEqual(queue.overallProgress, 0.525, accuracy: 0.001)

        queue.clearCompleted()
    }
}
