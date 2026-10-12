import AppKit
import SwiftUI

/// The help document, split into blocks SwiftUI can lay out. Only the
/// Markdown that Help.md uses is understood: `#`/`##` headings, `- ` list
/// items, and paragraphs with inline emphasis.
struct HelpDocument: Equatable {
    enum Block: Equatable {
        case title(String)
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    let blocks: [Block]

    init(markdown: String) {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph.removeAll()
            }
        }
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("## ") {
                flush()
                blocks.append(.heading(String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flush()
                blocks.append(.title(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        self.blocks = blocks
    }

    /// Help.md from the app bundle; when running from `swift run`, from the
    /// source tree.
    static func load() -> HelpDocument? {
        var candidates: [URL] = []
        if let url = Bundle.main.url(forResource: "Help", withExtension: "md") {
            candidates.append(url)
        }
        #if DEBUG
        candidates.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Help.md"))
        #endif
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return HelpDocument(markdown: text)
            }
        }
        return nil
    }
}

struct HelpView: View {
    private let document = HelpDocument.load()

    var body: some View {
        ScrollView {
            if let document {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                        view(for: block)
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(24)
                .textSelection(.enabled)
            } else {
                ContentUnavailableView(
                    "Help Is Unavailable",
                    systemImage: "questionmark.circle",
                    description: Text("The help text was not included in this build.")
                )
                .padding(40)
            }
        }
        .frame(minWidth: 420, idealWidth: 620, minHeight: 360, idealHeight: 640)
    }

    @ViewBuilder
    private func view(for block: HelpDocument.Block) -> some View {
        switch block {
        case .title(let text):
            Text(text).font(.largeTitle.bold())
        case .heading(let text):
            Text(text).font(.title2.bold()).padding(.top, 10)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "•").accessibilityHidden(true)
                inline(text)
            }
        case .paragraph(let text):
            inline(text)
        }
    }

    private func inline(_ markdown: String) -> some View {
        let attributed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
        return Text(attributed).fixedSize(horizontal: false, vertical: true)
    }
}

/// Help menu item; a View so it can open the Help window.
struct HelpMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("File Converter Help") {
            openWindow(id: "help")
        }
        .keyboardShortcut("?", modifiers: .command)
    }
}
