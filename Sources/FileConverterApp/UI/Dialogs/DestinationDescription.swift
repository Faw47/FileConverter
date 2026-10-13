import FileConverterCore
import Foundation

/// Plain-language description of where a preset saves files, using the same
/// resolution the queue uses (including General settings).
enum DestinationDescription {
    static func folder(for preset: ConversionPreset) -> String {
        let policy = EffectivePresetResolver.resolve(preset: preset).outputDirectoryPolicy.value
        switch policy {
        case .sameAsSource:
            return "The same folder as the original"
        case .downloads:
            return "Downloads"
        case .sourceSubfolder(let name):
            return "A “\(name)” folder next to the original"
        case .customFolder(_, let path):
            return (path as NSString).abbreviatingWithTildeInPath
        }
    }

    /// Example output name for the first file, e.g. "Report-compressed.pdf".
    static func exampleName(for preset: ConversionPreset, source: URL?) -> String? {
        guard let source else { return nil }
        return OutputNamingEngine.generateFormattedFilename(
            sourceURL: source,
            preset: preset,
            targetExtension: preset.destinationFormat
        )
    }

    /// One sentence for a dialog footer, e.g. "Saves “Report-web.jpg” next
    /// to the original." With several files the name is an example.
    static func sentence(for preset: ConversionPreset, sources: [URL]) -> String {
        let place: String
        switch EffectivePresetResolver.resolve(preset: preset).outputDirectoryPolicy.value {
        case .sameAsSource: place = "next to the original"
        case .downloads: place = "in Downloads"
        case .sourceSubfolder(let name): place = "in a “\(name)” folder next to the original"
        case .customFolder(_, let path): place = "in \((path as NSString).abbreviatingWithTildeInPath)"
        }
        guard let name = exampleName(for: preset, source: sources.first) else {
            return "Saves \(place)."
        }
        return sources.count > 1
            ? "Saves files like “\(name)” \(place)."
            : "Saves “\(name)” \(place)."
    }
}
