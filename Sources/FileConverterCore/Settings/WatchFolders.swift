import Foundation

/// A folder whose new files convert on their own with one preset.
public struct WatchFolder: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var bookmark: Data?
    public var presetID: UUID
    public var isEnabled: Bool
    /// When File Converter last looked at the folder. Files added after
    /// this, while the app was closed, are converted when it opens again.
    public var lastChecked: Date?

    public init(id: UUID = UUID(), path: String, bookmark: Data? = nil, presetID: UUID, isEnabled: Bool = true, lastChecked: Date? = nil) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.presetID = presetID
        self.isEnabled = isEnabled
        self.lastChecked = lastChecked
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// Results go here, inside the watched folder; the watcher only looks
    /// at the folder's own files, so its output never triggers it again.
    public static let outputSubfolderName = "Converted"

    /// The folder's own files (not hidden, not in subfolders).
    public static func files(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .addedToDirectoryDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
    }

    /// Files that arrived after `since` (by creation or added-to-folder date)
    /// and have no result in the "Converted" subfolder yet.
    public static func filesToCatchUp(in folder: URL, since: Date) -> [URL] {
        let converted = files(in: folder.appendingPathComponent(outputSubfolderName, isDirectory: true))
            .map { $0.deletingPathExtension().lastPathComponent }
        return files(in: folder).filter { url in
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .addedToDirectoryDateKey])
            let arrived = [values?.creationDate, values?.addedToDirectoryDate].compactMap { $0 }.max()
            guard let arrived, arrived > since else { return false }
            let base = url.deletingPathExtension().lastPathComponent
            return !converted.contains { $0 == base || $0.hasPrefix(base + " ") || $0.hasPrefix(base + "-") || $0.hasPrefix(base + "_") }
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

public enum WatchFolderStore {
    static let key = "fc.watchFolders"

    public static func load(defaults: UserDefaults = ConversionDefaults.store) -> [WatchFolder] {
        guard let data = defaults.data(forKey: key),
              let folders = try? JSONDecoder().decode([WatchFolder].self, from: data) else { return [] }
        return folders
    }

    public static func save(_ folders: [WatchFolder], defaults: UserDefaults = ConversionDefaults.store) {
        if let data = try? JSONEncoder().encode(folders) {
            defaults.set(data, forKey: key)
        }
    }

    /// The preset as a watched folder runs it: results into the "Converted"
    /// subfolder, whatever the preset or General settings say.
    public static func presetForWatching(_ preset: ConversionPreset) -> ConversionPreset {
        var watched = preset
        watched.outputDirectoryPolicy = .sourceSubfolder(subfolderName: WatchFolder.outputSubfolderName)
        var inheritance = watched.resolvedInheritance
        inheritance.outputLocation = false
        watched.inheritance = inheritance
        return watched
    }
}
