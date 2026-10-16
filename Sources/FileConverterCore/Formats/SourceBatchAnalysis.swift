import Foundation

/// One format-detection pass over a batch of dropped files, so views can
/// redraw (and filter on every keystroke) without detecting each file again.
public struct SourceBatchAnalysis: Sendable {
    public let urls: [URL]
    public let recognized: [URL]
    public let unsupported: [URL]
    /// Recognized files by category, in `FormatCategory.allCases` order.
    public let groups: [(category: FormatCategory, urls: [URL])]

    public init(urls: [URL]) {
        self.urls = urls
        var recognized: [URL] = []
        var unsupported: [URL] = []
        var grouped: [FormatCategory: [URL]] = [:]
        for url in urls {
            if let format = FormatDetector.detect(url: url).format {
                recognized.append(url)
                grouped[format.category, default: []].append(url)
            } else {
                unsupported.append(url)
            }
        }
        self.recognized = recognized
        self.unsupported = unsupported
        self.groups = FormatCategory.allCases.compactMap { category in
            grouped[category].map { (category, $0) }
        }
    }
}

/// Remembers a batch analysis and the presets compatible with it, recomputing
/// only when the files or the enabled presets change. A reference type so a
/// SwiftUI view can hold it in `@State` and fill it lazily from `body`.
public final class SourceBatchCache: @unchecked Sendable {
    private var analysis: SourceBatchAnalysis?
    private var compatiblePresetsSeen: [ConversionPreset] = []
    private var compatible: [[URL]: [ConversionPreset]] = [:]
    private var derived: [String: Any] = [:]

    public init() {}

    public func analysis(for urls: [URL]) -> SourceBatchAnalysis {
        if let analysis, analysis.urls == urls { return analysis }
        let fresh = SourceBatchAnalysis(urls: urls)
        analysis = fresh
        compatible.removeAll()
        derived.removeAll()
        return fresh
    }

    /// Presets compatible with `urls`, recomputed only when either input changes.
    public func compatiblePresets(
        forURLs urls: [URL],
        from presets: [ConversionPreset] = PresetStore.shared.enabledPresets
    ) -> [ConversionPreset] {
        if presets != compatiblePresetsSeen {
            compatible.removeAll()
            compatiblePresetsSeen = presets
        }
        if let cached = compatible[urls] { return cached }
        let value = PresetValidator.compatiblePresets(forURLs: urls, from: presets)
        compatible[urls] = value
        return value
    }

    /// Any other per-batch value (such as whether the files can be combined),
    /// computed once until the files change.
    public func value<T>(_ key: String, _ compute: () -> T) -> T {
        if let cached = derived[key] as? T { return cached }
        let value = compute()
        derived[key] = value
        return value
    }
}
