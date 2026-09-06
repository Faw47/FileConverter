import XCTest
@testable import FileConverterCore
@testable import FileConverterExternalBackends

final class ExternalProcessRunnerTests: XCTestCase {
    func testRunnerDrainsMoreThanPipeCapacityAndBoundsCapturedOutput() async throws {
        let command = """
        i=0
        while [ "$i" -lt 5000 ]; do
            printf 'stdout-payload-%05d-abcdefghijklmnopqrstuvwxyz\n' "$i"
            printf 'stderr-payload-%05d-abcdefghijklmnopqrstuvwxyz\n' "$i" >&2
            i=$((i + 1))
        done
        printf 'stdout-tail-marker\n'
        printf 'stderr-tail-marker\n' >&2
        """
        let process = ExternalProcessAttempt(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command],
            stdoutCaptureLimit: 2 * 1024,
            stderrCaptureLimit: 4 * 1024
        )

        let result = try await process.run()

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertLessThanOrEqual(result.stdout.count, 2 * 1024)
        XCTAssertLessThanOrEqual(result.stderr.utf8.count, 4 * 1024)
        XCTAssertTrue(String(decoding: result.stdout, as: UTF8.self).contains("stdout-tail-marker"))
        XCTAssertTrue(result.stderr.contains("stderr-tail-marker"))
    }

    func testTaskCancellationTerminatesChildAndWaitsForExit() async throws {
        let process = ExternalProcessAttempt(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            terminationGracePeriod: 0.2
        )
        let task = Task {
            try await process.run()
        }

        try await waitUntilLaunched(process)
        let cancellationStartedAt = Date()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled process should not return successfully")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }

        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(cancellationStartedAt), 3)
    }

    func testCancellationBeforeLaunchDoesNotLaunchProcess() async {
        let process = ExternalProcessAttempt(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"]
        )
        process.cancel()

        do {
            _ = try await process.run()
            XCTFail("A pre-cancelled process should not launch")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }

        XCTAssertFalse(process.hasLaunched)
        XCTAssertFalse(process.isRunning)
    }

    func testRegistryCancellationIsIdempotentAndRetainedUntilTermination() async throws {
        let ready = expectation(description: "Process installed its signal handler")
        let process = ExternalProcessAttempt(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; printf 'ready\\n'; exec /bin/sleep 30"],
            terminationGracePeriod: 0.2,
            stdoutLineHandler: { line in
                if line == "ready" {
                    ready.fulfill()
                }
            }
        )
        let registry = ExternalProcessRegistry()
        let jobID = UUID()
        let task = Task {
            try await registry.run(process, for: jobID)
        }

        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(registry.activeAttemptCount(for: jobID), 1)
        registry.cancel(jobID: jobID)
        registry.cancel(jobID: jobID)
        XCTAssertEqual(registry.activeAttemptCount(for: jobID), 1)

        do {
            _ = try await task.value
            XCTFail("A registry-cancelled process should not return successfully")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }

        XCTAssertEqual(registry.activeAttemptCount(for: jobID), 0)
        XCTAssertFalse(process.isRunning)
    }

    private func waitUntilLaunched(_ process: ExternalProcessAttempt) async throws {
        for _ in 0..<200 {
            if process.hasLaunched {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ProcessTestError.launchTimedOut
    }
}

final class LibreOfficeBackendHardeningTests: XCTestCase {
    private var testDirectory: URL!
    private var stagingParentURL: URL!

    override func setUpWithError() throws {
        testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LibreOfficeBackendHardeningTests-\(UUID().uuidString)",
            isDirectory: true
        )
        stagingParentURL = testDirectory.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingParentURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDirectory)
    }

    func testConversionUsesUniqueStagingAndProfileWithoutTouchingFinalDestination() async throws {
        let executableURL = try makeFakeLibreOffice(producesOutput: true)
        let backend = LibreOfficeBackend(
            executableURL: executableURL,
            stagingDirectoryParentURL: stagingParentURL
        )
        let sourceURL = testDirectory.appendingPathComponent("report.docx")
        let finalDestinationURL = testDirectory.appendingPathComponent("report.pdf")
        let firstTemporaryURL = testDirectory.appendingPathComponent("first-temporary.pdf")
        let secondTemporaryURL = testDirectory.appendingPathComponent("second-temporary.pdf")
        try Data("source".utf8).write(to: sourceURL)
        try Data("existing-final".utf8).write(to: finalDestinationURL)

        for temporaryURL in [firstTemporaryURL, secondTemporaryURL] {
            let job = ConversionJob(
                sourceURL: sourceURL,
                destinationURL: finalDestinationURL,
                temporaryOutputURL: temporaryURL,
                preset: makePDFPreset()
            )
            try await backend.convert(job: job) { _ in }
            XCTAssertEqual(try String(contentsOf: temporaryURL, encoding: .utf8), "converted")
        }

        XCTAssertEqual(try String(contentsOf: finalDestinationURL, encoding: .utf8), "existing-final")

        let outputDirectories = try recordedLines(named: "outdirs.txt")
        let profileURLs = try recordedLines(named: "profiles.txt")
        XCTAssertEqual(outputDirectories.count, 2)
        XCTAssertEqual(profileURLs.count, 2)
        XCTAssertEqual(Set(outputDirectories).count, 2)
        XCTAssertEqual(Set(profileURLs).count, 2)

        for (outputDirectory, profile) in zip(outputDirectories, profileURLs) {
            let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            let profileURL = try XCTUnwrap(URL(string: profile))
            XCTAssertTrue(outputURL.path.hasPrefix(stagingParentURL.path + "/"))
            XCTAssertEqual(
                outputURL.deletingLastPathComponent().standardizedFileURL,
                profileURL.deletingLastPathComponent().standardizedFileURL
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: profileURL.path))
        }
    }

    func testSuccessfulExitWithoutExpectedOutputFailsAndCleansStaging() async throws {
        let executableURL = try makeFakeLibreOffice(producesOutput: false)
        let backend = LibreOfficeBackend(
            executableURL: executableURL,
            stagingDirectoryParentURL: stagingParentURL
        )
        let sourceURL = testDirectory.appendingPathComponent("missing.docx")
        let temporaryURL = testDirectory.appendingPathComponent("missing-temporary.pdf")
        try Data("source".utf8).write(to: sourceURL)
        let job = ConversionJob(
            sourceURL: sourceURL,
            destinationURL: testDirectory.appendingPathComponent("missing.pdf"),
            temporaryOutputURL: temporaryURL,
            preset: makePDFPreset()
        )

        do {
            try await backend.convert(job: job) { _ in }
            XCTFail("LibreOffice success without the expected output should fail")
        } catch let error as ConversionError {
            guard case .externalToolFailed(let tool, let exitCode, _) = error else {
                return XCTFail("Unexpected conversion error: \(error)")
            }
            XCTAssertEqual(tool, "LibreOffice")
            XCTAssertEqual(exitCode, 0)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        for outputDirectory in try recordedLines(named: "outdirs.txt") {
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory))
        }
    }

    func testMoveDoesNotReplaceExistingTemporaryOutput() async throws {
        let executableURL = try makeFakeLibreOffice(producesOutput: true)
        let backend = LibreOfficeBackend(
            executableURL: executableURL,
            stagingDirectoryParentURL: stagingParentURL
        )
        let sourceURL = testDirectory.appendingPathComponent("collision.docx")
        let temporaryURL = testDirectory.appendingPathComponent("collision-temporary.pdf")
        try Data("source".utf8).write(to: sourceURL)
        try Data("existing-temporary".utf8).write(to: temporaryURL)
        let job = ConversionJob(
            sourceURL: sourceURL,
            destinationURL: testDirectory.appendingPathComponent("collision.pdf"),
            temporaryOutputURL: temporaryURL,
            preset: makePDFPreset()
        )

        do {
            try await backend.convert(job: job) { _ in }
            XCTFail("Moving over an existing temporary output should throw")
        } catch {
        }

        XCTAssertEqual(try String(contentsOf: temporaryURL, encoding: .utf8), "existing-temporary")
        for outputDirectory in try recordedLines(named: "outdirs.txt") {
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory))
        }
    }

    private func makeFakeLibreOffice(producesOutput: Bool) throws -> URL {
        let executableURL = testDirectory.appendingPathComponent("fake-soffice")
        let outputCommand = producesOutput
            ? "printf 'converted' > \"$outdir/$stem.$output_extension\""
            : ":"
        let script = """
        #!/bin/sh
        script_directory=${0%/*}
        outdir=''
        profile=''
        format=''
        source=''
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --outdir)
                    outdir=$2
                    shift 2
                    ;;
                --convert-to)
                    format=$2
                    shift 2
                    ;;
                -env:UserInstallation=*)
                    profile=${1#-env:UserInstallation=}
                    shift
                    ;;
                --headless)
                    shift
                    ;;
                *)
                    source=$1
                    shift
                    ;;
            esac
        done
        printf '%s\n' "$outdir" >> "$script_directory/outdirs.txt"
        printf '%s\n' "$profile" >> "$script_directory/profiles.txt"
        base=${source##*/}
        stem=${base%.*}
        output_extension=${format%%:*}
        \(outputCommand)
        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        return executableURL
    }

    private func makePDFPreset() -> ConversionPreset {
        ConversionPreset(
            name: "PDF",
            category: .document,
            sourceFormats: ["docx"],
            destinationFormat: "pdf",
            backend: .libreOffice
        )
    }

    private func recordedLines(named filename: String) throws -> [String] {
        let content = try String(
            contentsOf: testDirectory.appendingPathComponent(filename),
            encoding: .utf8
        )
        return content.split(whereSeparator: \.isNewline).map(String.init)
    }
}

final class CalibreBackendTests: XCTestCase {
    private var testDirectory: URL!

    override func setUpWithError() throws {
        testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CalibreBackendTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDirectory)
    }

    func testEPUBToPDFUsesDedicatedConverterAndTemporaryDestination() async throws {
        let executableURL = try makeFakeCalibre()
        let sourceURL = testDirectory.appendingPathComponent("book.epub")
        let temporaryURL = testDirectory.appendingPathComponent(".book.converting.pdf")
        try Data("EPUB fixture".utf8).write(to: sourceURL)

        let backend = CalibreBackend(executableURL: executableURL)
        let preset = ConversionPreset(
            name: "EPUB to PDF",
            category: .document,
            sourceFormats: ["epub"],
            destinationFormat: "pdf",
            backend: .calibre
        )
        let job = ConversionJob(
            sourceURL: sourceURL,
            destinationURL: testDirectory.appendingPathComponent("book.pdf"),
            temporaryOutputURL: temporaryURL,
            preset: preset
        )

        try await backend.convert(job: job) { _ in }

        XCTAssertEqual(try Data(contentsOf: temporaryURL), Data("fake PDF".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.destinationURL!.path))
    }

    private func makeFakeCalibre() throws -> URL {
        let executableURL = testDirectory.appendingPathComponent("fake-ebook-convert")
        let script = """
        #!/bin/sh
        printf 'fake PDF' > "$2"
        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        return executableURL
    }
}

final class FFmpegWorkflowIntegrationTests: XCTestCase {
    private var testDirectory: URL!

    override func setUpWithError() throws {
        testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FFmpegWorkflowIntegrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        ExternalToolDiscovery.shared.refreshAllTools(force: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDirectory)
    }

    func testAudioSplitAndTargetSizeWorkflowsWithInstalledFFmpeg() async throws {
        guard let ffmpegPath = ExternalToolDiscovery.shared.executablePath(for: "ffmpeg"),
              ExternalToolDiscovery.shared.executablePath(for: "ffprobe") != nil else {
            throw XCTSkip("FFmpeg and ffprobe are required for this optional integration test.")
        }
        let sourceURL = testDirectory.appendingPathComponent("source.wav")
        let fixtureProcess = ExternalProcessAttempt(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: [
                "-y", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
                "-t", "21", "-c:a", "pcm_s16le", sourceURL.path
            ],
            timeout: 60
        )
        let fixtureResult = try await fixtureProcess.run()
        XCTAssertEqual(fixtureResult.terminationStatus, 0, fixtureResult.stderr)

        let backend = FFmpegBackend()
        var splitPreset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "audio.split-mp3-5min" }
        )
        splitPreset.audioSplitDurationSeconds = 10
        let splitJob = ConversionJob(sourceURL: sourceURL, preset: splitPreset)
        let requirements = try await backend.outputRequirements(for: splitJob)
        XCTAssertEqual(requirements.count, 3)
        let splitOutputs = requirements.enumerated().map { index, _ in
            PlannedConversionOutput(
                finalURL: testDirectory.appendingPathComponent("part-\(index + 1).mp3"),
                temporaryURL: testDirectory.appendingPathComponent(".part-\(index + 1).mp3")
            )
        }

        _ = try await backend.convert(job: splitJob, outputs: splitOutputs) { _ in }
        XCTAssertTrue(splitOutputs.allSatisfy {
            FileManager.default.fileExists(atPath: $0.temporaryURL.path)
                && FileAccessManager.shared.fileSize(at: $0.temporaryURL) > 0
        })

        var targetPreset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "audio.fit-5mb" }
        )
        targetPreset.audioTargetFileSizeBytes = 350_000
        let targetTemporaryURL = testDirectory.appendingPathComponent(".sized.m4a")
        let targetJob = ConversionJob(
            sourceURL: sourceURL,
            destinationURL: testDirectory.appendingPathComponent("sized.m4a"),
            temporaryOutputURL: targetTemporaryURL,
            preset: targetPreset
        )

        let targetProgress = ProgressCollector()
        try await backend.convert(job: targetJob) { progress in
            targetProgress.append(progress.fractionCompleted)
        }
        XCTAssertGreaterThan(FileAccessManager.shared.fileSize(at: targetTemporaryURL), 0)
        XCTAssertLessThanOrEqual(
            FileAccessManager.shared.fileSize(at: targetTemporaryURL),
            Int64(try XCTUnwrap(targetPreset.audioTargetFileSizeBytes))
        )
        XCTAssertEqual(targetProgress.values.last, 1.0)
        XCTAssertTrue(targetProgress.values.dropLast().allSatisfy { $0 < 1.0 })
    }
}

private enum ProcessTestError: Error {
    case launchTimedOut
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }
}
