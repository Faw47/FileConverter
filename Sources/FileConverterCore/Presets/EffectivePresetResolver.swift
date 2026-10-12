import Foundation

/// Describes the origin and inheritance source of an effective setting.
public enum SettingProvenance: String, Sendable, Equatable, Codable {
    case globalDefault = "From General settings"
    case presetOverride = "Overridden by this preset"
    case explicitContext = "Set for current conversion"
}

/// A value resolved with its inheritance provenance.
public struct ProvenancedValue<T: Sendable & Equatable>: Sendable, Equatable {
    public let value: T
    public let provenance: SettingProvenance

    public init(value: T, provenance: SettingProvenance) {
        self.value = value
        self.provenance = provenance
    }
}

/// The unified, authoritative set of effective conversion settings computed for a specific job or preview.
public struct ResolvedConversionSettings: Sendable, Equatable {
    public let outputDirectoryPolicy: ProvenancedValue<OutputDirectoryPolicy>
    public let customFolderURL: URL?
    public let overwritePolicy: ProvenancedValue<OverwritePolicy>
    public let filenamePattern: ProvenancedValue<String>
    public let preserveMetadata: Bool
    public let preserveCreationDate: Bool
    public let quality: QualitySetting
    public let processingOptions: ConversionProcessingOptions?

    public init(
        outputDirectoryPolicy: ProvenancedValue<OutputDirectoryPolicy>,
        customFolderURL: URL? = nil,
        overwritePolicy: ProvenancedValue<OverwritePolicy>,
        filenamePattern: ProvenancedValue<String>,
        preserveMetadata: Bool,
        preserveCreationDate: Bool,
        quality: QualitySetting,
        processingOptions: ConversionProcessingOptions? = nil
    ) {
        self.outputDirectoryPolicy = outputDirectoryPolicy
        self.customFolderURL = customFolderURL
        self.overwritePolicy = overwritePolicy
        self.filenamePattern = filenamePattern
        self.preserveMetadata = preserveMetadata
        self.preserveCreationDate = preserveCreationDate
        self.quality = quality
        self.processingOptions = processingOptions
    }
}

/// Single source of truth for resolving effective conversion settings by combining
/// global application defaults with preset configurations and per-job contextual overrides.
public enum EffectivePresetResolver {

    public static func resolve(
        preset: ConversionPreset,
        customFolderURL: URL? = nil,
        collisionOverride: OverwritePolicy? = nil,
        globalOutputPolicy: OutputDirectoryPolicy? = nil,
        globalOverwritePolicy: OverwritePolicy? = nil,
        globalFilenamePattern: String? = nil
    ) -> ResolvedConversionSettings {

        // 1. Output Directory Policy
        let resolvedOutputPolicy: ProvenancedValue<OutputDirectoryPolicy>
        let effectiveGlobalOutput = globalOutputPolicy ?? OutputNamingEngine.globalDefaultOutputPolicy
        if preset.outputDirectoryPolicy == .sameAsSource && effectiveGlobalOutput != .sameAsSource {
            resolvedOutputPolicy = ProvenancedValue(value: effectiveGlobalOutput, provenance: .globalDefault)
        } else {
            resolvedOutputPolicy = ProvenancedValue(value: preset.outputDirectoryPolicy, provenance: .presetOverride)
        }

        // 2. Overwrite / Collision Policy
        let resolvedOverwritePolicy: ProvenancedValue<OverwritePolicy>
        if let collisionOverride = collisionOverride {
            resolvedOverwritePolicy = ProvenancedValue(value: collisionOverride, provenance: .explicitContext)
        } else if let globalOverwrite = globalOverwritePolicy, globalOverwrite != preset.overwritePolicy, preset.isBuiltIn || preset.overwritePolicy == .ask {
            resolvedOverwritePolicy = ProvenancedValue(value: globalOverwrite, provenance: .globalDefault)
        } else {
            resolvedOverwritePolicy = ProvenancedValue(value: preset.overwritePolicy, provenance: .presetOverride)
        }

        // 3. Filename Pattern
        let resolvedFilenamePattern: ProvenancedValue<String>
        let fallbackPattern = globalFilenamePattern ?? UserDefaults.standard.string(forKey: "fc.defaultFilenamePattern")
        if (preset.filenamePattern.isEmpty || preset.filenamePattern == "{name}"),
           let fallback = fallbackPattern,
           !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           fallback != "{name}" {
            resolvedFilenamePattern = ProvenancedValue(value: fallback, provenance: .globalDefault)
        } else {
            let pattern = preset.filenamePattern.isEmpty ? "{name}" : preset.filenamePattern
            resolvedFilenamePattern = ProvenancedValue(value: pattern, provenance: .presetOverride)
        }

        return ResolvedConversionSettings(
            outputDirectoryPolicy: resolvedOutputPolicy,
            customFolderURL: customFolderURL,
            overwritePolicy: resolvedOverwritePolicy,
            filenamePattern: resolvedFilenamePattern,
            preserveMetadata: preset.preserveMetadata,
            preserveCreationDate: preset.preserveCreationDate,
            quality: preset.quality,
            processingOptions: preset.processingOptions
        )
    }
}
