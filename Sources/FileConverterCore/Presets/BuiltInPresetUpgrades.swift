import Foundation

/// Carries factory changes to built-in presets that users already have on
/// disk. Stored built-ins keep user edits, so each upgrade changes a field
/// only when it still holds the value the previous factory version shipped.
public enum BuiltInPresetUpgrades {
    public static let currentRevision = 2

    private struct Upgrade: Sendable {
        let revision: Int
        let apply: @Sendable (inout ConversionPreset) -> Void
    }

    private static let upgrades: [String: [Upgrade]] = [
        // Revision 1: macOS cannot write WebP, and AVIF writing depends on the
        // OS version, so these presets must be free to use ImageMagick.
        "image.webp": [Upgrade(revision: 1) { replace(\.backend, from: .imageIO, to: .auto, in: &$0) }],
        "image.webp-lossless": [Upgrade(revision: 1) { replace(\.backend, from: .imageIO, to: .auto, in: &$0) }],
        "image.avif": [Upgrade(revision: 1) { replace(\.backend, from: .imageIO, to: .auto, in: &$0) }],
    ]

    /// Applies every upgrade newer than the stored revision and stamps the
    /// preset with the current revision.
    public static func upgrade(_ stored: ConversionPreset) -> ConversionPreset {
        var preset = stored
        let storedRevision = stored.factoryRevision ?? 0
        guard storedRevision < currentRevision else { return stored }
        if let key = stored.builtInKey {
            for upgrade in upgrades[key, default: []] where upgrade.revision > storedRevision {
                upgrade.apply(&preset)
            }
            if let factory = factoryPresets[key] {
                applyNewFields(from: factory, to: &preset, storedRevision: storedRevision)
            }
        }
        preset.factoryRevision = currentRevision
        return preset
    }

    private static let factoryPresets: [String: ConversionPreset] = Dictionary(
        BuiltInPresets.makeDefaultPresets().compactMap { preset in preset.builtInKey.map { ($0, preset) } },
        uniquingKeysWith: { first, _ in first }
    )

    /// Fields introduced after a revision are copied from the factory preset,
    /// since stored presets cannot have edited a field that did not exist.
    private static func applyNewFields(from factory: ConversionPreset, to preset: inout ConversionPreset, storedRevision: Int) {
        if storedRevision < 2, preset.sameFormatSuffix == nil {
            // Revision 2 added `sameFormatSuffix`.
            preset.sameFormatSuffix = factory.sameFormatSuffix
        }
    }

    static func replace<Value: Equatable>(
        _ keyPath: WritableKeyPath<ConversionPreset, Value>,
        from oldValue: Value,
        to newValue: Value,
        in preset: inout ConversionPreset
    ) {
        if preset[keyPath: keyPath] == oldValue {
            preset[keyPath: keyPath] = newValue
        }
    }
}
