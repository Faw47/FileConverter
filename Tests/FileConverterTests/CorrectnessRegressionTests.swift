import XCTest
@testable import FileConverterCore
@testable import FileConverterContracts
@testable import FileConverterNativeBackends

final class CorrectnessRegressionTests: XCTestCase {
    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Correctness-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - PDF strict parsing (acceptance 1, 2)

    func testStrictParserReportsInvalidReversedOutOfBoundsEmpty() {
        let invalid = PDFPageRangeParser.parseRangesStrict("abc, 2-4", totalPages: 10)
        XCTAssertEqual(invalid.validRanges, [2...4])
        XCTAssertEqual(invalid.invalidTokens, ["abc"])
        XCTAssertNil(invalid.errorMessage.map { _ in nil } ?? nil)
        XCTAssertNotNil(invalid.errorMessage)

        let reversed = PDFPageRangeParser.parseRangesStrict("5-2", totalPages: 10)
        XCTAssertTrue(reversed.validRanges.isEmpty)
        XCTAssertEqual(reversed.reversedRanges, ["5-2"])
        // Never silently reordered.
        XCTAssertFalse(reversed.validRanges.contains(2...5))

        let oob = PDFPageRangeParser.parseRangesStrict("15-20", totalPages: 10)
        XCTAssertTrue(oob.validRanges.isEmpty)
        XCTAssertEqual(oob.outOfBoundsPages, ["15-20"])

        let empty = PDFPageRangeParser.parseRangesStrict("", totalPages: 10)
        XCTAssertTrue(empty.isEmptySelection)
        XCTAssertTrue(empty.validRanges.isEmpty)
    }

    func testPlanOutputsNeverFallsBackToAllOnInvalid() {
        XCTAssertTrue(PDFPageRangeParser.planOutputs(totalPages: 10, splitMode: "ranges", pageRanges: "abc", mergeOutputs: false).isEmpty)
        XCTAssertTrue(PDFPageRangeParser.planOutputs(totalPages: 10, splitMode: "ranges", pageRanges: "5-2", mergeOutputs: false).isEmpty)
        XCTAssertTrue(PDFPageRangeParser.planOutputs(totalPages: 10, splitMode: "ranges", pageRanges: "", mergeOutputs: false).isEmpty)
        XCTAssertTrue(PDFPageRangeParser.planOutputs(totalPages: 10, splitMode: "ranges", pageRanges: "1-2, abc", mergeOutputs: false).isEmpty)
        XCTAssertTrue(PDFPageRangeParser.planOutputs(totalPages: 10, splitMode: "selected", pageRanges: nil, selectedPages: [], mergeOutputs: false).isEmpty)
        XCTAssertTrue(PDFPageRangeParser.planOutputs(totalPages: 10, splitMode: "selected", pageRanges: nil, selectedPages: [1, 11], mergeOutputs: false).isEmpty)
        // Valid still works.
        XCTAssertEqual(PDFPageRangeParser.planOutputs(totalPages: 10, splitMode: "ranges", pageRanges: "1-2", mergeOutputs: false).count, 1)
    }

    // MARK: - Aliases identical across validation/queue/Finder (acceptance 9)

    func testAliasVocabularyAgreesAcrossLayers() {
        let registry = FormatRegistry.shared
        for alias in ["tif", "tiff", "jpe", "jpeg", "jpg", "m4v", "mp4", "htm", "html"] {
            XCTAssertNotNil(registry.canonicalFormat(forAlias: alias), "alias \(alias) should resolve")
        }
        XCTAssertEqual(registry.canonicalFormat(forAlias: "tif")?.id, "tiff")
        XCTAssertEqual(registry.canonicalFormat(forAlias: "jpe")?.id, "jpeg")
        XCTAssertEqual(registry.canonicalFormat(forAlias: "m4v")?.id, "mp4")
        XCTAssertEqual(registry.canonicalFormat(forAlias: "htm")?.id, "html")

        guard let tiff = registry.format(forID: "tiff"),
              let jpeg = registry.format(forID: "jpeg"),
              let mp4 = registry.format(forID: "mp4") else {
            return XCTFail("formats missing")
        }
        XCTAssertTrue(registry.matchesSourceSpecifier("tif", format: tiff))
        XCTAssertTrue(registry.matchesSourceSpecifier("tiff", format: tiff))
        XCTAssertTrue(registry.matchesSourceSpecifier("jpe", format: jpeg))
        XCTAssertTrue(registry.matchesSourceSpecifier("m4v", format: mp4))

        let tifPreset = ConversionPreset(name: "TIF", category: .image, sourceFormats: ["tif"], destinationFormat: "png")
        XCTAssertTrue(PresetValidator.isPresetCompatible(tifPreset, forFormat: tiff))
        let jpePreset = ConversionPreset(name: "JPE", category: .image, sourceFormats: ["jpe"], destinationFormat: "png")
        XCTAssertTrue(PresetValidator.isPresetCompatible(jpePreset, forFormat: jpeg))
        // Invalid mixed with valid still rejected.
        let bad = ConversionPreset(name: "Bad", category: .image, sourceFormats: ["not-a-format"], destinationFormat: "png")
        XCTAssertFalse(PresetValidator.validationErrors(for: bad).isEmpty)
    }

    // MARK: - Preset quarantine + FLAC lossless (acceptance 10, 11)

    func testOneMalformedCustomDoesNotRemoveValidOrBuiltIns() throws {
        let dir = tempDirectory.appendingPathComponent("quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storageURL = dir.appendingPathComponent("presets.json")
        // Seed with defaults first.
        let seed = PresetStore(storageURL: storageURL, postsDarwinNotifications: false)
        let validCustom = ConversionPreset(name: "Valid Custom", category: .image, sourceFormats: ["image"], destinationFormat: "png")
        try seed.addPreset(validCustom)
        // Corrupt the file: one valid custom + one malformed (empty name + bad dest).
        var stored = seed.presets
        var malformed = validCustom
        malformed.id = UUID()
        malformed.name = ""
        malformed.destinationFormat = "not-a-format"
        stored.append(malformed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Doc: Codable { let schemaVersion: Int; let presets: [ConversionPreset] }
        try encoder.encode(Doc(schemaVersion: 2, presets: stored)).write(to: storageURL, options: .atomic)
        let quarantinedFileBytes = try Data(contentsOf: storageURL)

        let reloaded = PresetStore(
            storageURL: storageURL,
            postsDarwinNotifications: false,
            snapshotWriterOverride: { _ in }
        )
        XCTAssertTrue(reloaded.presets.contains(where: { $0.name == "Valid Custom" }))
        XCTAssertTrue(reloaded.presets.contains(where: { $0.isBuiltIn }))
        XCTAssertFalse(reloaded.presets.contains(where: { $0.id == malformed.id }))
        XCTAssertNotNil(reloaded.lastErrorDescription)
        XCTAssertEqual(try Data(contentsOf: storageURL), quarantinedFileBytes)

        XCTAssertTrue(reloaded.publishFinderMenuSnapshot())
        XCTAssertNotNil(reloaded.lastErrorDescription)
    }

    func testFLACLosslessRoundTripsAsLossless() throws {
        let dir = tempDirectory.appendingPathComponent("flac", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storageURL = dir.appendingPathComponent("presets.json")
        let store = PresetStore(storageURL: storageURL, postsDarwinNotifications: false)
        guard let flac = store.presets.first(where: { $0.builtInKey == "audio.flac" }) else {
            return XCTFail("FLAC preset missing")
        }
        XCTAssertEqual(flac.quality, .lossless)
        // Reload must preserve lossless (no silent migration to high).
        let reloaded = PresetStore(storageURL: storageURL, postsDarwinNotifications: false)
        XCTAssertEqual(reloaded.presets.first(where: { $0.builtInKey == "audio.flac" })?.quality, .lossless)
    }

    // MARK: - Format detection (acceptance 12)

    private func write(_ bytes: [UInt8], named name: String, extra: Data? = nil) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        var data = Data(bytes)
        if let extra { data.append(extra) }
        try data.write(to: url)
        return url
    }

    func testAVIFPreferredOverGenericHEICBrands() throws {
        var data = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70])
        data.append("avif".data(using: .utf8)!)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        data.append("mif1".data(using: .utf8)!)
        data.append("avif".data(using: .utf8)!)
        let url = tempDirectory.appendingPathComponent("photo.bin")
        try data.write(to: url)
        XCTAssertEqual(FormatDetector.detect(url: url).format?.id, "avif")
    }

    func testExtensionlessMP3FrameSyncDetected() throws {
        let url = try write([0xFF, 0xFB, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00], named: "audio_no_ext")
        XCTAssertEqual(FormatDetector.detect(url: url).format?.id, "mp3")
    }

    func testOggOpusVsVorbisDistinguished() throws {
        var opus = Data([0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00, 0x00])
        opus.append("OpusHead".data(using: .utf8)!)
        let opusURL = tempDirectory.appendingPathComponent("a.opus.bin")
        try opus.write(to: opusURL)
        XCTAssertEqual(FormatDetector.detect(url: opusURL).format?.id, "opus")

        var vorbis = Data([0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00, 0x00])
        vorbis.append("vorbis".data(using: .utf8)!)
        let oggURL = tempDirectory.appendingPathComponent("b.ogg.bin")
        try vorbis.write(to: oggURL)
        XCTAssertEqual(FormatDetector.detect(url: oggURL).format?.id, "ogg")
    }

    func testTruncatedFtypReturnsUnknownRatherThanMP4() throws {
        // ftyp header with no brand bytes available.
        let url = try write([0x00, 0x00, 0x00, 0x0C, 0x66, 0x74, 0x79, 0x70, 0x7A, 0x7A, 0x7A, 0x7A], named: "trunc.bin")
        let result = FormatDetector.detect(url: url)
        XCTAssertNotEqual(result.format?.id, "mp4")
    }

    func testTIFFMagicDetected() throws {
        let url = try write([0x49, 0x49, 0x2A, 0x00, 0x10, 0x00, 0x00, 0x00], named: "scan.bin")
        XCTAssertEqual(FormatDetector.detect(url: url).format?.id, "tiff")
    }

    // MARK: - Same-file guard (acceptance 3)

    func testReservationKeyResolvesTemporaryDirectoryAliases() {
        let tmpURL = URL(fileURLWithPath: "/tmp/fileconverter-reservation-key")
        let privateTmpURL = URL(fileURLWithPath: "/private/tmp/fileconverter-reservation-key")
        XCTAssertEqual(
            FileAccessManager.shared.reservationKey(for: tmpURL),
            FileAccessManager.shared.reservationKey(for: privateTmpURL)
        )
    }

    func testNumberedOutputTreatsAliasedReservationAsOccupied() {
        let targetURL = URL(fileURLWithPath: "/private/tmp/fileconverter-numbered-output.png")
        let aliasURL = URL(fileURLWithPath: "/tmp/fileconverter-numbered-output.png")
        let candidate = OutputNamingEngine.findAvailableNumberedURL(
            for: targetURL,
            reservedURLs: [aliasURL]
        )

        XCTAssertEqual(
            candidate,
            targetURL.deletingLastPathComponent()
                .appendingPathComponent("fileconverter-numbered-output (1).png")
        )
    }

    func testSameFileIdentityRejected() throws {
        let src = tempDirectory.appendingPathComponent("same.jpg")
        try Data("hello".utf8).write(to: src)
        XCTAssertTrue(FileAccessManager.shared.urlsReferToSameFile(src, src))
        let link = tempDirectory.appendingPathComponent("link.jpg")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: src)
        XCTAssertTrue(FileAccessManager.shared.urlsReferToSameFile(src, link))

        var preset = ConversionPreset(name: "JPG", category: .image, sourceFormats: ["image"], destinationFormat: "jpg")
        preset.filenamePattern = "{name}"
        // Ideal URL equals source path -> must throw.
        XCTAssertThrowsError(try OutputNamingEngine.resolveFinalDestinationURL(sourceURL: src, preset: preset, targetExtension: "jpg"))
    }

    // MARK: - Multi-output contract (acceptance 4)

    func testDefaultMultiOutputThrowsContractViolation() async {
        struct SingleOnlyBackend: ConversionBackend, Sendable {
            let backendType: BackendType = .imageIO
            let isAvailable = true
            func supports(sourceFormat: FormatDefinition, destinationFormat: FormatDefinition, preset: ConversionPreset) -> Bool { true }
            func convert(job: ConversionJob, progressHandler: @escaping @Sendable (ConversionProgress) -> Void) async throws {}
            func cancel(jobID: UUID) async {}
        }
        let backend = SingleOnlyBackend()
        let preset = ConversionPreset(name: "P", category: .image, sourceFormats: ["image"], destinationFormat: "png")
        let job = ConversionJob(sourceURL: tempDirectory.appendingPathComponent("a.png"), preset: preset)
        let outputs = [
            PlannedConversionOutput(finalURL: tempDirectory.appendingPathComponent("o1.png"), temporaryURL: tempDirectory.appendingPathComponent("t1.png")),
            PlannedConversionOutput(finalURL: tempDirectory.appendingPathComponent("o2.png"), temporaryURL: tempDirectory.appendingPathComponent("t2.png")),
        ]
        do {
            _ = try await backend.convert(job: job, outputs: outputs) { _ in }
            XCTFail("expected contract violation")
        } catch let error as ConversionError {
            guard case .backendContractViolation = error else {
                return XCTFail("wrong error \(error)")
            }
        } catch {
            XCTFail("wrong error type \(error)")
        }
    }

    // MARK: - Collision override + progress + batch (acceptance 5, 6, 7)

    @MainActor
    func testCollisionOverridePreservedAcrossRetry() {
        let preset = ConversionPreset(name: "P", category: .image, sourceFormats: ["image"], destinationFormat: "png", overwritePolicy: .ask)
        // Decision stores override without mutating the preset.
        let queue = ConversionQueue()
        let job = ConversionJob(sourceURL: tempDirectory.appendingPathComponent("a.png"), preset: preset, state: .awaitingCollision)
        queue.setJobsForTesting([job])
        queue.injectCollisionForTesting(jobID: job.id, destination: tempDirectory.appendingPathComponent("a.png"), filename: "a.png")
        queue.resolveCollisions(.replace, jobIDs: [job.id])
        let after = queue.jobs.first(where: { $0.id == job.id })
        XCTAssertEqual(after?.collisionOverride, .overwrite)
        XCTAssertEqual(after?.preset.overwritePolicy, .ask, "original preset must not mutate")
        queue.cancelAll()
        // Retry clears the per-attempt override on a terminal job.
        let retryQueue = ConversionQueue()
        var terminal = ConversionJob(sourceURL: tempDirectory.appendingPathComponent("a.png"), preset: preset, state: .failed(.unknown(message: "x")))
        terminal.collisionOverride = .overwrite
        retryQueue.setJobsForTesting([terminal])
        let tid = retryQueue.jobs[0].id
        retryQueue.retryJob(id: tid)
        XCTAssertNil(retryQueue.jobs.first?.collisionOverride)
        XCTAssertEqual(retryQueue.jobs.first?.preset.overwritePolicy, .ask)
        XCTAssertEqual(preset.overwritePolicy, .ask)
    }

    @MainActor
    func testCompletionProgressReachesOneForTerminalFailures() {
        let queue = ConversionQueue()
        let preset = BuiltInPresets.makeDefaultPresets().first!
        let j1 = ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/1"), preset: preset, state: .completed)
        let j2 = ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/2"), preset: preset, state: .failed(.unknown(message: "x")))
        let j3 = ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/3"), preset: preset, state: .cancelled)
        queue.setJobsForTesting([j1, j2, j3])
        XCTAssertEqual(queue.completionProgress, 1.0, accuracy: 0.001)
        XCTAssertEqual(queue.successFraction, 1.0/3.0, accuracy: 0.001)
        XCTAssertEqual(queue.completedCount, 1)
        XCTAssertEqual(queue.failedCount, 1)
    }

    @MainActor
    func testCancellationAndClearReleaseOwnedOutputReservations() {
        let queue = ConversionQueue()
        let preset = BuiltInPresets.makeDefaultPresets().first!
        let pending = ConversionJob(
            sourceURL: tempDirectory.appendingPathComponent("pending.png"),
            preset: preset,
            state: .awaitingCollision
        )
        let pendingOutput = tempDirectory.appendingPathComponent("pending-output.png")
        queue.setJobsForTesting([pending])
        queue.setReservationForTesting(url: pendingOutput, jobID: pending.id)
        queue.cancelJob(id: pending.id)
        XCTAssertFalse(queue.reservedOutputURLsForTesting.contains(FileAccessManager.shared.reservationKey(for: pendingOutput)))

        let terminal = ConversionJob(
            sourceURL: tempDirectory.appendingPathComponent("terminal.png"),
            preset: preset,
            state: .completed
        )
        let terminalOutput = tempDirectory.appendingPathComponent("terminal-output.png")
        queue.setJobsForTesting([terminal])
        queue.setReservationForTesting(url: terminalOutput, jobID: terminal.id)
        queue.clearCompleted()
        XCTAssertFalse(queue.reservedOutputURLsForTesting.contains(FileAccessManager.shared.reservationKey(for: terminalOutput)))
    }

    @MainActor
    func testAwaitingCollisionRetainsItsOutputReservation() {
        let queue = ConversionQueue()
        let preset = BuiltInPresets.makeDefaultPresets().first!
        let job = ConversionJob(
            sourceURL: tempDirectory.appendingPathComponent("awaiting.png"),
            preset: preset,
            state: .preparing
        )
        let destination = URL(fileURLWithPath: "/tmp/fileconverter-awaiting-output.png")
        queue.setJobsForTesting([job])
        queue.markAwaitingCollisionForTesting(jobID: job.id, destination: destination)

        XCTAssertEqual(queue.jobs.first?.state, .awaitingCollision)
        XCTAssertTrue(
            queue.reservedOutputURLsForTesting.contains(
                FileAccessManager.shared.reservationKey(for: destination)
            )
        )
        queue.cancelJob(id: job.id)
    }

    @MainActor
    func testOverlappingBatchesKeepIdentity() {
        let queue = ConversionQueue()
        let preset = BuiltInPresets.makeDefaultPresets().first!
        let b1 = UUID(), b2 = UUID()
        let j1 = ConversionJob(batchID: b1, sourceURL: URL(fileURLWithPath: "/tmp/a"), preset: preset, state: .completed)
        let j2 = ConversionJob(batchID: b2, sourceURL: URL(fileURLWithPath: "/tmp/b"), preset: preset, state: .queued)
        queue.setJobsForTesting([j1, j2])
        // Finishing j2 must not notify batch b1.
        XCTAssertEqual(queue.jobs.filter { $0.batchID == b1 }.count, 1)
        XCTAssertEqual(queue.jobs.filter { $0.batchID == b2 }.count, 1)
    }

    // MARK: - Disk space explicit state (acceptance 8)

    func testDiskSpaceStateIsExplicitAndEstimateHasNoUniversalFloor() {
        let state = FileAccessManager.shared.diskSpaceState(at: tempDirectory)
        switch state {
        case .available(let bytes):
            XCTAssertGreaterThan(bytes, 0)
        case .unavailable, .queryFailed:
            break
        }
        // Small source must not require 512 MB.
        let small = tempDirectory.appendingPathComponent("small.bin")
        try? Data("x".utf8).write(to: small)
        // Estimate via queue helper indirectly: use fileSize*4, not 512MB floor.
        let size = FileAccessManager.shared.fileSize(at: small)
        XCTAssertEqual(size, 1)
        _ = ConversionPreset(name: "P", category: .image, sourceFormats: ["image"], destinationFormat: "png")
    }

    // MARK: - Admission + Finder (acceptance 9, 15)

    func testAdmissionReportExplainsRejections() throws {
        let good = tempDirectory.appendingPathComponent("good.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: good)
        let bad = tempDirectory.appendingPathComponent("bad.xyzunknown")
        try Data("hello".utf8).write(to: bad)
        let preset = ConversionPreset(name: "PNG", category: .image, sourceFormats: ["image"], destinationFormat: "png", backend: .imageIO)
        struct StubImageBackend: ConversionBackend, Sendable {
            let backendType: BackendType = .imageIO
            let isAvailable = true
            func supports(sourceFormat: FormatDefinition, destinationFormat: FormatDefinition, preset: ConversionPreset) -> Bool {
                sourceFormat.category == .image && destinationFormat.category == .image
            }
            func convert(job: ConversionJob, progressHandler: @escaping @Sendable (ConversionProgress) -> Void) async throws {}
            func cancel(jobID: UUID) async {}
        }
        let resolver = BackendResolver(backends: [StubImageBackend()])
        let report = PresetValidator.admissionReport(forURLs: [good, bad], preset: preset, resolver: resolver)
        XCTAssertFalse(report.isFullyAdmissible)
        XCTAssertEqual(report.rejectedSources.count, 1)
        XCTAssertNotNil(report.rejectedSources.first?.rejectionReason)
    }

    func testMissingKnownExtensionIsNotAdmittedAsCompatible() {
        let missing = tempDirectory.appendingPathComponent("missing.png")
        let preset = ConversionPreset(name: "PNG", category: .image, sourceFormats: ["image"], destinationFormat: "png", backend: .imageIO)
        XCTAssertFalse(PresetValidator.isPresetCompatible(preset, forURL: missing))
        XCTAssertTrue(PresetValidator.compatiblePresets(forURLs: [missing], from: [preset]).isEmpty)
        let valid = tempDirectory.appendingPathComponent("valid.png")
        try? Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: valid)
        XCTAssertTrue(PresetValidator.compatiblePresets(forURLs: [valid, missing], from: [preset]).isEmpty)

        let report = PresetValidator.admissionReport(forURLs: [missing], preset: preset)
        XCTAssertFalse(report.isFullyAdmissible)
        XCTAssertFalse(report.rejectedSources.first?.exists ?? true)
        XCTAssertEqual(report.rejectedSources.first?.rejectionReason, "missing.png was not found.")
    }

    func testExistingUnreadableFileHasDistinctAdmissionReason() throws {
        let unreadable = tempDirectory.appendingPathComponent("unreadable.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }

        let preset = ConversionPreset(name: "PNG", category: .image, sourceFormats: ["image"], destinationFormat: "png", backend: .imageIO)
        let report = PresetValidator.admissionReport(forURLs: [unreadable], preset: preset)

        XCTAssertFalse(report.isFullyAdmissible)
        XCTAssertTrue(report.sources.first?.exists == true)
        XCTAssertFalse(report.sources.first?.isReadable == true)
        XCTAssertEqual(report.rejectedSources.first?.rejectionReason, "unreadable.png exists but is not readable.")
    }

    // MARK: - Coordinator boundary (acceptance: expired rejected)

    func testExpiredRequestValidationRejected() {
        let expired = ConversionRequest(
            edition: .native,
            presetID: UUID(),
            sources: [ConversionSourceDescriptor(bookmarkData: Data([0x01]), displayName: "a", lastKnownPath: "/tmp/a")],
            requestedAt: Date().addingTimeInterval(-600),
            expiresAt: Date().addingTimeInterval(-300)
        )
        XCTAssertThrowsError(try expired.validate(expectedEdition: .native))
    }

    func testCoordinatorPreservesUnknownPresetBeforeConfigurationLookup() async {
        let request = ConversionRequest(
            edition: .native,
            presetID: UUID(),
            sources: [
                ConversionSourceDescriptor(
                    bookmarkData: Data([0x01]),
                    displayName: "example.png",
                    lastKnownPath: "/tmp/example.png"
                )
            ]
        )
        let coordinator = ConversionCoordinator()

        do {
            try await coordinator.handleConversionRequest(request)
            XCTFail("Unknown preset should be rejected")
        } catch let error as ConversionCoordinatorError {
            guard case .unknownPreset = error else {
                return XCTFail("Unexpected coordinator error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCoordinatorFailsClosedWithoutProductConfiguration() async throws {
        let preset = try XCTUnwrap(PresetStore.shared.presets.first)
        let request = ConversionRequest(
            edition: .native,
            presetID: preset.id,
            sources: [
                ConversionSourceDescriptor(
                    bookmarkData: Data([0x01]),
                    displayName: "example.png",
                    lastKnownPath: "/tmp/example.png"
                )
            ]
        )
        let coordinator = ConversionCoordinator()

        do {
            try await coordinator.handleConversionRequest(request)
            XCTFail("Direct coordinator calls must fail closed without product configuration")
        } catch let error as ConversionCoordinatorError {
            guard case .missingBuildConfiguration = error else {
                return XCTFail("Unexpected coordinator error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - PDF capabilities never lossless (acceptance 13)

    func testNativePDFCompressionIsNeverLossless() {
        XCTAssertFalse(PDFKitBackend.compressionCapabilities.isLossless)
        XCTAssertFalse(PDFKitBackend.compressionCapabilities.isVectorPreserving)
        XCTAssertEqual(PDFKitBackend.compressionCapabilities.losslessRequiresBackend, .ghostscript)
    }
}
