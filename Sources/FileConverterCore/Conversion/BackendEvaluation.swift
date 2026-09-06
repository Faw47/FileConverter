import Foundation

/// The result of evaluating a preset against a source and destination.
/// Keeping availability separate from capability prevents the UI and Finder
/// snapshot from advertising conversions that cannot run on this Mac.
public enum BackendEvaluation: Sendable, Equatable {
    case usable(BackendType)
    case unavailable(BackendType)
    case unsupported
    case unknownFormat

    public var isUsable: Bool {
        if case .usable = self { return true }
        return false
    }

    public var backendType: BackendType? {
        switch self {
        case .usable(let type), .unavailable(let type): return type
        case .unsupported, .unknownFormat: return nil
        }
    }
}
