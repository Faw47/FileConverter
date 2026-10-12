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
    public let preserveCreationDate: ProvenancedValue<Bool>
    public let preserveModificationDate: ProvenancedValue<Bool>
    public let removeLocationData: ProvenancedValue<Bool>
    public let quality: QualitySetting
    public let processingOptions: ConversionProcessingOptions?

    public init(
        outputDirectoryPolicy: ProvenancedValue<OutputDirectoryPolicy>,
        customFolderURL: URL? = nil,
        overwritePolicy: ProvenancedValue<OverwritePolicy>,
        filenamePattern: ProvenancedValue<String>,
        preserveMetadata: Bool,
        preserveCreationDate: ProvenancedValue<Bool>,
        preserveModificationDate: ProvenancedValue<Bool>,
        removeLocationData: ProvenancedValue<Bool>,
        quality: QualitySetting,
        processingOptions: ConversionProcessingOptions? = nil
    ) {
        self.outputDirectoryPolicy = outputDirectoryPolicy
        self.customFolderURL = customFolderURL
        self.overwritePolicy = overwritePolicy
        self.filenamePattern = filenamePattern
        self.preserveMetadata = preserveMetadata
        self.preserveCreationDate = preserveCreationDate
        self.preserveModificationDate = preserveModificationDate
        self.removeLocationData = removeLocationData
        self.quality = quality
        self.processingOptions = processingOptions
    }

    /// The preset with every resolved value written in and inheritance
    /// switched off, so code that receives it cannot re-apply General
    /// settings a second time.
    public func applied(to preset: ConversionPreset) -> ConversionPreset {
        var result = preset
        result.outputDirectoryPolicy = outputDirectoryPolicy.value
        result.overwritePolicy = overwritePolicy.value
        result.filenamePattern = filenamePattern.value
        result.preserveCreationDate = preserveCreationDate.value
        result.preserveModificationDate = preserveModificationDate.value
        result.removeLocationData = removeLocationData.value
        result.inheritance = .inheritNone
        return result
    }
}

/// Single source of truth for combining General settings, preset values, and
/// per-job overrides. A preset uses a General value only when its
/// `PresetInheritance` flag for that setting is on.
public enum EffectivePresetResolver {

    public static func resolve(
        preset: ConversionPreset,
        defaults: ConversionDefaults = .current,
        collisionOverride: OverwritePolicy? = nil,
        customFolderURL: URL? = nil
    ) -> ResolvedConversionSettings {
        let inheritance = preset.resolvedInheritance

        func pick<T>(_ inherit: Bool, global: T, own: T) -> ProvenancedValue<T> {
            inherit
                ? ProvenancedValue(value: global, provenance: .globalDefault)
                : ProvenancedValue(value: own, provenance: .presetOverride)
        }

        let overwrite: ProvenancedValue<OverwritePolicy>
        if let collisionOverride {
            overwrite = ProvenancedValue(value: collisionOverride, provenance: .explicitContext)
        } else {
            overwrite = pick(inheritance.collisionPolicy, global: defaults.overwritePolicy, own: preset.overwritePolicy)
        }

        let ownPattern = preset.filenamePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "{name}"
            : preset.filenamePattern

        return ResolvedConversionSettings(
            outputDirectoryPolicy: pick(inheritance.outputLocation, global: defaults.outputDirectoryPolicy, own: preset.outputDirectoryPolicy),
            customFolderURL: customFolderURL,
            overwritePolicy: overwrite,
            filenamePattern: pick(inheritance.filenamePattern, global: defaults.filenamePattern, own: ownPattern),
            preserveMetadata: preset.preserveMetadata,
            preserveCreationDate: pick(inheritance.creationDate, global: defaults.preserveCreationDate, own: preset.preserveCreationDate),
            preserveModificationDate: pick(inheritance.modificationDate, global: defaults.preserveModificationDate, own: preset.preserveModificationDate ?? false),
            removeLocationData: pick(inheritance.locationData, global: defaults.removeLocationData, own: preset.removeLocationData ?? true),
            quality: preset.quality,
            processingOptions: preset.processingOptions
        )
    }
}
