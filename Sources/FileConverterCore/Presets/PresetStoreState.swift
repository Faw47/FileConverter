import Foundation

/// Represents the availability and health state of the preset store.
public enum PresetStoreState: Equatable, Sendable {
    /// Presets are being loaded or reloaded.
    case loading

    /// Presets are loaded, valid, and available for normal reads and mutations.
    case ready

    /// A read, decode, or corruption failure occurred. The store fails closed to protect user data:
    /// no mutations or destructive saves are permitted until an explicit recovery action is taken.
    case recoveryRequired(PresetStoreRecoveryContext)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var isRecoveryRequired: Bool {
        if case .recoveryRequired = self { return true }
        return false
    }

    public var recoveryContext: PresetStoreRecoveryContext? {
        if case .recoveryRequired(let context) = self { return context }
        return nil
    }
}

/// Context provided when the preset store requires user or programmatic recovery.
public struct PresetStoreRecoveryContext: Equatable, Sendable {
    /// Human-readable description of why recovery is required.
    public let errorDescription: String

    /// The exact URL to the damaged primary file on disk.
    public let sourceFileURL: URL

    /// Available File Converter-owned backup candidates.
    public let backupCandidates: [PresetBackupCandidate]

    public init(
        errorDescription: String,
        sourceFileURL: URL,
        backupCandidates: [PresetBackupCandidate]
    ) {
        self.errorDescription = errorDescription
        self.sourceFileURL = sourceFileURL
        self.backupCandidates = backupCandidates
    }
}

/// A discovered backup candidate file for preset recovery.
public struct PresetBackupCandidate: Equatable, Sendable, Identifiable {
    public var id: URL { url }

    /// URL to the backup file.
    public let url: URL

    /// The rotation index (1 is newest, up to 5).
    public let backupNumber: Int

    /// Modification timestamp of the backup file.
    public let modificationDate: Date?

    /// Number of valid presets inside this backup, or 0 if corrupt.
    public let presetCount: Int

    /// Whether this backup file successfully decodes and passes validation.
    public let isValid: Bool

    public init(
        url: URL,
        backupNumber: Int,
        modificationDate: Date?,
        presetCount: Int,
        isValid: Bool
    ) {
        self.url = url
        self.backupNumber = backupNumber
        self.modificationDate = modificationDate
        self.presetCount = presetCount
        self.isValid = isValid
    }
}
