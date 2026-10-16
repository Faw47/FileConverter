import AppKit
import SwiftUI

/// Where an edge bar sits: along a window's content, or at the bottom of a
/// sheet with its Cancel and confirm buttons.
enum EdgeBarStyle {
    case window
    case sheet
}

/// A bar along the top or bottom of the content. On macOS 26 and later it
/// floats over scrolling content with the system scroll-edge effect, as in
/// Finder and Mail; earlier systems get a bar with a divider.
private struct EdgeBar<Bar: View>: ViewModifier {
    let edge: VerticalEdge
    let style: EdgeBarStyle
    let isPresented: Bool
    let floats: Bool
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        if !isPresented {
            content
        } else if #available(macOS 26, *), !floats || style == .sheet {
            // Beside the content rather than over it: in Settings' split
            // view and in sheets the scroll-edge effect didn't fade rows
            // under a floating bar, so they showed through it.
            VStack(spacing: 0) {
                if edge == .top { paddedBar }
                content
                if edge == .bottom { paddedBar }
            }
        } else if #available(macOS 26, *) {
            content.safeAreaBar(edge: edge) {
                bar()
                    .padding(.horizontal, style == .sheet ? 20 : 16)
                    .padding(.vertical, style == .sheet ? 14 : 10)
            }
        } else {
            VStack(spacing: 0) {
                if edge == .top { fallbackBar; Divider() }
                content
                if edge == .bottom { Divider(); fallbackBar }
            }
        }
    }

    private var paddedBar: some View {
        bar()
            .padding(.horizontal, style == .sheet ? 20 : 12)
            .padding(.vertical, style == .sheet ? 14 : 8)
    }

    @ViewBuilder
    private var fallbackBar: some View {
        switch style {
        case .window:
            bar()
                .controlSize(.small)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.bar)
        case .sheet:
            bar()
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
    }
}

extension View {
    func edgeBar<Bar: View>(
        _ edge: VerticalEdge,
        style: EdgeBarStyle = .window,
        isPresented: Bool = true,
        floats: Bool = true,
        @ViewBuilder _ bar: @escaping () -> Bar
    ) -> some View {
        modifier(EdgeBar(edge: edge, style: style, isPresented: isPresented, floats: floats, bar: bar))
    }

    /// Glass on macOS 26 and later, where the button floats in an edge bar;
    /// the platform's own push button (or bordered prominent) before that.
    @ViewBuilder
    func edgeBarButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            self
        }
    }

    /// Outlines the window or sheet while files are dragged over it. On
    /// macOS 26 and later the outline follows the window's own corners.
    func dropHighlight(_ isTargeted: Bool, _ label: String) -> some View {
        overlay {
            if isTargeted {
                DropOutline(label: label)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct DropOutline: View {
    let label: String

    var body: some View {
        if #available(macOS 26, *) {
            outline(ConcentricRectangle())
        } else {
            outline(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func outline<S: Shape>(_ shape: S) -> some View {
        shape
            .stroke(Color.accentColor, lineWidth: 3)
            .background(shape.fill(Color.accentColor.opacity(0.06)))
            .overlay(Label(label, systemImage: "arrow.down.doc").font(.title3))
    }
}

/// The system search field (magnifying glass, clear button, Esc to clear),
/// for lists that filter in place rather than through the toolbar.
struct SearchField: NSViewRepresentable {
    let prompt: String
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel(prompt)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
