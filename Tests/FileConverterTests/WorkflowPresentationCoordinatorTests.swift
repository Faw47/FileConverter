import XCTest
@testable import FileConverterCore

@MainActor
final class WorkflowPresentationCoordinatorTests: XCTestCase {
    var coordinator: WorkflowPresentationCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        coordinator = WorkflowPresentationCoordinator()
    }

    override func tearDown() async throws {
        coordinator.clearAll()
        coordinator = nil
        try await super.tearDown()
    }

    func testInitialState() {
        XCTAssertNil(coordinator.currentPresentation)
        XCTAssertTrue(coordinator.pendingQueue.isEmpty)
        XCTAssertFalse(coordinator.isOpenPanelPresented)
        XCTAssertFalse(coordinator.isAddFilesQueued)
        XCTAssertFalse(coordinator.isPresenting)
        XCTAssertEqual(coordinator.pendingCount, 0)
    }

    func testEnqueueWhenIdlePresentsImmediately() {
        let dummyURL = URL(fileURLWithPath: "/tmp/sample.png")
        let item = WorkflowPresentationItem.batch(urls: [dummyURL], excludedCount: 0)

        coordinator.enqueue(item)

        XCTAssertEqual(coordinator.currentPresentation, item)
        XCTAssertTrue(coordinator.pendingQueue.isEmpty)
        XCTAssertTrue(coordinator.isPresenting)
        XCTAssertEqual(coordinator.pendingCount, 0)
    }

    func testEnqueueWhenBusyAppendsToPendingQueueFIFO() {
        let dummyURL1 = URL(fileURLWithPath: "/tmp/sample1.png")
        let dummyURL2 = URL(fileURLWithPath: "/tmp/sample2.png")
        let dummyURL3 = URL(fileURLWithPath: "/tmp/sample3.png")

        let item1 = WorkflowPresentationItem.batch(urls: [dummyURL1], excludedCount: 0)
        let item2 = WorkflowPresentationItem.batch(urls: [dummyURL2], excludedCount: 1)
        let item3 = WorkflowPresentationItem.batch(urls: [dummyURL3], excludedCount: 2)

        coordinator.enqueue(item1)
        coordinator.enqueue(item2)
        coordinator.enqueue(item3)

        XCTAssertEqual(coordinator.currentPresentation, item1)
        XCTAssertEqual(coordinator.pendingQueue.count, 2)
        XCTAssertEqual(coordinator.pendingQueue[0], item2)
        XCTAssertEqual(coordinator.pendingQueue[1], item3)
        XCTAssertEqual(coordinator.pendingCount, 2)

        // Dismiss current advances to item2
        coordinator.dismissCurrent()
        XCTAssertEqual(coordinator.currentPresentation, item2)
        XCTAssertEqual(coordinator.pendingQueue.count, 1)
        XCTAssertEqual(coordinator.pendingQueue[0], item3)

        // Dismiss current advances to item3
        coordinator.dismissCurrent()
        XCTAssertEqual(coordinator.currentPresentation, item3)
        XCTAssertTrue(coordinator.pendingQueue.isEmpty)

        // Dismiss item3 leaves it idle
        coordinator.dismissCurrent()
        XCTAssertNil(coordinator.currentPresentation)
        XCTAssertFalse(coordinator.isPresenting)
    }

    func testEnqueueWhileOpenPanelIsPresentedBuffersItem() {
        coordinator.isOpenPanelPresented = true
        XCTAssertTrue(coordinator.isPresenting)

        let dummyURL = URL(fileURLWithPath: "/tmp/sample.png")
        let item = WorkflowPresentationItem.batch(urls: [dummyURL], excludedCount: 0)

        coordinator.enqueue(item)
        XCTAssertNil(coordinator.currentPresentation)
        XCTAssertEqual(coordinator.pendingQueue.count, 1)

        coordinator.isOpenPanelPresented = false
        coordinator.advanceQueue()

        XCTAssertEqual(coordinator.currentPresentation, item)
        XCTAssertTrue(coordinator.pendingQueue.isEmpty)
    }

    func testQueueAddFilesWhenPresentingPostsNotificationOnDismiss() {
        let dummyURL = URL(fileURLWithPath: "/tmp/sample.png")
        let item = WorkflowPresentationItem.batch(urls: [dummyURL], excludedCount: 0)
        coordinator.enqueue(item)

        coordinator.queueAddFiles()
        XCTAssertTrue(coordinator.isAddFilesQueued)

        let exp = expectation(forNotification: NSNotification.Name("OpenFileConverterOpenPanel"), object: nil) { _ in
            return true
        }

        coordinator.dismissCurrent()

        wait(for: [exp], timeout: 2.0)
        XCTAssertFalse(coordinator.isAddFilesQueued)
        XCTAssertNil(coordinator.currentPresentation)
    }

    func testQueueAddFilesDoesNothingWhenNotPresenting() {
        coordinator.queueAddFiles()
        XCTAssertFalse(coordinator.isAddFilesQueued)
    }

    func testClearAllResetsEverything() {
        let item1 = WorkflowPresentationItem.batch(urls: [URL(fileURLWithPath: "/tmp/1.png")], excludedCount: 0)
        let item2 = WorkflowPresentationItem.batch(urls: [URL(fileURLWithPath: "/tmp/2.png")], excludedCount: 0)
        coordinator.enqueue(item1)
        coordinator.enqueue(item2)
        coordinator.queueAddFiles()

        XCTAssertNotNil(coordinator.currentPresentation)
        XCTAssertEqual(coordinator.pendingCount, 1)
        XCTAssertTrue(coordinator.isAddFilesQueued)

        coordinator.clearAll()

        XCTAssertNil(coordinator.currentPresentation)
        XCTAssertTrue(coordinator.pendingQueue.isEmpty)
        XCTAssertFalse(coordinator.isAddFilesQueued)
        XCTAssertFalse(coordinator.isPresenting)
    }

    func testWorkflowPresentationItemEqualityAndIDs() {
        let id = UUID()
        let itemA = WorkflowPresentationItem.conflictResolution(id: id, conflicts: [])
        let itemB = WorkflowPresentationItem.conflictResolution(id: id, conflicts: [])
        let itemC = WorkflowPresentationItem.conflictResolution(id: UUID(), conflicts: [])

        XCTAssertEqual(itemA, itemB)
        XCTAssertNotEqual(itemA, itemC)
        XCTAssertEqual(itemA.id, id)
    }
}
