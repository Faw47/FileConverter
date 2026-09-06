import Darwin
import Foundation

struct ExternalProcessResult: Sendable {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: String
}

enum ExternalProcessRunnerError: Error {
    case alreadyStarted
    case timedOut
}

final class ExternalProcessAttempt: @unchecked Sendable {
    static let defaultStderrCaptureLimit = 64 * 1024

    private enum State {
        case ready
        case launching
        case running
        case terminated
    }

    private static let executionQueue = DispatchQueue(
        label: "FileConverter.ExternalProcess.execution",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let drainQueue = DispatchQueue(
        label: "FileConverter.ExternalProcess.drain",
        qos: .utility,
        attributes: .concurrent
    )

    private let process: Process
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutCaptureLimit: Int
    private let stderrCaptureLimit: Int
    private let terminationGracePeriod: TimeInterval
    private let timeout: TimeInterval?
    private let stdoutLineHandler: (@Sendable (String) -> Void)?

    private let stateLock = NSLock()
    private var state: State = .ready
    private var didLaunch = false
    private var cancellationRequested = false
    private var terminationSent = false
    private var forceTerminationSent = false
    private var timedOut = false

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        stdoutCaptureLimit: Int = 0,
        stderrCaptureLimit: Int = ExternalProcessAttempt.defaultStderrCaptureLimit,
        terminationGracePeriod: TimeInterval = 1.5,
        timeout: TimeInterval? = nil,
        stdoutLineHandler: (@Sendable (String) -> Void)? = nil
    ) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.process = process
        self.stdoutCaptureLimit = max(0, stdoutCaptureLimit)
        self.stderrCaptureLimit = max(0, stderrCaptureLimit)
        self.terminationGracePeriod = max(0, terminationGracePeriod)
        self.timeout = timeout.map { max(0, $0) }
        self.stdoutLineHandler = stdoutLineHandler
    }

    var hasLaunched: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return didLaunch
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state == .running
    }

    func run() async throws -> ExternalProcessResult {
        if Task.isCancelled {
            cancel()
        }

        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.executionQueue.async {
                    do {
                        continuation.resume(returning: try self.runSynchronously())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }

        try Task.checkCancellation()
        return result
    }

    func runSynchronously() throws -> ExternalProcessResult {
        try beginLaunching()

        do {
            try process.run()
        } catch {
            markTerminated()
            throw error
        }

        let stdoutCapture = BoundedDataCapture(limit: stdoutCaptureLimit)
        let stderrCapture = BoundedDataCapture(limit: stderrCaptureLimit)
        let drainGroup = DispatchGroup()

        startDrain(
            handle: stdoutPipe.fileHandleForReading,
            capture: stdoutCapture,
            lineHandler: stdoutLineHandler,
            group: drainGroup
        )
        startDrain(
            handle: stderrPipe.fileHandleForReading,
            capture: stderrCapture,
            lineHandler: nil,
            group: drainGroup
        )

        markRunning()
        terminateIfRequested()
        if let timeout, timeout > 0 {
            Self.executionQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.isRunning else { return }
                self.stateLock.lock()
                self.timedOut = true
                self.cancellationRequested = true
                self.stateLock.unlock()
                self.terminateIfRequested()
            }
        }
        process.waitUntilExit()

        let terminationStatus = process.terminationStatus
        markTerminated()
        drainGroup.wait()

        if wasCancellationRequested {
            if wasTimedOut { throw ExternalProcessRunnerError.timedOut }
            throw CancellationError()
        }

        return ExternalProcessResult(
            terminationStatus: terminationStatus,
            stdout: stdoutCapture.content,
            stderr: String(decoding: stderrCapture.content, as: UTF8.self)
        )
    }

    func cancel() {
        stateLock.lock()
        cancellationRequested = true
        stateLock.unlock()
        terminateIfRequested()
    }

    private var wasCancellationRequested: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancellationRequested
    }

    private var wasTimedOut: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return timedOut
    }

    private func beginLaunching() throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard state == .ready else {
            throw ExternalProcessRunnerError.alreadyStarted
        }
        guard !cancellationRequested else {
            state = .terminated
            throw CancellationError()
        }
        state = .launching
    }

    private func markRunning() {
        stateLock.lock()
        didLaunch = true
        state = .running
        stateLock.unlock()
    }

    private func markTerminated() {
        stateLock.lock()
        state = .terminated
        stateLock.unlock()
    }

    private func terminateIfRequested() {
        stateLock.lock()
        let shouldTerminate = state == .running && cancellationRequested && !terminationSent
        if shouldTerminate {
            terminationSent = true
        }
        stateLock.unlock()

        guard shouldTerminate, process.isRunning else { return }
        process.terminate()

        Self.executionQueue.asyncAfter(deadline: .now() + terminationGracePeriod) { [weak self] in
            self?.forceTerminateIfNeeded()
        }
    }

    private func forceTerminateIfNeeded() {
        stateLock.lock()
        let shouldForceTerminate = state == .running
            && cancellationRequested
            && !forceTerminationSent
        if shouldForceTerminate {
            forceTerminationSent = true
        }
        stateLock.unlock()

        guard shouldForceTerminate, process.isRunning else { return }
        let processIdentifier = process.processIdentifier
        if processIdentifier > 0 {
            kill(processIdentifier, SIGKILL)
        }
    }

    private func startDrain(
        handle: FileHandle,
        capture: BoundedDataCapture,
        lineHandler: (@Sendable (String) -> Void)?,
        group: DispatchGroup
    ) {
        group.enter()
        Self.drainQueue.async {
            defer {
                try? handle.close()
                group.leave()
            }

            var pendingLine = ""
            while true {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { break }
                capture.append(chunk)

                guard let lineHandler else { continue }
                pendingLine.append(String(decoding: chunk, as: UTF8.self))
                var lines = pendingLine.components(separatedBy: "\n")
                pendingLine = lines.removeLast()
                for line in lines {
                    lineHandler(line)
                }
                if pendingLine.count > 64 * 1024 {
                    pendingLine = String(pendingLine.suffix(64 * 1024))
                }
            }

            if let lineHandler, !pendingLine.isEmpty {
                lineHandler(pendingLine)
            }
        }
    }
}

final class ExternalProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [UUID: [ObjectIdentifier: ExternalProcessAttempt]] = [:]

    func run(_ attempt: ExternalProcessAttempt, for jobID: UUID) async throws -> ExternalProcessResult {
        register(attempt, for: jobID)
        defer { unregister(attempt, for: jobID) }
        return try await attempt.run()
    }

    func cancel(jobID: UUID) {
        lock.lock()
        let activeAttempts = attempts[jobID].map { Array($0.values) } ?? []
        lock.unlock()

        for attempt in activeAttempts {
            attempt.cancel()
        }
    }

    func activeAttemptCount(for jobID: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts[jobID]?.count ?? 0
    }

    private func register(_ attempt: ExternalProcessAttempt, for jobID: UUID) {
        lock.lock()
        attempts[jobID, default: [:]][ObjectIdentifier(attempt)] = attempt
        lock.unlock()
    }

    private func unregister(_ attempt: ExternalProcessAttempt, for jobID: UUID) {
        lock.lock()
        attempts[jobID]?[ObjectIdentifier(attempt)] = nil
        if attempts[jobID]?.isEmpty == true {
            attempts[jobID] = nil
        }
        lock.unlock()
    }
}

private final class BoundedDataCapture: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var storage = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ data: Data) {
        guard limit > 0, !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        if data.count >= limit {
            storage = Data(data.suffix(limit))
            return
        }

        let overflow = storage.count + data.count - limit
        if overflow > 0 {
            storage.removeFirst(overflow)
        }
        storage.append(data)
    }

    var content: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
