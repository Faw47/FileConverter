import SwiftUI
import FileConverterCore
import UniformTypeIdentifiers

public struct DropZoneView: View {
    public var onSelectFiles: (() -> Void)?
    @Binding private var isDropTargeted: Bool
    @State private var isHovering = false

    public init(onSelectFiles: (() -> Void)? = nil, isDropTargeted: Binding<Bool> = .constant(false)) {
        self.onSelectFiles = onSelectFiles
        self._isDropTargeted = isDropTargeted
    }

    public var body: some View {
        Button(action: {
            onSelectFiles?()
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        (isHovering || isDropTargeted) ? Color.accentColor : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 2, dash: [6])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill((isHovering || isDropTargeted) ? Color.accentColor.opacity(0.08) : Color.clear)
                    )

                VStack(spacing: 8) {
                    Image(systemName: (isHovering || isDropTargeted) ? "arrow.down.doc.fill" : "plus.viewfinder")
                        .font(.system(size: 28))
                        .foregroundStyle((isHovering || isDropTargeted) ? Color.accentColor : Color.secondary)

                    Text((isHovering || isDropTargeted) ? "Drop files to convert" : "Drag and drop files here, or click to choose")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isHovering ? Color.accentColor : Color.secondary)
                }
            }
            .frame(height: 90)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Drop files to convert, or choose files")
        .accessibilityHint("Accepts readable files. Folders and empty files are ignored.")
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
