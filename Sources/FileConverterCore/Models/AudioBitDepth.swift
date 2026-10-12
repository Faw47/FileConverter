import Foundation

public enum AudioBitDepth: String, Codable, CaseIterable, Sendable {
    case bit16 = "16"
    case bit24 = "24"
    case bit32Float = "32float"

    public var displayName: String {
        switch self {
        case .bit16: return "16-bit"
        case .bit24: return "24-bit"
        case .bit32Float: return "32-bit float"
        }
    }

    public var bitDepthNumber: Int {
        switch self {
        case .bit16: return 16
        case .bit24: return 24
        case .bit32Float: return 32
        }
    }

    public var isFloat: Bool {
        self == .bit32Float
    }

    public var ffmpegWavCodec: String {
        switch self {
        case .bit16: return "pcm_s16le"
        case .bit24: return "pcm_s24le"
        case .bit32Float: return "pcm_f32le"
        }
    }

    public var ffmpegAiffCodec: String {
        switch self {
        case .bit16: return "pcm_s16be"
        case .bit24: return "pcm_s24be"
        case .bit32Float: return "pcm_f32be"
        }
    }

    public init?(ffmpegCodec: String) {
        switch ffmpegCodec.lowercased() {
        case "pcm_s16le", "pcm_s16be", "s16", "16":
            self = .bit16
        case "pcm_s24le", "pcm_s24be", "s24", "24":
            self = .bit24
        case "pcm_f32le", "pcm_f32be", "f32", "32", "32float":
            self = .bit32Float
        default:
            return nil
        }
    }
}
