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
