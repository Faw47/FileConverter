import Foundation
import PDFKit
import Vision
import ImageIO
import CoreGraphics
import CoreText
import AppKit
import FileConverterCore

public final class PDFKitBackend: ConversionBackend, @unchecked Sendable {
    public let backendType: BackendType = .pdfKit
    public var isAvailable: Bool { true }

    /// Capability metadata for PDF compression. The native backend always
    /// rasterizes pages to images: it is never vector-preserving nor
    /// lossless, does not preserve thumbnails/linearization/compatibility
    /// levels, and requires no external tool. Ghostscript is required for a
    /// true lossless/vector profile.
    public struct PDFCompressionCapabilities: Sendable, Equatable {
        public let isVectorPreserving = false
        public let isLossless = false
        public let supportsMetadataRemoval = true
        public let supportsAnnotationRemoval = true
        public let supportsThumbnailRemoval = false
        public let supportsLinearization = false
        public let supportsCompatibilityLevels = false
        public let requiresExternalTool = false
        public let losslessRequiresBackend: BackendType = .ghostscript

        public init() {}
    }

    public static let compressionCapabilities = PDFCompressionCapabilities()

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
            if sourceFormat.id == "pdf" && (preset.isPDFCompressWorkflow || preset.processingOptions?.pdfRotationDegrees != nil) {
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

    private func validateSplitSelection(options: ConversionProcessingOptions?, totalPages: Int, sourcePath: String) throws {
        let mode = options?.pdfSplitMode ?? "all"
        switch mode {
        case "ranges":
            let result = PDFPageRangeParser.parseRangesStrict(
                options?.pdfPageRanges ?? "",
                totalPages: totalPages
            )
            guard result.isValid else {
                throw ConversionError.malformedSource(
                    path: sourcePath,
                    reason: result.errorMessage ?? "Invalid PDF page selection."
                )
            }
        case "selected":
            let pages = options?.pdfSelectedPages ?? []
            guard !pages.isEmpty, pages.allSatisfy({ $0 >= 1 && $0 <= totalPages }) else {
                throw ConversionError.malformedSource(
                    path: sourcePath,
                    reason: "Selected PDF pages must be between 1 and \(totalPages)."
                )
            }
        default:
            break
        }
    }

    public func outputRequirements(for job: ConversionJob) async throws -> [ConversionOutputRequirement] {
        guard FormatDetector.detect(url: job.sourceURL).format?.id == "pdf" else {
            return [ConversionOutputRequirement(extensionName: job.preset.destinationFormat)]
        }
        guard let document = PDFDocument(url: job.sourceURL), document.pageCount > 0 else {
            throw ConversionError.malformedSource(path: job.sourceURL.path, reason: "PDF document contains no readable pages.")
        }
        if document.isLocked {
            throw ConversionError.malformedSource(path: job.sourceURL.path, reason: "PDF document is password-protected and cannot be processed.")
        }
        if job.preset.splitPDFIntoPages || job.preset.isPDFSplitWorkflow {
            let options = job.preset.processingOptions
            try validateSplitSelection(options: options, totalPages: document.pageCount, sourcePath: job.sourceURL.path)
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
            guard !plans.isEmpty else {
                throw ConversionError.malformedSource(
                    path: job.sourceURL.path,
                    reason: "No valid PDF split outputs could be planned."
                )
            }
            guard plans.count <= 1000 else {
                throw ConversionError.malformedSource(
                    path: job.sourceURL.path,
                    reason: "PDF split plan exceeds maximum safety ceiling of 1000 outputs (\(plans.count) requested)."
                )
            }
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
        guard document.pageCount <= 1000 else {
            throw ConversionError.malformedSource(
                path: job.sourceURL.path,
                reason: "PDF to image conversion exceeds maximum safety ceiling of 1000 pages (\(document.pageCount) requested)."
            )
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
        if pdfDoc.isLocked {
            throw ConversionError.malformedSource(path: job.sourceURL.path, reason: "PDF document is password-protected and cannot be processed.")
        }

        let start = Date()

        if job.preset.splitPDFIntoPages || job.preset.isPDFSplitWorkflow {
            let options = job.preset.processingOptions
            try validateSplitSelection(options: options, totalPages: pdfDoc.pageCount, sourcePath: job.sourceURL.path)
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
            guard !plans.isEmpty else {
                throw ConversionError.malformedSource(
                    path: job.sourceURL.path,
                    reason: "No valid PDF split outputs could be planned."
                )
            }

            guard plans.count == outputs.count else {
                throw ConversionError.malformedSource(path: job.sourceURL.path, reason: "Mismatch in expected split PDF output count.")
            }

            for (index, output) in outputs.enumerated() {
                if checkCancelled(jobID: jobID) {
                    throw ConversionError.cancelled
                }
                try Task.checkCancellation()
                try autoreleasepool {
                    let plan = plans[index]
                    let pages = plan.pageIndices.compactMap { pdfDoc.page(at: $0) }
                    try writePages(pages, to: output.temporaryURL)
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

        if job.preset.isPDFCompressWorkflow || job.preset.destinationFormat.lowercased() == "pdf" {
            guard let first = outputs.first else {
                throw ConversionError.destinationUnavailable(path: "")
            }
            var singleJob = job
            singleJob.destinationURL = first.finalURL
            singleJob.temporaryOutputURL = first.temporaryURL
            try await convert(job: singleJob, progressHandler: progressHandler)
            var warnings: [String] = []
            if job.preset.isPDFCompressWorkflow {
                // These options need Ghostscript; say so if it was not used.
                let opts = job.preset.processingOptions
                var skipped: [String] = []
                if opts?.pdfRemoveThumbnails == true { skipped.append("removing page thumbnails") }
                if opts?.pdfLinearize == true { skipped.append("fast web view") }
                if let level = opts?.pdfCompatibilityLevel, !level.isEmpty { skipped.append("PDF version \(level)") }
                if !skipped.isEmpty {
                    warnings.append("Without Ghostscript these options were skipped: \(skipped.joined(separator: ", ")).")
                }
            }
            return BackendConversionResult(warnings: warnings)
        }

        guard pdfDoc.pageCount == outputs.count else {
            throw ConversionError.malformedSource(path: job.sourceURL.path, reason: "Could not parse all PDF pages.")
        }

        for (index, output) in outputs.enumerated() {
            if checkCancelled(jobID: jobID) {
                throw ConversionError.cancelled
            }
            try Task.checkCancellation()
            try autoreleasepool {
                try Self.renderPage(pdfDoc.page(at: index), to: output.temporaryURL, preset: job.preset)
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
                    if doc.isLocked {
                        throw ConversionError.malformedSource(path: sourceURL.path, reason: "PDF document is password-protected and cannot be processed.")
                    }
                    if isCancelled() { throw ConversionError.cancelled }
                    if let degrees = job.preset.processingOptions?.pdfRotationDegrees {
                        for index in 0..<doc.pageCount {
                            guard let page = doc.page(at: index) else { continue }
                            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
                        }
                    }
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
            try convertPDFToImage(sourceURL: sourceURL, destURL: destURL, preset: job.preset, isCancelled: isCancelled, progressHandler: progressHandler)
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
            try Self.renderTextToPDF(.plainText(text), destURL: destURL)
            progressHandler(ConversionProgress(fractionCompleted: 1.0, elapsedTime: 0.5))
            return
        }

        if ext == "rtf" {
            guard let data = try? Data(contentsOf: sourceURL) else {
                throw ConversionError.malformedSource(path: sourceURL.path, reason: "Could not read RTF document.")
            }
            try Self.renderTextToPDF(.richText(data, sourcePath: sourceURL.path), destURL: destURL)
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
                try Self.renderTextToPDF(.richText(rtfData, sourcePath: sourceURL.path), destURL: destURL)
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
        preset: ConversionPreset,
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
        let start = Date()
        try Self.renderPage(firstPage, to: destURL, preset: preset)
        progressHandler(ConversionProgress(fractionCompleted: 1.0, elapsedTime: Date().timeIntervalSince(start)))
    }

    /// Dots per inch for PDF pages rendered to images.
    static func renderDPI(for preset: ConversionPreset) -> Int {
        if let dpi = preset.processingOptions?.pdfDPI, dpi > 0 { return min(dpi, 1_200) }
        switch preset.destinationFormat.lowercased() {
        case "jpg", "jpeg": return 200
        default: return 300
        }
    }

    /// Renders the visible page (crop box, upright) on white at the preset's DPI.
    static func renderPage(_ page: PDFPage?, to destURL: URL, preset: ConversionPreset) throws {
        guard let page else {
            throw ConversionError.malformedSource(path: destURL.path, reason: "PDF page is unreadable.")
        }
        let scale = CGFloat(renderDPI(for: preset)) / 72
        let bounds = page.bounds(for: .cropBox)
        let normalizedRotation = ((page.rotation % 360) + 360) % 360
        let isRotated = (normalizedRotation == 90 || normalizedRotation == 270)
        let pixelWidth = max(1, Int(((isRotated ? bounds.height : bounds.width) * scale).rounded()))
        let pixelHeight = max(1, Int(((isRotated ? bounds.width : bounds.height) * scale).rounded()))
        guard pixelWidth * pixelHeight <= 400_000_000 else {
            throw ConversionError.imageTooLarge(width: pixelWidth, height: pixelHeight, limitMegapixels: 400)
        }
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
        try? FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.current = previousContext }
        context.cgContext.saveGState()
        context.cgContext.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.cgContext.scaleBy(x: scale, y: scale)
        context.cgContext.concatenate(page.transform(for: .cropBox))
        page.draw(with: .cropBox, to: context.cgContext)
        context.cgContext.restoreGState()

        let type: NSBitmapImageRep.FileType
        var properties: [NSBitmapImageRep.PropertyKey: Any] = [:]
        switch preset.destinationFormat.lowercased() {
        case "jpg", "jpeg":
            type = .jpeg
            let quality: Double
            switch preset.quality {
            case .low: quality = 0.5
            case .medium: quality = 0.75
            case .high, .custom: quality = 0.9
            case .veryHigh, .lossless: quality = 0.98
            }
            properties[.compressionFactor] = NSNumber(value: quality)
        case "tiff", "tif":
            type = .tiff
            properties[.compressionMethod] = NSNumber(value: NSBitmapImageRep.TIFFCompression.lzw.rawValue)
        case "bmp": type = .bmp
        case "gif": type = .gif
        default: type = .png
        }
        guard let data = rep.representation(using: type, properties: properties) else {
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
        if doc.isLocked {
            throw ConversionError.malformedSource(path: sourceURL.path, reason: "PDF document is password-protected and cannot be processed.")
        }
        let count = doc.pageCount
        guard count > 0 else {
            throw ConversionError.malformedSource(path: sourceURL.path, reason: "PDF document contains no pages.")
        }
        let options = preset.processingOptions
        let stripMetadata = options?.pdfRemoveMetadata ?? false
        let removeAnnotations = options?.pdfRemoveAnnotations ?? false

        guard options?.pdfFlattenToImages == true else {
            // Default: recompress embedded images and keep everything else
            // (text, links, bookmarks, form fields) intact.
            if removeAnnotations {
                for index in 0..<count {
                    guard let page = doc.page(at: index) else { continue }
                    for annotation in page.annotations where annotation.type != "Widget" {
                        page.removeAnnotation(annotation)
                    }
                }
            }
            if stripMetadata {
                doc.documentAttributes = [:]
            }
            if isCancelled() { throw ConversionError.cancelled }
            let profile = options?.pdfCompressionProfile?.lowercased() ?? "ebook"
            let writeOptions: [PDFDocumentWriteOption: Any] = [
                .saveImagesAsJPEGOption: true,
                .optimizeImagesForScreenOption: profile != "prepress" && profile != "printer"
            ]
            guard doc.write(to: destURL, withOptions: writeOptions) else {
                throw ConversionError.destinationUnavailable(path: destURL.path)
            }
            progressHandler(ConversionProgress(fractionCompleted: 1, elapsedTime: Date().timeIntervalSince(start)))
            return
        }

        // Flatten: every page becomes one JPEG image (smallest file). Text
        // recognized on this Mac is drawn invisibly under the image so the
        // PDF stays searchable and selectable.
        let dpi: Int = {
            if let dpi = options?.pdfDPI { return dpi }
            switch options?.pdfCompressionProfile?.lowercased() {
            case "screen": return 96
            case "printer", "prepress": return 300
            default: return 150
            }
        }()
        let quality = options?.pdfImageQuality ?? 0.7
        let isGrayscale = options?.pdfColorMode == "grayscale" || options?.pdfColorMode == "monochrome"

        var auxiliary: [CFString: Any] = [:]
        if !stripMetadata, let attributes = doc.documentAttributes {
            if let title = attributes[PDFDocumentAttribute.titleAttribute] { auxiliary[kCGPDFContextTitle] = title }
            if let author = attributes[PDFDocumentAttribute.authorAttribute] { auxiliary[kCGPDFContextAuthor] = author }
            if let subject = attributes[PDFDocumentAttribute.subjectAttribute] { auxiliary[kCGPDFContextSubject] = subject }
        }
        guard let consumer = CGDataConsumer(url: destURL as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: nil, auxiliary as CFDictionary) else {
            throw ConversionError.destinationUnavailable(path: destURL.path)
        }

        for index in 0..<count {
            if isCancelled() {
                pdf.closePDF()
                throw ConversionError.cancelled
            }
            guard let page = doc.page(at: index) else { continue }
            try autoreleasepool {
                if removeAnnotations { page.displaysAnnotations = false }
                let bounds = page.bounds(for: .cropBox)
                let rotation = ((page.rotation % 360) + 360) % 360
                let pageSize = (rotation == 90 || rotation == 270)
                    ? CGSize(width: bounds.height, height: bounds.width)
                    : bounds.size
                let scale = CGFloat(dpi) / 72
                let pixelWidth = max(1, Int((pageSize.width * scale).rounded()))
                let pixelHeight = max(1, Int((pageSize.height * scale).rounded()))
                let space = isGrayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
                guard let bitmap = CGContext(
                    data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space,
                    bitmapInfo: isGrayscale ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
                ) else {
                    throw ConversionError.unknown(message: "Could not create a page image.")
                }
                bitmap.setFillColor(gray: 1, alpha: 1)
                bitmap.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
                bitmap.scaleBy(x: scale, y: scale)
                bitmap.concatenate(page.transform(for: .cropBox))
                page.draw(with: .cropBox, to: bitmap)
                guard let rendered = bitmap.makeImage() else {
                    throw ConversionError.unknown(message: "Could not render page \(index + 1).")
                }

                // Store the page as JPEG so the PDF embeds compressed data.
                let jpegData = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(jpegData, "public.jpeg" as CFString, 1, nil) else {
                    throw ConversionError.unknown(message: "Could not encode page \(index + 1).")
                }
                CGImageDestinationAddImage(destination, rendered, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                CGImageDestinationFinalize(destination)
                guard let jpegSource = CGImageSourceCreateWithData(jpegData, nil),
                      let jpeg = CGImageSourceCreateImageAtIndex(jpegSource, 0, nil) else {
                    throw ConversionError.unknown(message: "Could not encode page \(index + 1).")
                }

                var box = CGRect(origin: .zero, size: pageSize)
                pdf.beginPage(mediaBox: &box)
                pdf.draw(jpeg, in: box)
                Self.drawRecognizedText(in: rendered, onto: pdf, pageSize: pageSize)
                pdf.endPage()
            }

            progressHandler(ConversionProgress(
                fractionCompleted: Double(index + 1) / Double(count),
                elapsedTime: Date().timeIntervalSince(start)
            ))
        }
        pdf.closePDF()
    }

    /// Recognizes text in a rendered page and draws it invisibly at the same
    /// place, the way scanned-document PDFs are made searchable.
    static func drawRecognizedText(in image: CGImage, onto context: CGContext, pageSize: CGSize) {
        let request = VNRecognizeTextRequest()
        // Fast recognition is accurate enough for search on printed pages
        // and several times quicker than the accurate model.
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let observations = request.results else { return }

        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for observation in observations {
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { continue }
            // Vision boxes are normalized with a bottom-left origin, like PDF.
            let rect = CGRect(
                x: observation.boundingBox.minX * pageSize.width,
                y: observation.boundingBox.minY * pageSize.height,
                width: observation.boundingBox.width * pageSize.width,
                height: observation.boundingBox.height * pageSize.height
            )
            guard rect.width > 1, rect.height > 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.85, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            guard width > 0 else { continue }
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY + rect.height * 0.15)
            context.scaleBy(x: rect.width / width, y: 1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    private static func renderTextToPDF(_ source: TextPDFSource, destURL: URL) throws {
        let attributedString: NSAttributedString
        switch source {
        case .plainText(let text):
            attributedString = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                // Paper is white regardless of the Mac's appearance.
                .foregroundColor: NSColor.black
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

        let paperWidth: CGFloat = 595.2 // A4 width
        let paperHeight: CGFloat = 841.8 // A4 height
        let margin: CGFloat = 36.0
        let contentWidth = paperWidth - (margin * 2)
        let contentHeight = paperHeight - (margin * 2)

        var pageMediaBox = CGRect(x: 0, y: 0, width: paperWidth, height: paperHeight)
        guard let consumer = CGDataConsumer(url: destURL as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &pageMediaBox, nil) else {
            throw ConversionError.destinationUnavailable(path: destURL.path)
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributedString as CFAttributedString)
        var textIndex = 0
        let textLength = attributedString.length

        if textLength == 0 {
            context.beginPDFPage(nil)
            context.endPDFPage()
        } else {
            while textIndex < textLength {
                context.beginPDFPage(nil)

                let frameRect = CGRect(x: margin, y: margin, width: contentWidth, height: contentHeight)
                let path = CGPath(rect: frameRect, transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: textIndex, length: 0), path, nil)

                CTFrameDraw(frame, context)

                let visibleRange = CTFrameGetVisibleStringRange(frame)
                if visibleRange.length == 0 {
                    textIndex += 1
                } else {
                    textIndex += visibleRange.length
                }

                context.endPDFPage()
            }
        }

        context.closePDF()
    }
}
