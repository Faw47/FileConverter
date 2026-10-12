import Foundation

/// Carries factory changes to built-in presets that users already have on
/// disk. Stored built-ins keep user edits, so each upgrade changes a field
/// only when it still holds the value the previous factory version shipped.
public enum BuiltInPresetUpgrades {
    public static let currentRevision = 1

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
        }
        preset.factoryRevision = currentRevision
        return preset
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
