import Foundation
import UniformTypeIdentifiers

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

    /// The file URLs in dropped items, in drop order, delivered on the main
    /// queue. Shared by the main window and the PDF dialogs.
    static func fileURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let collector = DropURLCollector()
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    defer { group.leave() }
                    if let url { collector.store(url, at: index) }
                }
            } else {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    if let url = item as? URL {
                        collector.store(url, at: index)
                    } else if let nsURL = item as? NSURL {
                        collector.store(nsURL as URL, at: index)
                    } else if let data = item as? Data {
                        if let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           let url = URL(string: string), url.isFileURL {
                            collector.store(url, at: index)
                        } else if let url = URL(dataRepresentation: data, relativeTo: nil) {
                            collector.store(url, at: index)
                        }
                    }
                }
            }
        }
        group.notify(queue: .main) {
            let urls = collector.orderedURLs().filter { !$0.path.isEmpty }
            MainActor.assumeIsolated { completion(urls) }
        }
    }
}
