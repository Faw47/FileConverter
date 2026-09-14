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
        if preset.splitPDFIntoPages || preset.isPDFSplitWorkflow {
            return sourceFormat.id == "pdf" && destinationFormat.id == "pdf"
        }
        if destinationFormat.id == "pdf" {
            if sourceFormat.id == "pdf" && preset.isPDFCompressWorkflow {
                return true
            }
            return sourceFormat.category == .image || sourceFormat.id == "txt" || sourceFormat.id == "rtf" || sourceFormat.id == "html"
        }
        if sourceFormat.id == "pdf" {
            // Can extract PDF pages to image formats supported by NSBitmapImageRep
            let supportedImageTargets: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "gif"]
            let ext = destinationFormat.primaryExtension.lowercased()
            let id = destinationFormat.id.lowercased()
            return supportedImageTargets.contains(ext) || supportedImageTargets.contains(id)
        }
        return false
    }

    private func markCancelled(jobID: UUID) {
        lock.withLock {
            _ = cancelledJobs.insert(jobID)
        }
    }

    private func clearCancelled(jobID: UUID) {
        lock.withLock {
            _ = cancelledJobs.remove(jobID)
        }
    }

    private func checkCancelled(jobID: UUID) -> Bool {
        lock.withLock {
            cancelledJobs.contains(jobID)
        }
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
        if job.preset.splitPDFIntoPages || job.preset.isPDFSplitWorkflow {
            let options = job.preset.processingOptions
            let plans = PDFPageRangeParser.planOutputs(
                totalPages: document.pageCount,
                splitMode: options?.pdfSplitMode,
                pageRanges: options?.pdfPageRanges,
                chunkSize: options?.pdfChunkSize,
                selectedPages: options?.pdfSelectedPages,
                mergeOutputs: options?.pdfMergeSplitOutputs ?? false,
                namingPattern: options?.pdfNamingPattern,
                zeroPadDigits: options?.pdfZeroPadDigits
            )
            return plans.map { plan in
                ConversionOutputRequirement(
                    extensionName: "pdf",
                    suffix: plan.suffix
                )
            }
        }
        let destinationIsImage = FormatRegistry.shared.format(forID: job.preset.destinationFormat)?.category == .image
        guard destinationIsImage else {
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
        if Task.isCancelled || checkCancelled(jobID: jobID) {
            throw ConversionError.cancelled
        }
        defer { clearCancelled(jobID: jobID) }

        guard let pdfDoc = PDFDocument(url: job.sourceURL) else {
            throw ConversionError.malformedSource(path: job.sourceURL.path, reason: "Could not open PDF document.")
        }

        let start = Date()

        if job.preset.splitPDFIntoPages || job.preset.isPDFSplitWorkflow {
            let options = job.preset.processingOptions
            let plans = PDFPageRangeParser.planOutputs(
                totalPages: pdfDoc.pageCount,
                splitMode: options?.pdfSplitMode,
                pageRanges: options?.pdfPageRanges,
                chunkSize: options?.pdfChunkSize,
                selectedPages: options?.pdfSelectedPages,
                mergeOutputs: options?.pdfMergeSplitOutputs ?? false,
                namingPattern: options?.pdfNamingPattern,
                zeroPadDigits: options?.pdfZeroPadDigits
            )

            guard plans.count == outputs.count else {
                throw ConversionError.malformedSource(path: job.sourceURL.path, reason: "Mismatch in expected split PDF output count.")
            }

            for (index, output) in outputs.enumerated() {
                if checkCancelled(jobID: jobID) {
                    throw ConversionError.cancelled
                }
                try Task.checkCancellation()
                let plan = plans[index]
                let pages = plan.pageIndices.compactMap { pdfDoc.page(at: $0) }
                try writePages(pages, to: output.temporaryURL)
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

        if job.preset.isPDFCompressWorkflow || job.preset.destinationFormat.lowercased() == "pdf" {
            guard let first = outputs.first else {
                throw ConversionError.destinationUnavailable(path: "")
            }
            var singleJob = job
            singleJob.destinationURL = first.finalURL
            singleJob.temporaryOutputURL = first.temporaryURL
            try await convert(job: singleJob, progressHandler: progressHandler)
            return BackendConversionResult()
        }

        guard pdfDoc.pageCount == outputs.count else {
            throw ConversionError.malformedSource(path: job.sourceURL.path, reason: "Could not parse all PDF pages.")
        }

        for (index, output) in outputs.enumerated() {
            if checkCancelled(jobID: jobID) {
                throw ConversionError.cancelled
            }
            try Task.checkCancellation()
            try renderPage(pdfDoc.page(at: index), to: output.temporaryURL, targetFormat: job.preset.destinationFormat)
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
        if Task.isCancelled || checkCancelled(jobID: jobID) {
            throw ConversionError.cancelled
        }
        defer { clearCancelled(jobID: jobID) }

        let sourceURL = job.sourceURL
        guard let destURL = job.temporaryOutputURL ?? job.destinationURL else {
            throw ConversionError.destinationUnavailable(path: "")
        }

        let destDir = destURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let isCancelled = { [weak self] () -> Bool in
            if Task.isCancelled { return true }
            guard let self = self else { return false }
            return self.checkCancelled(jobID: jobID)
        }

        if isCancelled() { throw ConversionError.cancelled }

        progressHandler(ConversionProgress(fractionCompleted: 0.1, elapsedTime: 0.1))

        let targetFormat = job.preset.destinationFormat.lowercased()

        if targetFormat == "pdf" {
            if sourceURL.pathExtension.lowercased() == "pdf" {
                if job.preset.isPDFCompressWorkflow {
                    try compressPDF(sourceURL: sourceURL, destURL: destURL, preset: job.preset, isCancelled: isCancelled, progressHandler: progressHandler)
                } else {
                    guard let doc = PDFDocument(url: sourceURL) else {
                        throw ConversionError.malformedSource(path: sourceURL.path, reason: "Could not open PDF document.")
                    }
                    if isCancelled() { throw ConversionError.cancelled }
                    guard doc.write(to: destURL) else {
                        throw ConversionError.destinationUnavailable(path: destURL.path)
                    }
                    progressHandler(ConversionProgress(fractionCompleted: 1.0, elapsedTime: 0.5))
                }
            } else {
                // Convert source to PDF
                try await convertToPDF(sourceURL: sourceURL, destURL: destURL, isCancelled: isCancelled, progressHandler: progressHandler)
            }
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

        if ext == "pdf" {
            guard let doc = PDFDocument(url: sourceURL) else {
                throw ConversionError.malformedSource(path: sourceURL.path, reason: "Could not open PDF document.")
            }
            if isCancelled() { throw ConversionError.cancelled }
            guard doc.write(to: destURL) else {
                throw ConversionError.destinationUnavailable(path: destURL.path)
            }
            progressHandler(ConversionProgress(fractionCompleted: 1.0, elapsedTime: 0.5))
            return
        }

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
                let rtfData: Data = try await MainActor.run {
                    let attributed = try NSAttributedString(
                        data: data,
                        options: [.documentType: NSAttributedString.DocumentType.html],
                        documentAttributes: nil
                    )
                    return attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]) ?? Data()
                }
                try await Self.renderTextToPDF(.richText(rtfData, sourcePath: sourceURL.path), destURL: destURL)
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
        let normalizedRotation = ((firstPage.rotation % 360) + 360) % 360
        let isRotated = (normalizedRotation == 90 || normalizedRotation == 270)
        let pixelWidth = max(1, Int((isRotated ? pageBounds.height : pageBounds.width) * scale))
        let pixelHeight = max(1, Int((isRotated ? pageBounds.width : pageBounds.height) * scale))

        let imageRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )

        guard let rep = imageRep,
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw ConversionError.unknown(message: "Failed to create bitmap context.")
        }

        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.current = previousContext }
        context.cgContext.saveGState()
        context.cgContext.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.cgContext.scaleBy(x: scale, y: scale)
        context.cgContext.concatenate(firstPage.transform(for: .mediaBox))
        firstPage.draw(with: .mediaBox, to: context.cgContext)
        context.cgContext.restoreGState()

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
        let normalizedRotation = ((page.rotation % 360) + 360) % 360
        let isRotated = (normalizedRotation == 90 || normalizedRotation == 270)
        let pixelWidth = max(1, Int((isRotated ? bounds.height : bounds.width) * scale))
        let pixelHeight = max(1, Int((isRotated ? bounds.width : bounds.height) * scale))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep,
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw ConversionError.unknown(message: "Failed to create bitmap context.")
        }
        let destDir = destURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.current = previousContext }
        context.cgContext.saveGState()
        context.cgContext.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.cgContext.scaleBy(x: scale, y: scale)
        context.cgContext.concatenate(page.transform(for: .mediaBox))
        page.draw(with: .mediaBox, to: context.cgContext)
        context.cgContext.restoreGState()
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

    private func writePages(_ pages: [PDFPage], to destinationURL: URL) throws {
        guard !pages.isEmpty else {
            throw ConversionError.malformedSource(path: destinationURL.path, reason: "No pages to write.")
        }
        let destDir = destinationURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let document = PDFDocument()
        for (index, page) in pages.enumerated() {
            let pageToInsert = (page.copy() as? PDFPage) ?? page
            document.insert(pageToInsert, at: index)
        }
        guard document.write(to: destinationURL) else {
            throw ConversionError.destinationUnavailable(path: destinationURL.path)
        }
    }

    private func writePage(_ page: PDFPage?, to destinationURL: URL) throws {
        guard let page else {
            throw ConversionError.malformedSource(path: destinationURL.path, reason: "PDF page is unreadable.")
        }
        try writePages([page], to: destinationURL)
    }

    private func compressPDF(
        sourceURL: URL,
        destURL: URL,
        preset: ConversionPreset,
        isCancelled: () -> Bool,
        progressHandler: (ConversionProgress) -> Void
    ) throws {
        let start = Date()
        guard let doc = PDFDocument(url: sourceURL) else {
            throw ConversionError.malformedSource(path: sourceURL.path, reason: "Cannot open PDF document.")
        }
        let count = doc.pageCount
        guard count > 0 else {
            throw ConversionError.malformedSource(path: sourceURL.path, reason: "PDF document contains no pages.")
        }

        let options = preset.processingOptions
        let dpi: Int = {
            if let dpi = options?.pdfDPI { return dpi }
            if let profile = options?.pdfCompressionProfile {
                switch profile.lowercased() {
                case "screen": return 72
                case "ebook": return 150
                case "printer", "prepress": return 300
                default: return 150
                }
            }
            switch preset.quality {
            case .low: return 72
            case .medium: return 150
            case .high, .veryHigh, .lossless: return 300
            case .custom: return 150
            }
        }()

        let quality: Double = {
            if let q = options?.pdfImageQuality { return q }
            if let profile = options?.pdfCompressionProfile {
                switch profile.lowercased() {
                case "screen": return 0.5
                case "ebook": return 0.7
                case "printer": return 0.85
                case "prepress": return 0.95
                default: return 0.7
                }
            }
            switch preset.quality {
            case .low: return 0.5
            case .medium: return 0.7
            case .high: return 0.85
            case .veryHigh, .lossless: return 0.95
            case .custom: return 0.7
            }
        }()

        let isGrayscale = options?.pdfColorMode == "grayscale" || options?.pdfColorMode == "monochrome"
        let stripMetadata = options?.pdfRemoveMetadata ?? false
        let removeAnnotations = options?.pdfRemoveAnnotations ?? false

        let newDoc = PDFDocument()
        for i in 0..<count {
            if isCancelled() { throw ConversionError.cancelled }
            guard let page = doc.page(at: i) else { continue }
            do {
                let originalRotation = page.rotation
                let originalDisplaysAnnotations = page.displaysAnnotations
                page.rotation = 0
                if removeAnnotations {
                    page.displaysAnnotations = false
                }
                defer {
                    page.rotation = originalRotation
                    if removeAnnotations {
                        page.displaysAnnotations = originalDisplaysAnnotations
                    }
                }

                let pageBounds = page.bounds(for: .mediaBox)
                let scale = CGFloat(dpi) / 72.0
                let pixelWidth = max(1, Int(pageBounds.width * scale))
                let pixelHeight = max(1, Int(pageBounds.height * scale))

                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: pixelWidth,
                    pixelsHigh: pixelHeight,
                    bitsPerSample: 8,
                    samplesPerPixel: isGrayscale ? 1 : 4,
                    hasAlpha: !isGrayscale,
                    isPlanar: false,
                    colorSpaceName: isGrayscale ? .deviceWhite : .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
                    let copied = (page.copy() as? PDFPage) ?? page
                    newDoc.insert(copied, at: newDoc.pageCount)
                    continue
                }

                let prevContext = NSGraphicsContext.current
                NSGraphicsContext.current = context
                do {
                    defer { NSGraphicsContext.current = prevContext }
                    let cgContext = context.cgContext
                    cgContext.saveGState()
                    if isGrayscale {
                        cgContext.setFillColor(gray: 1.0, alpha: 1.0)
                    } else {
                        cgContext.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
                    }
                    cgContext.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
                    cgContext.scaleBy(x: scale, y: scale)
                    cgContext.concatenate(page.transform(for: .mediaBox))
                    page.draw(with: .mediaBox, to: cgContext)
                    cgContext.restoreGState()
                }

                if let imgData = rep.representation(using: .jpeg, properties: [.compressionFactor: NSNumber(value: quality)]),
                   let compressedImage = NSImage(data: imgData),
                   let compressedPage = PDFPage(image: compressedImage) {
                    compressedPage.setBounds(pageBounds, for: .mediaBox)
                    compressedPage.rotation = originalRotation
                    newDoc.insert(compressedPage, at: newDoc.pageCount)
                } else {
                    let copied = (page.copy() as? PDFPage) ?? page
                    newDoc.insert(copied, at: newDoc.pageCount)
                }
            }

            progressHandler(ConversionProgress(
                fractionCompleted: Double(i + 1) / Double(count),
                elapsedTime: Date().timeIntervalSince(start)
            ))
        }

        if stripMetadata {
            newDoc.documentAttributes = [:]
        } else {
            newDoc.documentAttributes = doc.documentAttributes
        }

        guard newDoc.write(to: destURL) else {
            throw ConversionError.destinationUnavailable(path: destURL.path)
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

        guard let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo else {
            throw ConversionError.destinationUnavailable(path: destURL.path)
        }
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
