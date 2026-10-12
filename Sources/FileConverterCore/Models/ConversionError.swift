import Foundation

public enum ConversionError: Error, LocalizedError, CustomStringConvertible, Sendable, Codable, Equatable {
    case unsupportedInputFormat(path: String, detectedType: String?)
    case unsupportedOutputFormat(targetFormat: String)
    case incompatibleConversion(sourceFormat: String, targetFormat: String)
    case backendUnavailable(backend: String)
    case dependencyMissing(dependencyName: String, installCommand: String)
    case permissionDenied(path: String)
    case encoderUnavailable(codec: String, reason: String)
    case decoderUnavailable(codec: String, reason: String)
    case malformedSource(path: String, reason: String)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case destinationUnavailable(path: String)
    case externalToolFailed(tool: String, exitCode: Int32, stderr: String)
    case cancelled
    case outputCollision(path: String)
    case sandboxAccessFailure(path: String)
    case fileNotFound(path: String)
    case invalidPreset(reason: String)
    case backendContractViolation(message: String)
    case executionDeadlineExceeded(tool: String, duration: TimeInterval)
    case destinationChangingTooQuickly(path: String)
    /// Another job in the queue is writing the same output file.
    case destinationReserved(path: String)
    /// A Finder request was refused before any job started.
    case admissionRejected(reason: String)
    case imageTooLarge(width: Int, height: Int, limitMegapixels: Int)
    case unknown(message: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedInputFormat(let path, let detectedType):
            let filename = URL(fileURLWithPath: path).lastPathComponent
            if let detectedType = detectedType {
                return "The format of '\(filename)' (\(detectedType)) is not supported for conversion."
            }
            return "The format of '\(filename)' could not be recognized or is not supported."

        case .unsupportedOutputFormat(let targetFormat):
            return "Output format '\(targetFormat.uppercased())' is not supported."

        case .incompatibleConversion(let source, let target):
            return "Cannot convert from \(source.uppercased()) to \(target.uppercased())."

        case .backendUnavailable(let backend):
            return "The \(backend) backend is not available in this File Converter edition."

        case .dependencyMissing(let name, let command):
            return "Required tool '\(name)' is not installed. You can install it using: \(command)"

        case .permissionDenied(let path):
            let filename = URL(fileURLWithPath: path).lastPathComponent
            return "Permission was denied while attempting to access '\(filename)'."

        case .encoderUnavailable(let codec, let reason):
            return "The '\(codec)' encoder is not available on this system (\(reason))."

        case .decoderUnavailable(let codec, let reason):
            return "Could not decode audio/video stream using '\(codec)': \(reason)."

        case .malformedSource(let path, let reason):
            let filename = URL(fileURLWithPath: path).lastPathComponent
            return "File '\(filename)' is corrupted or malformed: \(reason)."

        case .insufficientDiskSpace(let requiredBytes, let availableBytes):
            let reqStr = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
            let availStr = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
            return "Insufficient disk space. Required approx. \(reqStr), but only \(availStr) is available."

        case .destinationUnavailable(let path):
            return "Destination directory '\(path)' is read-only or unreachable."

        case .externalToolFailed(let tool, let exitCode, _):
            return "\(tool) failed with exit code \(exitCode)."

        case .cancelled:
            return "Conversion was cancelled."

        case .outputCollision(let path):
            let filename = URL(fileURLWithPath: path).lastPathComponent
            return "'\(filename)' already exists."

        case .sandboxAccessFailure(let path):
            let filename = URL(fileURLWithPath: path).lastPathComponent
            return "Unable to maintain sandbox security-scoped access to '\(filename)'."

        case .fileNotFound(let path):
            let filename = URL(fileURLWithPath: path).lastPathComponent
            return "Source file '\(filename)' was not found or was moved."

        case .invalidPreset(let reason):
            return "Preset configuration is invalid: \(reason)"

        case .backendContractViolation(let message):
            return "Backend contract violation: \(message)"

        case .executionDeadlineExceeded(let tool, let duration):
            return "\(tool) exceeded execution deadline of \(Int(duration))s."

        case .destinationChangingTooQuickly(let path):
            let filename = URL(fileURLWithPath: path).lastPathComponent
            return "Destination '\(filename)' is changing too quickly to safely complete conversion."

        case .destinationReserved(let path):
            let filename = URL(fileURLWithPath: path).lastPathComponent
            return "Another conversion in the queue is already creating '\(filename)'."

        case .admissionRejected(let reason):
            return reason

        case .imageTooLarge(let width, let height, let limit):
            let megapixels = (width * height) / 1_000_000
            return "This image is \(width)×\(height) (\(megapixels) MP), too large to convert at full size (limit \(limit) MP). Choose a preset with a size limit."

        case .unknown(let message):
            return message
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .backendUnavailable:
            return "Choose a supported backend or install the optional tool shown in Settings."
        case .dependencyMissing(_, let command):
            return "Run '\(command)' in Terminal or configure external tools in Settings > External Tools."
        case .insufficientDiskSpace:
            return "Free up disk space on the target volume and try again."
        case .permissionDenied:
            return "Select the file using File Converter's Open dialog or grant read/write access to the enclosing folder."
        case .destinationChangingTooQuickly:
            return "Wait for other processes to finish writing to the destination folder, then try again."
        case .executionDeadlineExceeded:
            return "Increase the tool execution deadline in Settings or try converting a smaller input file."
        default:
            return nil
        }
    }

    public var technicalDetails: String {
        switch self {
        case .externalToolFailed(let tool, let exitCode, let stderr):
            let home = NSHomeDirectory()
            let redacted = stderr.replacingOccurrences(of: home, with: "~")
            let bounded = String(redacted.suffix(16 * 1024))
            return "Tool: \(tool)\nExit Code: \(exitCode)\nStderr (last 16 KB):\n\(bounded)"
        case .executionDeadlineExceeded(let tool, let duration):
            return "Tool '\(tool)' timed out after \(Int(duration)) seconds."
        case .destinationChangingTooQuickly(let path):
            return "Destination '\(path)' could not be reserved because concurrent changes repeatedly conflicted."
        default:
            return errorDescription ?? "Unknown error"
        }
    }

    public var description: String {
        errorDescription ?? "ConversionError"
    }
}
