import AppKit
import FileConverterCore
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Puts several PDFs and images into one PDF, in the order given: every
/// page of each PDF, and one page per image.
public enum PDFCombiner {
    /// Two or more files, each a PDF or an image macOS can open.
    public static func canCombine(_ urls: [URL]) -> Bool {
        urls.count >= 2 && urls.allSatisfy(isCombinable)
    }

    static func isCombinable(_ url: URL) -> Bool {
        guard let format = FormatDetector.detect(url: url).format else { return false }
        if format.id == "pdf" { return true }
        // Images macOS itself can read (not, say, PSD through ImageMagick).
        guard format.category == .image,
              let type = UTType(filenameExtension: url.pathExtension),
              let readable = CGImageSourceCopyTypeIdentifiers() as? [String] else { return false }
        return readable.contains(type.identifier)
    }

    /// Writes the combined PDF to `destination`, replacing a file there.
    /// Returns the number of pages.
    @discardableResult
    public static func combine(_ sources: [URL], into destination: URL) throws -> Int {
        let document = PDFDocument()
        for url in sources {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            if url.pathExtension.lowercased() == "pdf" {
                guard let pdf = PDFDocument(url: url) else {
                    throw ConversionError.malformedSource(path: url.path, reason: "Could not open PDF document.")
                }
                guard !pdf.isLocked else {
                    throw ConversionError.malformedSource(path: url.path, reason: "PDF document is password-protected and cannot be processed.")
                }
                for index in 0..<pdf.pageCount {
                    guard let page = pdf.page(at: index)?.copy() as? PDFPage else { continue }
                    document.insert(page, at: document.pageCount)
                }
            } else {
                guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else {
                    throw ConversionError.malformedSource(path: url.path, reason: "Could not read the image.")
                }
                document.insert(page, at: document.pageCount)
            }
        }
        guard document.pageCount > 0 else {
            throw ConversionError.malformedSource(path: destination.path, reason: "There were no pages to combine.")
        }
        // Write beside the destination, then swap it in, so a failure never
        // leaves half a file.
        let folder = destination.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".\(UUID().uuidString).pdf")
        guard document.write(to: temporary) else {
            throw ConversionError.destinationUnavailable(path: destination.path)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        return document.pageCount
    }
}
