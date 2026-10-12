import Foundation
import FileConverterCore

public final class GhostscriptBackend: ConversionBackend, @unchecked Sendable {
    public let backendType: BackendType = .ghostscript
    public var isAvailable: Bool {
        ExternalToolDiscovery.shared.isToolAvailable("gs")
    }

    private let processRegistry = ExternalProcessRegistry()

    public init() {}

    public func supports(sourceFormat: FormatDefinition, destinationFormat: FormatDefinition, preset: ConversionPreset) -> Bool {
        guard destinationFormat.id == "pdf" else { return false }
        let validSources: Set<String> = ["pdf", "ps", "eps", "postscript"]
        return validSources.contains(sourceFormat.id.lowercased()) || validSources.contains(sourceFormat.primaryExtension.lowercased())
    }

    public func cancel(jobID: UUID) async {
        processRegistry.cancel(jobID: jobID)
        ExternalProcessSupervisor.shared.cancel(jobID: jobID)
    }

    public func convert(job: ConversionJob, progressHandler: @escaping @Sendable (ConversionProgress) -> Void) async throws {
        guard let gsPath = ExternalToolDiscovery.shared.executablePath(for: "gs") else {
            throw ConversionError.dependencyMissing(dependencyName: "Ghostscript", installCommand: "brew install ghostscript")
        }

        let jobID = job.id
        let sourceURL = job.sourceURL
        guard let destURL = job.temporaryOutputURL ?? job.destinationURL else {
            throw ConversionError.destinationUnavailable(path: "")
        }

        let options = job.preset.processingOptions
        var pdfSettings = "/ebook"
        if let profile = options?.pdfCompressionProfile {
            switch profile.lowercased() {
            case "screen": pdfSettings = "/screen"
            case "ebook": pdfSettings = "/ebook"
            case "printer": pdfSettings = "/printer"
            case "prepress": pdfSettings = "/prepress"
            default: pdfSettings = "/ebook"
            }
        } else {
            switch job.preset.quality {
            case .low: pdfSettings = "/screen"
            case .medium: pdfSettings = "/ebook"
            case .high: pdfSettings = "/printer"
            case .veryHigh, .lossless, .custom: pdfSettings = "/prepress"
            }
        }

        var args = [
            "-sDEVICE=pdfwrite",
            "-dCompatibilityLevel=\(options?.pdfCompatibilityLevel ?? "1.4")",
            "-dPDFSETTINGS=\(pdfSettings)",
            "-dNOPAUSE",
            "-dQUIET",
            "-dBATCH"
        ]

        if let dpi = options?.pdfDPI {
            args.append("-dDownsampleColorImages=true")
            args.append("-dColorImageResolution=\(dpi)")
            args.append("-dDownsampleGrayImages=true")
            args.append("-dGrayImageResolution=\(dpi)")
            args.append("-dDownsampleMonoImages=true")
            args.append("-dMonoImageResolution=\(dpi)")
        }

        // pdfwrite converts to gray but has no 1-bit strategy; "monochrome"
        // from older presets is treated as grayscale.
        if options?.pdfColorMode == "grayscale" || options?.pdfColorMode == "monochrome" {
            args.append("-sColorConversionStrategy=Gray")
            args.append("-dProcessColorModel=/DeviceGray")
        }

        if options?.pdfLinearize == true {
            args.append("-dFastWebView=true")
        }

        if options?.pdfRemoveAnnotations == true {
            args.append("-dPreserveAnnots=false")
        }

        args.append("-sOutputFile=\(destURL.path.replacingOccurrences(of: "%", with: "%%"))")
        if options?.pdfRemoveMetadata == true {
            // Blank the document info before the input is processed.
            args.append(contentsOf: [
                "-c", "[ /Title () /Author () /Subject () /Keywords () /Creator () /DOCINFO pdfmark",
                "-f"
            ])
        }
        args.append(sourceURL.path.replacingOccurrences(of: "%", with: "%%"))

        let startTime = Date()
        progressHandler(ConversionProgress(fractionCompleted: 0.1, elapsedTime: 0))

        let result: ExternalProcessResult
        do {
            result = try await ExternalProcessSupervisor.shared.run(
                tool: .ghostscript,
                executableURL: URL(fileURLWithPath: gsPath),
                arguments: args,
                deadline: 300,
                for: jobID
            )
        } catch is CancellationError {
            throw ConversionError.cancelled
        }

        let exitCode = result.terminationStatus
        if exitCode == 0 {
            progressHandler(ConversionProgress(fractionCompleted: 1.0, elapsedTime: Date().timeIntervalSince(startTime)))
        } else if exitCode == 15 || exitCode == 9 {
            throw ConversionError.cancelled
        } else {
            throw ConversionError.externalToolFailed(tool: "Ghostscript", exitCode: exitCode, stderr: result.stderr)
        }
    }
}
