import Foundation

public enum FormatCategory: String, Codable, CaseIterable, Sendable, Comparable, Identifiable {
    case video = "video"
    case audio = "audio"
    case image = "image"
    case document = "document"
    case custom = "custom"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        case .image: return "Image"
        case .document: return "Document"
        case .custom: return "Custom Presets"
        }
    }

    public var systemImage: String {
        switch self {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        case .document: return "doc.text"
        case .custom: return "slider.horizontal.3"
        }
    }

    public var sortOrder: Int {
        switch self {
        case .video: return 0
        case .audio: return 1
        case .image: return 2
        case .document: return 3
        case .custom: return 4
        }
    }

    public static func < (lhs: FormatCategory, rhs: FormatCategory) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}
