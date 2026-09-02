import FileConverterContracts
import Foundation
import XCTest
@testable import FileConverterCore

final class FinderIPCDrainTests: XCTestCase {
    private let keyData = Data(repeating: 0xA5, count: 32)
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FinderIPCDrainTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try store.prepareDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testClaimReturnsOnlyFilesAcquiredByThatDrain() throws {
        let pendingRequest = makeRequest()
        let inFlightRequest = makeRequest()
        let pendingFile = pendingDirectory.appendingPathComponent("001-pending.json")
        let inFlightFile = processingDirectory.appendingPathComponent("000-in-flight.json")
        try write(pendingRequest, to: pendingFile)
        try write(inFlightRequest, to: inFlightFile)
        try setModificationDate(now, for: inFlightFile)

        let firstClaims = try store.claimPendingRequests(now: now)
        let secondClaims = try store.claimPendingRequests(now: now)

        XCTAssertEqual(firstClaims.map(\.request.id), [pendingRequest.id])
        XCTAssertTrue(secondClaims.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inFlightFile.path))
        XCTAssertEqual(try jsonFileCount(in: processingDirectory), 2)
    }

    func testProcessingClaimIsRecoveredOnlyAfterLeaseExpires() throws {
        let request = makeRequest()
        let processingFile = processingDirectory.appendingPathComponent("abandoned.json")
        try write(request, to: processingFile)
        try setModificationDate(now.addingTimeInterval(-59), for: processingFile)

        XCTAssertTrue(try store.claimPendingRequests(now: now).isEmpty)

        let recoveredClaims = try store.claimPendingRequests(now: now.addingTimeInterval(2))

        XCTAssertEqual(recoveredClaims.map(\.request.id), [request.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: processingFile.path))
        XCTAssertEqual(try jsonFileCount(in: processingDirectory), 1)
    }

    func testDuplicateRequestUUIDIsReturnedOnceAndQuarantined() throws {
        let request = makeRequest()
        try write(request, to: pendingDirectory.appendingPathComponent("001.json"))
        try write(request, to: pendingDirectory.appendingPathComponent("002.json"))

        let claims = try store.claimPendingRequests(now: now)

        XCTAssertEqual(claims.map(\.request.id), [request.id])
        XCTAssertEqual(try jsonFileCount(in: processingDirectory), 1)
        XCTAssertEqual(try jsonFileCount(in: rejectedDirectory), 1)
    }

    func testUnauthenticatedRequestIsQuarantined() throws {
        let request = makeRequest()
        let otherKey = Data(repeating: 0x5A, count: 32)
        try write(
            request,
            authenticatedWith: otherKey,
            to: pendingDirectory.appendingPathComponent("unauthenticated.json")
        )

        let claims = try store.claimPendingRequests(now: now)

        XCTAssertTrue(claims.isEmpty)
        XCTAssertEqual(try jsonFileCount(in: processingDirectory), 0)
        XCTAssertEqual(try jsonFileCount(in: rejectedDirectory), 1)
    }

    private var store: IPCRequestStore {
        IPCRequestStore(
            requestsRootURL: temporaryDirectory,
            keyData: keyData,
            expectedEdition: .native,
            processingClaimLeaseDuration: 60
        )
    }

    private var pendingDirectory: URL {
        temporaryDirectory.appendingPathComponent("Pending", isDirectory: true)
    }

    private var processingDirectory: URL {
        temporaryDirectory.appendingPathComponent("Processing", isDirectory: true)
    }

    private var rejectedDirectory: URL {
        temporaryDirectory.appendingPathComponent("Rejected", isDirectory: true)
    }

    private func makeRequest(id: UUID = UUID()) -> ConversionRequest {
        ConversionRequest(
            id: id,
            edition: .native,
            presetID: UUID(),
            sources: [
                ConversionSourceDescriptor(
                    bookmarkData: Data([1, 2, 3]),
                    displayName: "example.png",
                    lastKnownPath: "/tmp/example.png"
                )
            ],
            requestedAt: now.addingTimeInterval(-10),
            expiresAt: now.addingTimeInterval(290)
        )
    }

    private func write(
        _ request: ConversionRequest,
        authenticatedWith key: Data? = nil,
        to file: URL
    ) throws {
        let envelope = try ConversionRequestAuthenticator.authenticate(
            request,
            keyData: key ?? keyData
        )
        let data = try ConversionRequestAuthenticator.encoder().encode(envelope)
        try data.write(to: file)
    }

    private func setModificationDate(_ date: Date, for file: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    private func jsonFileCount(in directory: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .count
    }
}
