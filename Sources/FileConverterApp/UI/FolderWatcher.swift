import AppKit
import FileConverterCore
import Foundation

/// Converts new files that appear in watched folders. Only each folder's
/// own files count (not subfolders), files already there when a folder is
/// added are left alone, files added while the app was closed are caught up
/// at start, and a file is converted once its size has stopped
/// changing, so a copy in progress isn't picked up half-written.
@MainActor
final class FolderWatcher: ObservableObject {
    static let shared = FolderWatcher()

    @Published private(set) var folders: [WatchFolder] = WatchFolderStore.load()

    private var sources: [UUID: DispatchSourceFileSystemObject] = [:]
    private var known: [UUID: Set<String>] = [:]
    private var pending: Set<String> = []

    func start() {
        stopAll()
        let now = Date()
        for index in folders.indices where folders[index].isEnabled {
            watch(folders[index])
            folders[index].lastChecked = now
        }
        WatchFolderStore.save(folders)
    }

    func add(folderURL: URL, presetID: UUID) {
        let bookmark = try? folderURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        folders.append(WatchFolder(path: folderURL.path, bookmark: bookmark, presetID: presetID))
        commit()
    }

    func update(_ folder: WatchFolder) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index] = folder
        commit()
    }

    func remove(id: UUID) {
        folders.removeAll { $0.id == id }
        commit()
    }

    private func commit() {
        WatchFolderStore.save(folders)
        start()
    }

    private func stopAll() {
        sources.values.forEach { $0.cancel() }
        sources.removeAll()
        known.removeAll()
    }

    private func watch(_ folder: WatchFolder) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        known[folder.id] = Set(Self.fileNames(in: folder.url))
        if let lastChecked = folder.lastChecked {
            for url in WatchFolder.filesToCatchUp(in: folder.url, since: lastChecked) {
                waitUntilStable(url, folderID: folder.id, lastSize: -1, checks: 0)
            }
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write], queue: .main)
        let id = folder.id
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged(id: id) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sources[folder.id] = source
    }

    private func folderChanged(id: UUID) {
        guard let folder = folders.first(where: { $0.id == id && $0.isEnabled }) else { return }
        let names = Self.fileNames(in: folder.url)
        let new = Set(names).subtracting(known[id] ?? [])
        known[id, default: []].formUnion(new)
        if let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index].lastChecked = Date()
            WatchFolderStore.save(folders)
        }
        for name in new {
            waitUntilStable(folder.url.appendingPathComponent(name), folderID: id, lastSize: -1, checks: 0)
        }
    }

    private func waitUntilStable(_ url: URL, folderID: UUID, lastSize: Int64, checks: Int) {
        guard !pending.contains(url.path) || checks > 0 else { return }
        pending.insert(url.path)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1)
            if size > 0, size == lastSize {
                pending.remove(url.path)
                convert(url, folderID: folderID)
            } else if size >= 0, checks < 150 {
                waitUntilStable(url, folderID: folderID, lastSize: size, checks: checks + 1)
            } else {
                pending.remove(url.path)
            }
        }
    }

    private func convert(_ url: URL, folderID: UUID) {
        guard let folder = folders.first(where: { $0.id == folderID && $0.isEnabled }),
              let preset = PresetStore.shared.preset(forID: folder.presetID),
              !preset.isInteractiveWorkflow,
              !PresetValidator.compatiblePresets(forURLs: [url], from: [preset]).isEmpty else { return }
        Task {
            try? await AppState.shared.convertFilesWhenReady(urls: [url], preset: WatchFolderStore.presetForWatching(preset))
        }
    }

    private static func fileNames(in folder: URL) -> [String] {
        WatchFolder.files(in: folder).map(\.lastPathComponent)
    }
}
