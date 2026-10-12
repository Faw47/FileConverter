import Foundation

/// Remembers which preset was last used for each source format and the most
/// recent presets overall, so pickers can start where the user left off.
public enum PresetUsageStore {
    static let key = "fc.presetUsage"
    public static let recentLimit = 8

    private struct Usage: Codable {
        var lastByFormat: [String: UUID] = [:]
        var recent: [UUID] = []
    }

    private static func load(_ defaults: UserDefaults) -> Usage {
        guard let data = defaults.data(forKey: key),
              let usage = try? JSONDecoder().decode(Usage.self, from: data) else { return Usage() }
        return usage
    }

    private static func save(_ usage: Usage, _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(usage) {
            defaults.set(data, forKey: key)
        }
    }

    /// Records that `presetID` was used for files of these formats.
    public static func record(presetID: UUID, sourceFormatIDs: [String], defaults: UserDefaults = ConversionDefaults.store) {
        var usage = load(defaults)
        for formatID in Set(sourceFormatIDs) {
            usage.lastByFormat[formatID] = presetID
        }
        usage.recent.removeAll { $0 == presetID }
        usage.recent.insert(presetID, at: 0)
        if usage.recent.count > recentLimit {
            usage.recent.removeLast(usage.recent.count - recentLimit)
        }
        save(usage, defaults)
    }

    public static func record(presetID: UUID, urls: [URL], defaults: UserDefaults = ConversionDefaults.store) {
        let formats = urls.compactMap { FormatDetector.detect(url: $0).format?.id }
        record(presetID: presetID, sourceFormatIDs: formats, defaults: defaults)
    }

    public static func lastPresetID(forFormat formatID: String, defaults: UserDefaults = ConversionDefaults.store) -> UUID? {
        load(defaults).lastByFormat[formatID]
    }

    public static func recentPresetIDs(defaults: UserDefaults = ConversionDefaults.store) -> [UUID] {
        load(defaults).recent
    }

    /// The last preset used for these files' formats that accepts all of them.
    public static func lastCompatiblePreset(
        for urls: [URL],
        among compatible: [ConversionPreset],
        defaults: UserDefaults = ConversionDefaults.store
    ) -> ConversionPreset? {
        let usage = load(defaults)
        let formats = urls.compactMap { FormatDetector.detect(url: $0).format?.id }
        let candidates = formats.compactMap { usage.lastByFormat[$0] } + usage.recent
        for id in candidates {
            if let preset = compatible.first(where: { $0.id == id }) {
                return preset
            }
        }
        return nil
    }
}
