import Foundation

/// Closed while optional tools (FFmpeg encoders, ImageMagick, …) are being
/// discovered. Finder requests that need those tools wait here instead of
/// being rejected during the first seconds after a cold launch.
///
/// The gate starts open; the app closes it synchronously right before
/// discovery starts, so a request arriving at launch cannot slip through.
public final class BackendReadinessGate: @unchecked Sendable {
    public static let shared = BackendReadinessGate()

    private let lock = NSLock()
    private var isReady = true
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    public init() {}

    public var ready: Bool {
        lock.withLock { isReady }
    }

    public func markNotReady() {
        lock.withLock { isReady = false }
    }

    public func markReady() {
        let pending = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
            isReady = true
            let values = Array(waiters.values)
            waiters.removeAll()
            return values
        }
        for continuation in pending {
            continuation.resume(returning: true)
        }
    }

    /// Returns true when the gate is open, false when the timeout passed first.
    public func waitUntilReady(timeout: Duration = .seconds(30)) async -> Bool {
        if ready { return true }
        let id = UUID()
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.expire(id)
        }
        let opened = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if isReady { return true }
                waiters[id] = continuation
                return false
            }
            if resumeNow { continuation.resume(returning: true) }
        }
        timeoutTask.cancel()
        return opened
    }

    private func expire(_ id: UUID) {
        let continuation = lock.withLock { waiters.removeValue(forKey: id) }
        continuation?.resume(returning: false)
    }
}
