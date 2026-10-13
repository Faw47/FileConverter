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
        func name(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }
        switch self {
        case .unsupportedInputFormat(let path, let detectedType):
            if let detectedType {
                return "File Converter can’t convert \(detectedType) files like “\(name(path))”."
            }
            return "File Converter doesn’t recognize the format of “\(name(path))”."

        case .unsupportedOutputFormat(let targetFormat):
            return "File Converter can’t make \(targetFormat.uppercased()) files."

        case .incompatibleConversion(let source, let target):
            return "\(source.uppercased()) files can’t be converted to \(target.uppercased())."

        case .backendUnavailable(let backend):
            return "This conversion needs \(backend), which isn’t available."

        case .dependencyMissing(let tool, _):
            return "This conversion needs \(tool), which isn’t installed."

        case .permissionDenied(let path):
            return "File Converter isn’t allowed to open “\(name(path))”."

        case .encoderUnavailable(let codec, _):
            return "This Mac can’t make \(codec) video or audio."

        case .decoderUnavailable(let codec, _):
            return "This Mac can’t read the \(codec) video or audio in this file."

        case .malformedSource(let path, _):
            return "“\(name(path))” is damaged or incomplete."

        case .insufficientDiskSpace(let requiredBytes, let availableBytes):
            let required = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
            return "Not enough disk space: about \(required) is needed and \(available) is free."

        case .destinationUnavailable(let path):
            return "Can’t save to “\(name(path))”. The folder is read-only or no longer available."

        case .externalToolFailed(let tool, _, _):
            return "\(tool) couldn’t convert this file."

        case .cancelled:
            return "Cancelled."

        case .outputCollision(let path):
            return "“\(name(path))” already exists."

        case .sandboxAccessFailure(let path):
            return "File Converter lost access to “\(name(path))”."

        case .fileNotFound(let path):
            return "“\(name(path))” was moved or deleted."

        case .invalidPreset:
            return "This preset has settings that don’t work together."

        case .backendContractViolation:
            return "Something went wrong inside File Converter."

        case .executionDeadlineExceeded(let tool, _):
            return "\(tool) stopped responding."

        case .destinationChangingTooQuickly(let path):
            return "“\(name(path))” kept changing while File Converter tried to save it."

        case .destinationReserved(let path):
            return "Another conversion in the queue is already making “\(name(path))”."

        case .admissionRejected(let reason):
            return reason

        case .imageTooLarge(let width, let height, let limit):
            let megapixels = (width * height) / 1_000_000
            return "This image is \(width) × \(height) (\(megapixels) MP), larger than the \(limit) MP that can be converted at full size. Choose a preset with a size limit."

        case .unknown(let message):
            return message
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .backendUnavailable:
            return "Install the tool it needs; Settings › External Tools shows what is missing."
        case .dependencyMissing(_, let command):
            return "Install it with “\(command)” in Terminal, then try again. Settings › External Tools shows what was found."
        case .insufficientDiskSpace:
            return "Free up space on the disk you’re saving to, then try again."
        case .permissionDenied, .sandboxAccessFailure:
            return "Add the file again with Choose Files… or by dropping it on the window."
        case .destinationChangingTooQuickly:
            return "Wait until other apps finish writing to that folder, then try again."
        case .executionDeadlineExceeded:
            return "Try again, or try a smaller file."
        case .malformedSource:
            return "Check that the file opens in another app."
        case .encoderUnavailable, .decoderUnavailable:
            return "Installing FFmpeg adds support for more formats."
        case .backendContractViolation:
            return "Try again. If it keeps happening, copy the details and report it."
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
        case .encoderUnavailable(let codec, let reason):
            return "Encoder '\(codec)' unavailable: \(reason)"
        case .decoderUnavailable(let codec, let reason):
            return "Decoder '\(codec)' failed: \(reason)"
        case .malformedSource(let path, let reason):
            return "Malformed source '\(path)': \(reason)"
        case .invalidPreset(let reason):
            return "Invalid preset: \(reason)"
        case .backendContractViolation(let message):
            return "Backend contract violation: \(message)"
        case .sandboxAccessFailure(let path):
            return "Security-scoped access to '\(path)' could not be kept."
        case .dependencyMissing(let tool, let command):
            return "Missing dependency: \(tool)\nInstall command: \(command)"
        default:
            return errorDescription ?? "Unknown error"
        }
    }

    public var description: String {
        errorDescription ?? "ConversionError"
    }
}
