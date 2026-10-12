import FileConverterCore
import SwiftUI

/// What the main window shows when nothing is in the queue: one place to
/// drop files or choose them.
public struct DropZoneView: View {
    public var onSelectFiles: (() -> Void)?
    @Binding private var isDropTargeted: Bool

    public init(onSelectFiles: (() -> Void)? = nil, isDropTargeted: Binding<Bool> = .constant(false)) {
        self.onSelectFiles = onSelectFiles
        self._isDropTargeted = isDropTargeted
    }

    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(isDropTargeted ? "Drop to Convert" : "Drop Files Here")
                    .font(.title3.weight(.semibold))
                Text("Or right-click files in Finder and choose File Converter.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Choose Files…") { onSelectFiles?() }
                .controlSize(.large)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                )
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isDropTargeted ? Color.accentColor.opacity(0.07) : Color.clear)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop files to convert, or choose files")
    }
}
