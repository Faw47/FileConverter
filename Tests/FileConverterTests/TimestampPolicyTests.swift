import XCTest
@testable import FileConverterCore
import FileConverterNativeBackends

@MainActor
final class TimestampPolicyTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var previousStore: UserDefaults!

    override func setUp() async throws {
        directory = try BackendHarness.makeTempDirectory("Timestamps")
        suiteName = "TimestampPolicyTests-\(UUID().uuidString)"
        previousStore = ConversionDefaults.store
        ConversionDefaults.store = UserDefaults(suiteName: suiteName)!
        BackendResolver.shared.configure(backends: NativeBackendCatalog.makeBackends())
    }

    override func tearDown() async throws {
        ConversionDefaults.store.removePersistentDomain(forName: suiteName)
        ConversionDefaults.store = previousStore
        try? FileManager.default.removeItem(at: directory)
    }

    private func convert() async throws -> (source: URL, output: URL) {
        let source = try TestFixtures.copy("same_name/photo.png", to: directory)
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: source.path)
        let queue = ConversionQueue()
        queue.addJobs([ConversionJob(sourceURL: source, preset: try BackendHarness.builtIn("image.jpeg"))])
        for _ in 0..<200 where !(queue.jobs.first?.state.isTerminal ?? false) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let output = try XCTUnwrap(queue.jobs.first?.destinationURL, "\(String(describing: queue.jobs.first?.state))")
        return (source, output)
    }

    private func dates(_ url: URL) throws -> (created: Date, modified: Date) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (try XCTUnwrap(attributes[.creationDate] as? Date), try XCTUnwrap(attributes[.modificationDate] as? Date))
    }

    func testDefaultsKeepCreationDateAndUseFreshModificationDate() async throws {
        let (_, output) = try await convert()
        let result = try dates(output)
        XCTAssertEqual(result.created.timeIntervalSince1970, 1_500_000_000, accuracy: 1)
        XCTAssertGreaterThan(result.modified.timeIntervalSinceNow, -60, "new files should sort first by date")
    }

    func testBothDatesKeptWhenGeneralSaysSo() async throws {
        ConversionDefaults.store.set(true, forKey: ConversionDefaults.Keys.preserveModificationDate)
        let (_, output) = try await convert()
        XCTAssertEqual(try dates(output).modified.timeIntervalSince1970, 1_500_000_000, accuracy: 1)
    }

    func testGeneralToggleOffReachesBuiltInPresets() async throws {
        ConversionDefaults.store.set(false, forKey: ConversionDefaults.Keys.preserveCreationDate)
        let (_, output) = try await convert()
        XCTAssertGreaterThan(try dates(output).created.timeIntervalSinceNow, -60)
    }
}
