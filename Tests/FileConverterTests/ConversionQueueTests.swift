import XCTest
@testable import FileConverterCore
import FileConverterNativeBackends

final class ConversionQueueTests: XCTestCase {
    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        BackendResolver.shared.configure(backends: NativeBackendCatalog.makeBackends())
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("QueueTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    @MainActor
    func testBatchQueueAdditionAndProgress() {
        let queue = ConversionQueue.shared
        queue.clearCompleted()

        let preset = BuiltInPresets.makeDefaultPresets().first { $0.menuName == "PNG" }!
        let files = (1...5).map { i -> URL in
            let url = tempDirectory.appendingPathComponent("img_\(i).jpg")
            try? "data".write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let jobs = files.map { ConversionJob(sourceURL: $0, preset: preset) }
        queue.addJobs(jobs)

        XCTAssertEqual(queue.jobs.count, 5)
        XCTAssertEqual(queue.queuedCount + queue.activeCount + queue.completedCount + queue.failedCount, 5)

        queue.cancelAll()
        XCTAssertEqual(queue.jobs.filter { $0.state == .cancelled }.count, 5)
        XCTAssertEqual(queue.cancelledCount, 5)
        XCTAssertEqual(queue.failedCount, 0)
    }

    @MainActor
    func testConcurrentJobsReserveUniqueDestinations() async throws {
        let queue = ConversionQueue()
        queue.setMaxConcurrency(2)
        BackendResolver.shared.configure(backends: [TestImageBackend()])

        let firstURL = tempDirectory.appendingPathComponent("first.jpg")
        let secondURL = tempDirectory.appendingPathComponent("second.jpg")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)

        var preset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "image.png" }
        )
        // Custom values below are this preset's own, not General settings.
        preset.inheritance = .inheritNone
        preset.filenamePattern = "shared-output"
        preset.overwritePolicy = .appendNumber
        queue.addJobs([
            ConversionJob(sourceURL: firstURL, preset: preset),
            ConversionJob(sourceURL: secondURL, preset: preset)
        ])

        for _ in 0..<100 where queue.completedCount < 2 && queue.failedCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(queue.completedCount, 2)
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertEqual(
            Set(queue.jobs.compactMap { $0.destinationURL?.lastPathComponent }),
            ["shared-output.png", "shared-output (1).png"]
        )
        queue.clearCompleted()
    }

    @MainActor
    func testAliasedDestinationReservationsRemainUnique() async throws {
        let queue = ConversionQueue()
        queue.setMaxConcurrency(2)
        BackendResolver.shared.configure(backends: [TestImageBackend()])

        let directory = URL(fileURLWithPath: "/private/tmp/FileConverterAlias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURL = URL(fileURLWithPath: "/tmp/\(directory.lastPathComponent)/first.jpg")
        let secondURL = URL(fileURLWithPath: "/private/tmp/\(directory.lastPathComponent)/second.jpg")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)

        var preset = try XCTUnwrap(BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "image.png" })
        // Custom values below are this preset's own, not General settings.
        preset.inheritance = .inheritNone
        preset.filenamePattern = "shared-output"
        preset.overwritePolicy = .appendNumber
        queue.addJobs([
            ConversionJob(sourceURL: firstURL, preset: preset),
            ConversionJob(sourceURL: secondURL, preset: preset)
        ])

        for _ in 0..<100 where queue.completedCount < 2 && queue.failedCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(queue.completedCount, 2)
        XCTAssertEqual(
            Set(queue.jobs.compactMap { $0.destinationURL?.lastPathComponent }),
            ["shared-output.png", "shared-output (1).png"]
        )
        queue.clearCompleted()
    }

    @MainActor
    func testReplaceDecisionReclaimsHeldDestination() async throws {
        let queue = ConversionQueue()
        BackendResolver.shared.configure(backends: [TestImageBackend()])

        let sourceURL = tempDirectory.appendingPathComponent("replace-source.jpg")
        let existingOutput = tempDirectory.appendingPathComponent("replace-target.png")
        try Data("source".utf8).write(to: sourceURL)
        try Data("old".utf8).write(to: existingOutput)

        var preset = try XCTUnwrap(BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "image.png" })
        // Custom values below are this preset's own, not General settings.
        preset.inheritance = .inheritNone
        preset.filenamePattern = "replace-target"
        preset.overwritePolicy = .ask
        let job = ConversionJob(sourceURL: sourceURL, preset: preset, state: .preparing)
        queue.setJobsForTesting([job])
        queue.markAwaitingCollisionForTesting(jobID: job.id, destination: existingOutput)

        XCTAssertTrue(
            queue.reservedOutputURLsForTesting.contains(
                FileAccessManager.shared.reservationKey(for: existingOutput)
            )
        )
        queue.resolveCollisions(.replace, jobIDs: [job.id])

        for _ in 0..<100 where !queue.jobs.allSatisfy({ $0.state.isTerminal }) {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(queue.jobs.first?.state, .completed)
        XCTAssertEqual(queue.jobs.first?.destinationURL, existingOutput)
        XCTAssertNotEqual(try Data(contentsOf: existingOutput), Data("old".utf8))
    }

    @MainActor
    func testSkipCollisionFinishesAsSkippedWithoutReplacingOutput() async throws {
        let queue = ConversionQueue()
        BackendResolver.shared.configure(backends: [TestImageBackend()])

        let sourceURL = tempDirectory.appendingPathComponent("source.jpg")
        try Data("source".utf8).write(to: sourceURL)
        let existingOutput = tempDirectory.appendingPathComponent("existing.png")
        try Data("keep-me".utf8).write(to: existingOutput)

        var preset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "image.png" }
        )
        // Custom values below are this preset's own, not General settings.
        preset.inheritance = .inheritNone
        preset.filenamePattern = "existing"
        preset.overwritePolicy = .skip
        queue.addJobs([ConversionJob(sourceURL: sourceURL, preset: preset)])

        for _ in 0..<100 where !queue.jobs.allSatisfy({ $0.state.isTerminal }) {
            try await Task.sleep(for: .milliseconds(20))
        }

        guard case .skipped = try XCTUnwrap(queue.jobs.first).state else {
            return XCTFail("Expected an existing-output skip to be reported as skipped")
        }
        XCTAssertEqual(try Data(contentsOf: existingOutput), Data("keep-me".utf8))
    }

    @MainActor
    func testReplaceIfNewerCollisionFinishesAsSkippedIfTargetIsNewer() async throws {
        let queue = ConversionQueue()
        BackendResolver.shared.configure(backends: [TestImageBackend()])

        let sourceURL = tempDirectory.appendingPathComponent("older_source.jpg")
        try Data("older source".utf8).write(to: sourceURL)
        let existingOutput = tempDirectory.appendingPathComponent("existing_newer.png")
        try Data("newer target".utf8).write(to: existingOutput)

        let pastDate = Date().addingTimeInterval(-60)
        try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: sourceURL.path)

        var preset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "image.png" }
        )
        // Custom values below are this preset's own, not General settings.
        preset.inheritance = .inheritNone
        preset.filenamePattern = "existing_newer"
        preset.overwritePolicy = .replaceIfNewer
        queue.addJobs([ConversionJob(sourceURL: sourceURL, preset: preset)])

        for _ in 0..<100 where !queue.jobs.allSatisfy({ $0.state.isTerminal }) {
            try await Task.sleep(for: .milliseconds(20))
        }

        guard case .skipped = try XCTUnwrap(queue.jobs.first).state else {
            return XCTFail("Expected older source to be reported as skipped when target is newer")
        }
        XCTAssertEqual(try Data(contentsOf: existingOutput), Data("newer target".utf8))
    }

    @MainActor
    func testReplaceIfNewerReplacesWhenSourceIsNewer() async throws {
        let queue = ConversionQueue()
        BackendResolver.shared.configure(backends: [TestImageBackend()])

        let sourceURL = tempDirectory.appendingPathComponent("newer_source.jpg")
        try Data("newer source".utf8).write(to: sourceURL)
        let existingOutput = tempDirectory.appendingPathComponent("existing_older.png")
        try Data("older target".utf8).write(to: existingOutput)

        let pastDate = Date().addingTimeInterval(-60)
        try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: existingOutput.path)

        var preset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "image.png" }
        )
        // Custom values below are this preset's own, not General settings.
        preset.inheritance = .inheritNone
        preset.filenamePattern = "existing_older"
        preset.overwritePolicy = .replaceIfNewer
        queue.addJobs([ConversionJob(sourceURL: sourceURL, preset: preset)])

        for _ in 0..<100 where !queue.jobs.allSatisfy({ $0.state.isTerminal }) {
            try await Task.sleep(for: .milliseconds(20))
        }

        guard case .completed = try XCTUnwrap(queue.jobs.first).state else {
            return XCTFail("Expected older target to be replaced when source is newer")
        }
        XCTAssertNotEqual(try Data(contentsOf: existingOutput), Data("older target".utf8))
    }

    @MainActor
    func testCollisionPauseClearsLeaseOwnership() async throws {
        let queue = ConversionQueue()
        BackendResolver.shared.configure(backends: [TestImageBackend()])

        let sourceFile = tempDirectory.appendingPathComponent("lease_source.jpg")
        try Data("source".utf8).write(to: sourceFile)

        let bookmark = try sourceFile.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let lease = try SecurityScopedLease(bookmarkData: bookmark)
        XCTAssertTrue(lease.isActive)

        var preset = try XCTUnwrap(BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "image.png" })
        preset.overwritePolicy = .ask
        preset.filenamePattern = "lease_source"
        let job = ConversionJob(
            sourceURL: sourceFile,
            sourceBookmarkData: bookmark,
            sourceAccessLease: lease,
            preset: preset
        )

        queue.setJobsForTesting([job])
        let conflictingOutput = tempDirectory.appendingPathComponent("lease_source.png")
        try Data("existing".utf8).write(to: conflictingOutput)

        // Trigger collision pause
        queue.markAwaitingCollisionForTesting(jobID: job.id, destination: conflictingOutput)

        guard let pausedJob = queue.jobs.first else {
            return XCTFail("Expected job in queue")
        }
        XCTAssertEqual(pausedJob.state, .awaitingCollision)
        // Verify lease ownership was cleared from the paused job (TASK-021 / H2)
        XCTAssertNil(pausedJob.sourceAccessLease)
        // Verify the lease was released and is no longer active
        XCTAssertFalse(lease.isActive)

        // Resolve collision; job must reacquire a fresh lease from bookmark and complete
        queue.resolveCollisions(.replace, jobIDs: [job.id])

        for _ in 0..<100 where !queue.jobs.allSatisfy({ $0.state.isTerminal }) {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(queue.jobs.first?.state, .completed)
        XCTAssertEqual(
            queue.jobs.first?.destinationURL?.resolvingSymlinksInPath(),
            conflictingOutput.resolvingSymlinksInPath()
        )

        // Verify retry of a terminal job resets lease and collisionPlan
        queue.retryJob(id: job.id)
        XCTAssertNil(queue.jobs.first?.sourceAccessLease)
        XCTAssertNil(queue.jobs.first?.collisionPlan)
    }

    @MainActor
    func testMultiOutputCollisionCollectsAllConflicts() async throws {
        let queue = ConversionQueue()
        BackendResolver.shared.configure(backends: [TestMultiOutputBackend()])

        let sourceURL = tempDirectory.appendingPathComponent("multi_source.jpg")
        try Data("source image".utf8).write(to: sourceURL)

        var preset = try XCTUnwrap(BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "image.png" })
        // Custom values below are this preset's own, not General settings.
        preset.inheritance = .inheritNone
        preset.overwritePolicy = .ask
        preset.filenamePattern = "{name}"

        // Pre-create both expected conflicting destination outputs
        let output1 = tempDirectory.appendingPathComponent("multi_source-part-1.png")
        let output2 = tempDirectory.appendingPathComponent("multi_source-part-2.png")
        try Data("existing part 1".utf8).write(to: output1)
        try Data("existing part 2".utf8).write(to: output2)

        let job = ConversionJob(sourceURL: sourceURL, preset: preset)
        queue.addJobs([job])

        for _ in 0..<100 where !queue.jobs.allSatisfy({ $0.state.isTerminal || $0.state == .awaitingCollision }) {
            try await Task.sleep(for: .milliseconds(20))
        }

        guard let pausedJob = queue.jobs.first else {
            return XCTFail("Expected job in queue")
        }
        XCTAssertEqual(pausedJob.state, .awaitingCollision)

        guard let conflict = queue.pendingCollisions.first(where: { $0.jobID == job.id }) else {
            return XCTFail("Expected pending collision for job")
        }

        // Must collect all conflicting outputs in a single preflight pass (TASK-015 / M5)
        XCTAssertEqual(conflict.conflictingURLs.count, 2)
        let conflictFileNames = Set(conflict.conflictingURLs.map(\.lastPathComponent))
        XCTAssertTrue(conflictFileNames.contains("multi_source-part-1.png"))
        XCTAssertTrue(conflictFileNames.contains("multi_source-part-2.png"))
        XCTAssertEqual(conflict.destinationFingerprints.count, 2)
    }

    @MainActor
    func testQueueRejectsDirectorySource() async throws {
        let queue = ConversionQueue()
        let dirURL = tempDirectory.appendingPathComponent("folder_source")
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let preset = BuiltInPresets.makeDefaultPresets().first { $0.menuName == "PNG" }!
        let job = ConversionJob(sourceURL: dirURL, preset: preset)
        queue.addJobs([job])

        for _ in 0..<50 {
            if let current = queue.jobs.first(where: { $0.id == job.id }),
               current.state.isTerminal {
                if case .failed(let error) = current.state {
                    guard case .unsupportedInputFormat(let path, let detectedType) = error else {
                        return XCTFail("Expected unsupportedInputFormat error, got \(error)")
                    }
                    XCTAssertEqual(path, dirURL.path)
                    XCTAssertEqual(detectedType, "Directory")
                    return
                } else {
                    return XCTFail("Expected job to fail, got \(current.state)")
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Job did not complete in time")
    }

    @MainActor
    func testQueueRejectsZeroByteSource() async throws {
        let queue = ConversionQueue()
        let emptyFileURL = tempDirectory.appendingPathComponent("empty.jpg")
        try Data().write(to: emptyFileURL)

        let preset = BuiltInPresets.makeDefaultPresets().first { $0.menuName == "PNG" }!
        let job = ConversionJob(sourceURL: emptyFileURL, preset: preset)
        queue.addJobs([job])

        for _ in 0..<50 {
            if let current = queue.jobs.first(where: { $0.id == job.id }),
               current.state.isTerminal {
                if case .failed(let error) = current.state {
                    guard case .malformedSource(let path, let reason) = error else {
                        return XCTFail("Expected malformedSource error, got \(error)")
                    }
                    XCTAssertEqual(path, emptyFileURL.path)
                    XCTAssertEqual(reason, "File is zero bytes.")
                    return
                } else {
                    return XCTFail("Expected job to fail, got \(current.state)")
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Job did not complete in time")
    }
}

private final class TestMultiOutputBackend: ConversionBackend, Sendable {
    let backendType: BackendType = .imageIO
    let isAvailable = true

    func supports(
        sourceFormat: FormatDefinition,
        destinationFormat: FormatDefinition,
        preset: ConversionPreset
    ) -> Bool {
        sourceFormat.category == .image && destinationFormat.category == .image
    }

    func outputRequirements(for job: ConversionJob) async throws -> [ConversionOutputRequirement] {
        [
            ConversionOutputRequirement(extensionName: "png", suffix: "part-1"),
            ConversionOutputRequirement(extensionName: "png", suffix: "part-2")
        ]
    }

    func convert(
        job: ConversionJob,
        progressHandler: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws {
        progressHandler(ConversionProgress(fractionCompleted: 1))
    }

    func convert(
        job: ConversionJob,
        outputs: [PlannedConversionOutput],
        progressHandler: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws -> BackendConversionResult {
        for output in outputs {
            try Data("multi-output content".utf8).write(to: output.temporaryURL)
        }
        progressHandler(ConversionProgress(fractionCompleted: 1))
        return BackendConversionResult()
    }

    func cancel(jobID: UUID) async {}
}

private final class TestImageBackend: ConversionBackend, Sendable {
    let backendType: BackendType = .imageIO
    let isAvailable = true

    func supports(
        sourceFormat: FormatDefinition,
        destinationFormat: FormatDefinition,
        preset: ConversionPreset
    ) -> Bool {
        sourceFormat.category == .image && destinationFormat.category == .image
    }

    func convert(
        job: ConversionJob,
        progressHandler: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws {
        try await Task.sleep(for: .milliseconds(50))
        guard let outputURL = job.temporaryOutputURL else {
            throw ConversionError.destinationUnavailable(path: "")
        }
        try Data(job.id.uuidString.utf8).write(to: outputURL)
        progressHandler(ConversionProgress(fractionCompleted: 1))
    }

    func cancel(jobID: UUID) async {}
}
