import Darwin
import Foundation
import FileConverterCore

/// Recognized external tools and their finite execution deadlines.
public enum ExternalProcessTool: String, Sendable {
    case probe = "Probe"
    case ffmpeg = "FFmpeg"
    case imageMagick = "ImageMagick"
    case libreOffice = "LibreOffice"
    case ghostscript = "Ghostscript"
    case calibre = "Calibre"

    public var defaultDeadline: TimeInterval {
        switch self {
        case .probe: return 15.0
        case .imageMagick: return 120.0
        case .libreOffice: return 300.0
        case .ghostscript: return 300.0
        case .calibre: return 600.0
        case .ffmpeg: return 3600.0
        }
    }
}

/// A central supervisor that coordinates all external converter subprocesses,
/// enforcing closed stdin, finite deadlines, process group cancellation,
/// and registered attempt tracking.
public final class ExternalProcessSupervisor: @unchecked Sendable {
    public static let shared = ExternalProcessSupervisor()

    public let registry: ExternalProcessRegistry

    public init(registry: ExternalProcessRegistry = ExternalProcessRegistry()) {
        self.registry = registry
    }

    public func run(
        tool: ExternalProcessTool,
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        stdoutCaptureLimit: Int = 0,
        stderrCaptureLimit: Int = 64 * 1024,
        terminationGracePeriod: TimeInterval = 1.5,
        deadline: TimeInterval? = nil,
        stdoutLineHandler: (@Sendable (String) -> Void)? = nil,
        for jobID: UUID
    ) async throws -> ExternalProcessResult {
        let effectiveTimeout = deadline ?? tool.defaultDeadline
        let attempt = ExternalProcessAttempt(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            stdoutCaptureLimit: stdoutCaptureLimit,
            stderrCaptureLimit: stderrCaptureLimit,
            terminationGracePeriod: terminationGracePeriod,
            timeout: effectiveTimeout,
            stdoutLineHandler: stdoutLineHandler
        )
        do {
            return try await registry.run(attempt, for: jobID)
        } catch ExternalProcessRunnerError.timedOut {
            throw ConversionError.executionDeadlineExceeded(
                tool: tool.rawValue,
                duration: effectiveTimeout
            )
        }
    }

    public func cancel(jobID: UUID) {
        registry.cancel(jobID: jobID)
    }

    public func activeAttemptCount(for jobID: UUID) -> Int {
        registry.activeAttemptCount(for: jobID)
    }
}
