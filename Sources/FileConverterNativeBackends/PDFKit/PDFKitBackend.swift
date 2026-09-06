import Foundation
import PDFKit
import CoreGraphics
import AppKit
import FileConverterCore

public final class PDFKitBackend: ConversionBackend, @unchecked Sendable {
    public let backendType: BackendType = .pdfKit
    public var isAvailable: Bool { true }

    private enum TextPDFSource: Sendable {
        case plainText(String)
        case richText(Data, sourcePath: String)
    }

    private var cancelledJobs = Set<UUID>()
    private let lock = NSLock()

    public init() {}

    public func supports(sourceFormat: FormatDefinition, destinationFormat: FormatDefinition, preset: ConversionPreset) -> Bool {
        if preset.splitPDFIntoPages {
            return sourceFormat.id == "pdf" && destinationFormat.id == "pdf"
        }
        if destinationFormat.id == "pdf" {
            // PDF-to-PDF is intentionally not advertised: it is a no-op and
            // previously hid unsupported document rendering paths.
            return sourceFormat.category == .image || sourceFormat.id == "txt" || sourceFormat.id == "rtf" || sourceFormat.id == "html"
        }
        if sourceFormat.id == "pdf" {
            // Can extract PDF pages to image (png, jpg, tiff)
            return destinationFormat.category == .image
        }
        return false
    }

    private func markCancelled(jobID: UUID) {
        lock.lock()
        cancelledJobs.insert(jobID)
        lock.unlock()
    }

    private func clearCancelled(jobID: UUID) {
        lock.lock()
        cancelledJobs.remove(jobID)
        lock.unlock()
    }

    private func checkCancelled(jobID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledJobs.contains(jobID)
    }

    public func cancel(jobID: UUID) async {
        markCancelled(jobID: jobID)
    }

    public func outputRequirements(for job: ConversionJob) async throws -> [ConversionOutputRequirement] {
        guard FormatDetector.detect(url: job.sourceURL).format?.id == "pdf" else {
            return [ConversionOutputRequirement(extensionName: job.preset.destinationFormat)]
        }
        guard let document = PDFDocument(url: job.sourceURL), document.pageCount > 0 else {
            throw ConversionError.malformedSource(path: job.sourceURL.path, reason: "PDF document contains no readable pages.")
        }
        let destinationIsImage = FormatRegistry.shared.format(forID: job.preset.destinationFormat)?.category == .image
        guard destinationIsImage || job.preset.splitPDFIntoPages else {
            return [ConversionOutputRequirement(extensionName: job.preset.destinationFormat)]
        }
        return (0..<document.pageCount).map { index in
            ConversionOutputRequirement(
                extensionName: job.preset.destinationFormat,
                suffix: ConversionOutputSequence.suffix(
                    prefix: "page",
                    index: index + 1,
                    totalCount: document.pageCount,
                    minimumWidth: 3
                )
            )
        }
    }

    public func convert(
        job: ConversionJob,
        outputs: [PlannedConversionOutput],
        progressHandler: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws -> BackendConversionResult {
        guard FormatDetector.detect(url: job.sourceURL).format?.id == "pdf" else {
            try await convert(job: job, progressHandler: progressHandler)
            return BackendConversionResult()
        }

        let jobID = job.id
        clearCancelled(jobID: jobID)
        defer { clearCancelled(jobID: jobID) }

        guard let pdfDoc = PDFDocument(url: job.sourceURL), pdfDoc.pageCount == outputs.count else {
            throw ConversionError.malformedSource(path: job.sourceURL.path, reason: "Could not parse all PDF pages.")
        }
        let start = Date()
        for (index, output) in outputs.enumerated() {
            if checkCancelled(jobID: jobID) {
                throw ConversionError.cancelled
            }
            try Task.checkCancellation()
            if job.preset.splitPDFIntoPages {
                try writePage(pdfDoc.page(at: index), to: output.temporaryURL)
            } else {
                try renderPage(pdfDoc.page(at: index), to: output.temporaryURL, targetFormat: job.preset.destinationFormat)
            }
            if checkCancelled(jobID: jobID) {
                throw ConversionError.cancelled
            }
            progressHandler(ConversionProgress(
                fractionCompleted: Double(index + 1) / Double(outputs.count),
                elapsedTime: Date().timeIntervalSince(start)
            ))
        }
        return BackendConversionResult()
    }

    public func convert(job: ConversionJob, progressHandler: @escaping @Sendable (ConversionProgress) -> Void) async throws {
        let jobID = job.id
        clearCancelled(jobID: jobID)
        defer { clearCancelled(jobID: jobID) }

        let sourceURL = job.sourceURL
        guard let destURL = job.temporaryOutputURL ?? job.destinationURL else {
            throw ConversionError.destinationUnavailable(path: "")
        }

        let isCancelled = { [weak self] () -> Bool in
            guard let self = self else { return false }
            return self.checkCancelled(jobID: jobID)
        }

        if isCancelled() { throw ConversionError.cancelled }

        progressHandler(ConversionProgress(fractionCompleted: 0.1, elapsedTime: 0.1))

        let targetFormat = job.preset.destinationFormat.lowercased()

        if targetFormat == "pdf" {
            // Convert source to PDF
            try await convertToPDF(sourceURL: sourceURL, destURL: destURL, isCancelled: isCancelled, progressHandler: progressHandler)
        } else if FormatDetector.detect(url: job.sourceURL).format?.id == "pdf" {
            // Convert PDF to Image
            try convertPDFToImage(sourceURL: sourceURL, destURL: destURL, targetFormat: targetFormat, isCancelled: isCancelled, progressHandler: progressHandler)
        } else {
            throw ConversionError.incompatibleConversion(sourceFormat: sourceURL.pathExtension, targetFormat: targetFormat)
        }
    }

    private func convertToPDF(
        sourceURL: URL,
        destURL: URL,
        isCancelled: () -> Bool,
        progressHandler: (ConversionProgress) -> Void
    ) async throws {
        let ext = sourceURL.pathExtension.lowercased()

        if ext == "txt" {
            let text: String
            do {
                text = try String(contentsOf: sourceURL, encoding: .utf8)
            } catch {
                throw ConversionError.malformedSource(path: sourceURL.path, reason: "Could not read UTF-8 text.")
            }
            try await Self.renderTextToPDF(.plainText(text), destURL: destURL)
            progressHandler(ConversionProgress(fractionCompleted: 1.0, elapsedTime: 0.5))
            return
        }

        if ext == "rtf" {
            guard let data = try? Data(contentsOf: sourceURL) else {
                throw ConversionError.malformedSource(path: sourceURL.path, reason: "Could not read RTF document.")
            }
            try await Self.renderTextToPDF(.richText(data, sourcePath: sourceURL.path), destURL: destURL)
            progressHandler(ConversionProgress(fractionCompleted: 1.0, elapsedTime: 0.5))
            return
        }

        if ext == "html" || ext == "htm" {
            guard let data = try? Data(contentsOf: sourceURL) else {
                throw ConversionError.malformedSource(path: sourceURL.path, reason: "Could not read HTML document.")
            }
            do {
                let attributed = try NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.html],
                    documentAttributes: nil
                )
                try await Self.renderTextToPDF(.richText(attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]) ?? Data(), sourcePath: sourceURL.path), destURL: destURL)
            } catch {
                throw ConversionError.malformedSource(path: sourceURL.path, reason: "Could not render HTML document.")
            }
            progressHandler(ConversionProgress(fractionCompleted: 1.0, elapsedTime: 0.5))
            return
        }

        // Image to PDF
        guard let image = NSImage(contentsOf: sourceURL) else {
            throw ConversionError.malformedSource(path: sourceURL.path, reason: "Could not load image data for PDF conversion.")
        }

        if isCancelled() { throw ConversionError.cancelled }

        guard let pdfPage = PDFPage(image: image) else {
            throw ConversionError.unknown(message: "Failed to create PDF page from image.")
        }

        let pdfDoc = PDFDocument()
        pdfDoc.insert(pdfPage, at: 0)

        if isCancelled() { throw ConversionError.cancelled }

        guard pdfDoc.write(to: destURL) else {
            throw ConversionError.destinationUnavailable(path: destURL.path)
        }

        progressHandler(ConversionProgress(fractionCompleted: 1.0, elapsedTime: 0.5))
    }

    private func convertPDFToImage(
        sourceURL: URL,
        destURL: URL,
        targetFormat: String,
        isCancelled: () -> Bool,
        progressHandler: (ConversionProgress) -> Void
    ) throws {
        guard let pdfDoc = PDFDocument(url: sourceURL) else {
            throw ConversionError.malformedSource(path: sourceURL.path, reason: "Could not parse PDF document.")
        }

        guard let firstPage = pdfDoc.page(at: 0) else {
            throw ConversionError.malformedSource(path: sourceURL.path, reason: "PDF document contains no pages.")
        }

        if isCancelled() { throw ConversionError.cancelled }

        let pageBounds = firstPage.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0 // High DPI rendering
        let pixelSize = NSSize(width: pageBounds.width * scale, height: pageBounds.height * scale)

        let imageRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )

        guard let rep = imageRep else {
            throw ConversionError.unknown(message: "Failed to create bitmap context.")
        }

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: scale, y: scale)
            firstPage.draw(with: .mediaBox, to: context.cgContext)
        }
        NSGraphicsContext.restoreGraphicsState()

        let storageType: NSBitmapImageRep.FileType
        switch targetFormat {
        case "jpg", "jpeg":
            storageType = .jpeg
        case "tiff", "tif":
            storageType = .tiff
        case "bmp":
            storageType = .bmp
        case "gif":
            storageType = .gif
        default:
            storageType = .png
        }

        guard let data = rep.representation(using: storageType, properties: [:]) else {
            throw ConversionError.unknown(message: "Failed to encode bitmap image.")
        }

        if isCancelled() { throw ConversionError.cancelled }

        try data.write(to: destURL, options: .atomic)
        progressHandler(ConversionProgress(fractionCompleted: 1.0, elapsedTime: 0.5))
    }

    private func renderPage(_ page: PDFPage?, to destURL: URL, targetFormat: String) throws {
        guard let page else {
            throw ConversionError.malformedSource(path: destURL.path, reason: "PDF page is unreadable.")
        }
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(bounds.width * scale)),
            pixelsHigh: max(1, Int(bounds.height * scale)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { throw ConversionError.unknown(message: "Failed to create bitmap context.") }
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
        NSGraphicsContext.restoreGraphicsState()
        let type: NSBitmapImageRep.FileType = {
            switch targetFormat.lowercased() {
            case "jpg", "jpeg": return .jpeg
            case "tiff", "tif": return .tiff
            case "bmp": return .bmp
            case "gif": return .gif
            default: return .png
            }
        }()
        guard let data = rep.representation(using: type, properties: [:]) else {
            throw ConversionError.unknown(message: "Failed to encode bitmap image.")
        }
        try data.write(to: destURL, options: .atomic)
    }

    private func writePage(_ page: PDFPage?, to destinationURL: URL) throws {
        guard let page else {
            throw ConversionError.malformedSource(path: destinationURL.path, reason: "PDF page is unreadable.")
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        guard document.write(to: destinationURL) else {
            throw ConversionError.destinationUnavailable(path: destinationURL.path)
        }
    }

    @MainActor
    private static func renderTextToPDF(_ source: TextPDFSource, destURL: URL) async throws {
        let attributedString: NSAttributedString
        switch source {
        case .plainText(let text):
            attributedString = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.textColor
            ])
        case .richText(let data, let sourcePath):
            do {
                attributedString = try NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
                )
            } catch {
                throw ConversionError.malformedSource(path: sourcePath, reason: "Could not parse RTF document.")
            }
        }

        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.paperSize = NSSize(width: 595.2, height: 841.8) // A4
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 523.2, height: 769.8))
        textView.textStorage?.setAttributedString(attributedString)

        let printOperation = NSPrintOperation.pdfOperation(
            with: textView,
            inside: textView.bounds,
            toPath: destURL.path,
            printInfo: printInfo
        )
        printOperation.showsPrintPanel = false
        printOperation.showsProgressPanel = false

        guard printOperation.run() else {
            throw ConversionError.destinationUnavailable(path: destURL.path)
        }
    }
}
