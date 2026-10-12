import Foundation

final class DropURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urlsByIndex: [Int: URL] = [:]

    func store(_ url: URL, at index: Int) {
        lock.lock()
        urlsByIndex[index] = url
        lock.unlock()
    }

    func orderedURLs() -> [URL] {
        lock.lock()
        let urls = urlsByIndex.sorted { $0.key < $1.key }.map(\.value)
        lock.unlock()
        return urls
    }
}
