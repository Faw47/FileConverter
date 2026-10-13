import FileConverterCore
import SwiftUI

/// What the main window shows when nothing is in the queue. The whole
/// window accepts drops; the highlight is drawn by the window.
public struct DropZoneView: View {
    public var onSelectFiles: (() -> Void)?
    @Binding private var isDropTargeted: Bool

    public init(onSelectFiles: (() -> Void)? = nil, isDropTargeted: Binding<Bool> = .constant(false)) {
        self.onSelectFiles = onSelectFiles
        self._isDropTargeted = isDropTargeted
    }

    public var body: some View {
        ContentUnavailableView {
            Label("Drop Files to Convert", systemImage: "arrow.down.doc")
        } description: {
            Text("Or select files in Finder, right-click, and choose File Converter.")
        } actions: {
            Button("Choose Files…") { onSelectFiles?() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
