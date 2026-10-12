import XCTest
@testable import FileConverterCore

final class StagingArtifactManifestTests: XCTestCase {
    private var tempDirectory: URL!
    private var manifestStorageURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-manifest-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        manifestStorageURL = tempDirectory.appendingPathComponent("test_manifest.json")
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testRegisterAndUnregisterArtifact() throws {
        let manifest = StagingArtifactManifest(storageURL: manifestStorageURL)
        let jobID = UUID()
        let filePath = tempDirectory.appendingPathComponent(".fileconverter-tmp-12345.mp4").path

        manifest.registerArtifact(path: filePath, jobID: jobID, kind: .temporaryFile)

        let entries = manifest.allEntries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.path, URL(fileURLWithPath: filePath).standardizedFileURL.path)
        XCTAssertEqual(entries.first?.jobID, jobID)
        XCTAssertEqual(entries.first?.kind, .temporaryFile)

        manifest.unregisterArtifact(path: filePath)
        XCTAssertTrue(manifest.allEntries.isEmpty)
    }

    func testUnregisterArtifactsForJobID() throws {
        let manifest = StagingArtifactManifest(storageURL: manifestStorageURL)
        let job1 = UUID()
        let job2 = UUID()

        let file1 = tempDirectory.appendingPathComponent(".fileconverter-tmp-1.mp4").path
        let file2 = tempDirectory.appendingPathComponent(".fileconverter-tmp-2.mp4").path
        let file3 = tempDirectory.appendingPathComponent(".fileconverter-tmp-3.mp4").path

        manifest.registerArtifact(path: file1, jobID: job1, kind: .temporaryFile)
        manifest.registerArtifact(path: file2, jobID: job1, kind: .temporaryFile)
        manifest.registerArtifact(path: file3, jobID: job2, kind: .temporaryFile)

        XCTAssertEqual(manifest.entries(for: job1).count, 2)
        XCTAssertEqual(manifest.entries(for: job2).count, 1)

        manifest.unregisterArtifacts(for: job1)
        XCTAssertEqual(manifest.entries(for: job1).count, 0)
        XCTAssertEqual(manifest.entries(for: job2).count, 1)
    }

    func testSweepOrphanedArtifactsDeletesOnlyManifestAndSafeMarkers() throws {
        let priorSessionID = UUID()
        let priorManifest = StagingArtifactManifest(sessionID: priorSessionID, storageURL: manifestStorageURL)

        // 1. Prior session orphaned artifact with valid marker
        let orphanFile = tempDirectory.appendingPathComponent(".fileconverter-tmp-orphan.m4a")
        try "test data".write(to: orphanFile, atomically: true, encoding: .utf8)
        priorManifest.registerArtifact(path: orphanFile.path, jobID: UUID(), kind: .temporaryFile)

        // 2. Prior session orphaned directory with valid marker
        let orphanDir = tempDirectory.appendingPathComponent("FileConverter-LibreOffice-workdir", isDirectory: true)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        let innerFile = orphanDir.appendingPathComponent("dummy.txt")
        try "dummy".write(to: innerFile, atomically: true, encoding: .utf8)
        priorManifest.registerArtifact(path: orphanDir.path, jobID: UUID(), kind: .stagingDirectory)

        // 3. Unrelated file in same temp dir (NOT registered in manifest)
        let userFile = tempDirectory.appendingPathComponent("user_important_doc.pdf")
        try "pdf data".write(to: userFile, atomically: true, encoding: .utf8)

        // 4. Current session artifact with valid marker
        let currentSessionID = UUID()
        let currentFile = tempDirectory.appendingPathComponent(".fileconverter-tmp-current.mp3")
        try "current".write(to: currentFile, atomically: true, encoding: .utf8)

        let currentManifest = StagingArtifactManifest(sessionID: currentSessionID, storageURL: manifestStorageURL)
        currentManifest.registerArtifact(path: currentFile.path, jobID: UUID(), kind: .temporaryFile)

        // Now run sweep on current session
        let deleted = currentManifest.sweepOrphanedArtifacts()

        // Verify orphan file and directory were deleted
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanDir.path))
        XCTAssertEqual(deleted.count, 2)

        // Verify user file and current session file were PRESERVED
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentFile.path))

        // Verify manifest now only contains current session entry
        XCTAssertEqual(currentManifest.allEntries.count, 1)
        XCTAssertEqual(currentManifest.allEntries.first?.sessionID, currentSessionID)
    }

    func testSweepRefusesDangerousOrUnmarkedPaths() throws {
        let priorSessionID = UUID()
        let priorManifest = StagingArtifactManifest(sessionID: priorSessionID, storageURL: manifestStorageURL)

        // File does not have FileConverter ownership marker
        let unmarkedFile = tempDirectory.appendingPathComponent("regular_file.txt")
        try "content".write(to: unmarkedFile, atomically: true, encoding: .utf8)
        priorManifest.registerArtifact(path: unmarkedFile.path, jobID: UUID(), kind: .temporaryFile)

        let currentManifest = StagingArtifactManifest(sessionID: UUID(), storageURL: manifestStorageURL)
        let deleted = currentManifest.sweepOrphanedArtifacts()

        XCTAssertTrue(deleted.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmarkedFile.path))
    }

    func testSweepTemporaryOutputCreatedByOutputNamingEngine() throws {
        let priorSessionID = UUID()
        let priorManifest = StagingArtifactManifest(sessionID: priorSessionID, storageURL: manifestStorageURL)

        let destURL = tempDirectory.appendingPathComponent("document.pdf")
        let tempURL = OutputNamingEngine.createTemporaryOutputURL(for: destURL)
        XCTAssertTrue(tempURL.lastPathComponent.contains(".fileconverter-tmp-"), "Temporary output file must contain .fileconverter-tmp- marker")

        try "test data".write(to: tempURL, atomically: true, encoding: .utf8)
        priorManifest.registerArtifact(path: tempURL.path, jobID: UUID(), kind: .temporaryFile)

        let currentManifest = StagingArtifactManifest(sessionID: UUID(), storageURL: manifestStorageURL)
        let deleted = currentManifest.sweepOrphanedArtifacts()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path), "Orphaned temporary output created by OutputNamingEngine must be swept")
        XCTAssertEqual(deleted.count, 1)
    }
}
