import FileConverterCore
import XCTest

/// Only interruptions the user can act on are shown: the original must
/// still exist and the interruption must be recent.
final class InterruptedConversionTests: XCTestCase {
    private func entry(_ path: String, daysAgo: Double, now: Date) -> JournalEntry {
        JournalEntry(
            id: UUID(), requestID: UUID(), sourceURLPath: path,
            presetID: UUID(), presetName: "PNG", state: .running,
            updatedAt: now.addingTimeInterval(-daysAgo * 24 * 3600)
        )
    }

    func testMissingAndOldEntriesAreNotOffered() {
        let now = Date()
        let recent = entry("/Users/me/photo.jpg", daysAgo: 1, now: now)
        let gone = entry("/var/folders/xx/T/first.jpg", daysAgo: 1, now: now)
        let old = entry("/Users/me/old.mov", daysAgo: 10, now: now)
        let result = ConversionJournal.partitionInterrupted(
            [recent, gone, old], now: now,
            fileExists: { $0.hasPrefix("/Users/me/") }
        )
        XCTAssertEqual(result.actionable, [recent])
        XCTAssertEqual(Set(result.stale.map(\.id)), [gone.id, old.id])
    }
}
