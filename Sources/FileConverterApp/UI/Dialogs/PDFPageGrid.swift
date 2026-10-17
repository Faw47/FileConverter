import SwiftUI
import PDFKit

/// A rendered page thumbnail that can cross from the renderer to the view.
struct PDFThumbnailImage: @unchecked Sendable {
    let cgImage: CGImage
}

/// Renders page thumbnails away from the main thread. Each PDF is opened
/// once and kept for its other pages; finished thumbnails are cached so
/// scrolling back is instant.
actor PDFThumbnailRenderer {
    static let shared = PDFThumbnailRenderer()

    private var documents: [URL: PDFDocument] = [:]
    private var documentOrder: [URL] = []
    private let cache = NSCache<NSString, CGImage>()

    init() {
        cache.countLimit = 600
    }

    func thumbnail(for url: URL, pageIndex: Int, pixelSize: CGSize) -> PDFThumbnailImage? {
        let key = "\(url.path)#\(pageIndex)@\(Int(pixelSize.width))x\(Int(pixelSize.height))" as NSString
        if let cached = cache.object(forKey: key) { return PDFThumbnailImage(cgImage: cached) }
        guard let page = document(for: url)?.page(at: pageIndex) else { return nil }
        let image = page.thumbnail(of: pixelSize, for: .cropBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        cache.setObject(cgImage, forKey: key)
        return PDFThumbnailImage(cgImage: cgImage)
    }

    private func document(for url: URL) -> PDFDocument? {
        if let cached = documents[url] { return cached }
        guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
        documents[url] = document
        documentOrder.append(url)
        if documentOrder.count > 4 {
            documents.removeValue(forKey: documentOrder.removeFirst())
        }
        return document
    }
}

/// The pages of one PDF as thumbnails. When `isSelectable` is set, clicking
/// turns a page on or off and Shift-click adds a range; otherwise the
/// grid previews what the current split does, dimming pages that are left out.
struct PDFPageGrid: View {
    let documentURL: URL?
    let pageCount: Int
    let isSelectable: Bool
    let selectedPages: Set<Int>
    /// Pages the current choice leaves out of every file.
    let excludedPages: Set<Int>
    /// "File 2" and so on, when a file holds more than one page.
    let fileLabel: (Int) -> String?
    let onClick: (_ page: Int, _ extendingRange: Bool) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 14) {
                ForEach(1...max(1, pageCount), id: \.self) { page in
                    PDFPageGridCell(
                        documentURL: documentURL,
                        pageNumber: page,
                        isSelected: isSelectable && selectedPages.contains(page),
                        isExcluded: !isSelectable && excludedPages.contains(page),
                        caption: isSelectable ? nil : fileLabel(page)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard isSelectable else { return }
                        onClick(page, NSEvent.modifierFlags.contains(.shift))
                    }
                    .accessibilityAddTraits(isSelectable ? .isButton : [])
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
        }
        .frame(minHeight: 260, idealHeight: 320, maxHeight: 360)
    }
}

private struct PDFPageGridCell: View {
    let documentURL: URL?
    let pageNumber: Int
    let isSelected: Bool
    let isExcluded: Bool
    let caption: String?

    @State private var thumbnail: PDFThumbnailImage?
    @Environment(\.displayScale) private var displayScale

    private static let size = CGSize(width: 76, height: 98)

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                if let thumbnail {
                    Image(decorative: thumbnail.cgImage, scale: displayScale)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                } else {
                    Rectangle()
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(Rectangle().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
                        .aspectRatio(8.5 / 11, contentMode: .fit)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .padding(5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                }
            }
            .opacity(isExcluded ? 0.35 : 1)

            Text(label)
                .font(.caption)
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .foregroundStyle(isSelected ? Color.white : (isExcluded ? Color.secondary.opacity(0.6) : Color.secondary))
                .background {
                    if isSelected { Capsule().fill(Color.accentColor) }
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(pageNumber)")
        .accessibilityValue(accessibilityValue)
        .task(id: TaskKey(url: documentURL, page: pageNumber)) {
            guard let documentURL else { return }
            let pixels = CGSize(width: Self.size.width * displayScale, height: Self.size.height * displayScale)
            let image = await PDFThumbnailRenderer.shared.thumbnail(for: documentURL, pageIndex: pageNumber - 1, pixelSize: pixels)
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }

    private var label: String {
        if let caption { return "\(pageNumber) · \(caption)" }
        return "\(pageNumber)"
    }

    private var accessibilityValue: String {
        if isSelected { return "Selected" }
        if isExcluded { return "Left out" }
        return caption ?? ""
    }

    private struct TaskKey: Hashable {
        let url: URL?
        let page: Int
    }
}
