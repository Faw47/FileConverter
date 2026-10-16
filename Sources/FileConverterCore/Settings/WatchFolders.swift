import Foundation

/// A folder whose new files convert on their own with one preset.
public struct WatchFolder: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var bookmark: Data?
    public var presetID: UUID
    public var isEnabled: Bool

    public init(id: UUID = UUID(), path: String, bookmark: Data? = nil, presetID: UUID, isEnabled: Bool = true) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.presetID = presetID
        self.isEnabled = isEnabled
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// Results go here, inside the watched folder; the watcher only looks
    /// at the folder's own files, so its output never triggers it again.
    public static let outputSubfolderName = "Converted"
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
