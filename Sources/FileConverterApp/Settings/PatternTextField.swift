import AppKit
import SwiftUI

/// Inserts text into a `PatternTextField` at its caret.
@MainActor
final class PatternFieldController: ObservableObject {
    fileprivate weak var field: NSTextField?

    func insert(_ token: String) {
        guard let field else { return }
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertText(token, replacementRange: editor.selectedRange())
        } else {
            field.window?.makeFirstResponder(field)
            if let editor = field.currentEditor() as? NSTextView {
                editor.moveToEndOfDocument(nil)
                editor.insertText(token, replacementRange: editor.selectedRange())
            } else {
                field.stringValue += token
            }
        }
        // insertText updates the editor; push the new value to the binding.
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
    }
}

/// Monospaced single-line field that reports edits live and commits when
/// editing ends (Return or focus loss).
struct PatternTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var controller: PatternFieldController
    var onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.setAccessibilityLabel("Filename pattern")
        controller.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        controller.field = field
        if field.stringValue != text, field.currentEditor() == nil {
            field.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PatternTextField

        init(_ parent: PatternTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onCommit()
        }
    }
}
