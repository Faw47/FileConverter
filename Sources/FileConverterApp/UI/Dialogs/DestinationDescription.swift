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
}
