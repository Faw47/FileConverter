import Foundation

public enum PresetValidator {
    public static func isPresetCompatible(_ preset: ConversionPreset, forURL url: URL) -> Bool {
        let detection = FormatDetector.detect(url: url)
        guard let format = detection.format, !detection.isDirectory else {
            return false
        }
        return isPresetCompatible(preset, forFormat: format)
    }

    public static func isPresetCompatible(_ preset: ConversionPreset, forFormat format: FormatDefinition) -> Bool {
        guard preset.isEnabled else { return false }

        // Source compatibility check
        let lowerSources = Set(preset.sourceFormats.map { $0.lowercased() })
        let matchesCategory = lowerSources.contains(format.category.rawValue.lowercased())
        let matchesFormatID = lowerSources.contains(format.id.lowercased())
        let matchesPrimaryExt = lowerSources.contains(format.primaryExtension.lowercased())
        let matchesAny = lowerSources.contains("*")

        guard matchesCategory || matchesFormatID || matchesPrimaryExt || matchesAny else {
            return false
        }

        return true
    }

    public static func compatiblePresets(
        forURLs urls: [URL],
        from presets: [ConversionPreset] = PresetStore.shared.enabledPresets,
        resolver: BackendResolver = .shared
    ) -> [ConversionPreset] {
        guard !urls.isEmpty else { return [] }

        // Detect format for each URL
        var sourceFormats: [FormatDefinition] = []
        for url in urls {
            let detection = FormatDetector.detect(url: url)
            guard let format = detection.format, !detection.isDirectory else {
                // If any item is unsupported or a folder, no presets match
                return []
            }
            sourceFormats.append(format)
        }

        // Filter presets that are valid for ALL selected formats (Intersection)
        let matchingPresets = presets.filter { preset in
            sourceFormats.allSatisfy { format in
                isPresetCompatible(preset, forFormat: format)
                    && resolver.canResolve(preset: preset, sourceFormat: format)
            }
        }

        return matchingPresets.sorted { $0.sortOrder < $1.sortOrder }
    }

    public static func groupPresetsByCategory(_ presets: [ConversionPreset]) -> [FormatCategory: [ConversionPreset]] {
        var grouped: [FormatCategory: [ConversionPreset]] = [:]
        for preset in presets {
            grouped[preset.category, default: []].append(preset)
        }
        for (cat, list) in grouped {
            grouped[cat] = list.sorted { $0.sortOrder < $1.sortOrder }
        }
        return grouped
    }
}
