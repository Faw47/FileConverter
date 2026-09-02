import SwiftUI
import FileConverterCore
import UniformTypeIdentifiers

public struct DropZoneView: View {
    public var onSelectFiles: (() -> Void)?
    @State private var isHovering = false

    public init(onSelectFiles: (() -> Void)? = nil) {
        self.onSelectFiles = onSelectFiles
    }

    public var body: some View {
        Button(action: {
            onSelectFiles?()
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isHovering ? Color.accentColor : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 2, dash: [6])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isHovering ? Color.accentColor.opacity(0.08) : Color.clear)
                    )

                VStack(spacing: 8) {
                    Image(systemName: isHovering ? "arrow.down.doc.fill" : "plus.viewfinder")
                        .font(.system(size: 28))
                        .foregroundColor(isHovering ? .accentColor : .secondary)

                    Text(isHovering ? "Drop files to convert" : "Drag and drop files here, or click to choose")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isHovering ? .accentColor : .secondary)
                }
            }
            .frame(height: 90)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
