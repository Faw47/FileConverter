import SwiftUI
import FileConverterCore

extension FormatCategory {
    public var color: Color {
        switch self {
        case .video: return .purple
        case .audio: return .orange
        case .image: return .blue
        case .document: return .green
        case .custom: return .pink
        }
    }
}
