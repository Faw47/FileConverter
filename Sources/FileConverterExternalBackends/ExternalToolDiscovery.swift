import Foundation
import FileConverterCore

public struct ToolInfo: Sendable, Identifiable, Codable {
    public var id: String { name }
    public let name: String
    public let executablePath: String?
    public let version: String?
    public let isInstalled: Bool
    public let installCommand: String

    public init(
        name: String,
        executablePath: String?,
        version: String?,
        isInstalled: Bool,
        installCommand: String
    ) {
        self.name = name
        self.executablePath = executablePath
        self.version = version
        self.isInstalled = isInstalled
        self.installCommand = installCommand
    }
}

public final class ExternalToolDiscovery: @unchecked Sendable {
    public static let shared = ExternalToolDiscovery()
    public static let didRefreshNotification = Notification.Name("io.fileconverter.externalToolsDidRefresh")

    private var cachedTools: [String: ToolInfo] = [:]
    private var probedFFmpegEncoders: Set<String>?
    private var lastRefresh: Date?
    private var isRefreshing = false
    private let lock = NSLock()

    public init() {}

    public func refreshAllTools(force: Bool = false) {
        lock.lock()
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 300 {
            lock.unlock()
            return
        }
        guard !isRefreshing else {
            lock.unlock()
            return
        }
        isRefreshing = true
        lock.unlock()

        // Process launches can take seconds on a cold system. Perform them
        // without holding the cache lock so availability reads stay instant.
        var discoveredTools: [String: ToolInfo] = [:]
        discoveredTools["ffmpeg"] = discoverTool(name: "ffmpeg", installCommand: "brew install ffmpeg")
        discoveredTools["ffprobe"] = discoverTool(name: "ffprobe", installCommand: "brew install ffmpeg")
        discoveredTools["magick"] = discoverTool(name: "magick", installCommand: "brew install imagemagick")
        discoveredTools["gs"] = discoverTool(name: "gs", installCommand: "brew install ghostscript")
        discoveredTools["soffice"] = discoverLibreOffice()
        discoveredTools["ebook-convert"] = discoverCalibre()

        let encoders: Set<String>
        if let ffmpegPath = discoveredTools["ffmpeg"]?.executablePath {
            encoders = probeFFmpegEncoders(executableURL: URL(fileURLWithPath: ffmpegPath))
        } else {
            encoders = []
        }

        lock.lock()
        cachedTools = discoveredTools
        probedFFmpegEncoders = encoders
        lastRefresh = Date()
        isRefreshing = false
        lock.unlock()

        NotificationCenter.default.post(name: Self.didRefreshNotification, object: self)
    }

    public func toolInfo(for name: String) -> ToolInfo? {
        lock.lock()
        defer { lock.unlock() }
        return cachedTools[name]
    }

    public func isToolAvailable(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cachedTools[name]?.isInstalled ?? false
    }

    public func executablePath(for name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedTools[name]?.executablePath
    }

    public func allTools() -> [ToolInfo] {
        lock.lock()
        defer { lock.unlock() }
        return Array(cachedTools.values)
    }

    /// Returns the last completed encoder probe without launching a process.
    /// A nil value means discovery has not completed yet.
    public func cachedAvailableFFmpegEncoders() -> Set<String>? {
        cachedFFmpegEncoders()
    }

    public func availableFFmpegEncoders() -> Set<String> {
        if let cached = cachedFFmpegEncoders() {
            return cached
        }

        guard let ffmpegPath = executablePath(for: "ffmpeg") else {
            return []
        }

        let encoders = probeFFmpegEncoders(executableURL: URL(fileURLWithPath: ffmpegPath))

        cacheFFmpegEncoders(encoders)
        return encoders
    }

    func availableFFmpegEncoders(
        executableURL: URL,
        processRegistry: ExternalProcessRegistry,
        jobID: UUID
    ) async throws -> Set<String> {
        if let cached = cachedFFmpegEncoders() {
            return cached
        }

        let process = ExternalProcessAttempt(
            executableURL: executableURL,
            arguments: ["-encoders", "-hide_banner"],
            stdoutCaptureLimit: 4 * 1024 * 1024,
            timeout: 30
        )

        let encoders: Set<String>
        do {
            let result = try await processRegistry.run(process, for: jobID)
            encoders = result.terminationStatus == 0 ? parseFFmpegEncoders(result.stdout) : []
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLogger.backends.error("Failed to probe FFmpeg encoders: \(error.localizedDescription)")
            encoders = []
        }

        cacheFFmpegEncoders(encoders)
        return encoders
    }

    // MARK: - Private Discovery Helpers

    private func discoverTool(name: String, installCommand: String) -> ToolInfo {
        let candidatePaths = searchPaths(for: name)
        for path in candidatePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                let version = queryVersion(for: path)
                return ToolInfo(name: name, executablePath: path, version: version, isInstalled: true, installCommand: installCommand)
            }
        }
        return ToolInfo(name: name, executablePath: nil, version: nil, isInstalled: false, installCommand: installCommand)
    }

    private func discoverLibreOffice() -> ToolInfo {
        let candidatePaths = [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "/opt/homebrew/bin/soffice",
            "/usr/local/bin/soffice"
        ]
        for path in candidatePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                let version = queryVersion(for: path, args: ["--version"])
                return ToolInfo(name: "soffice", executablePath: path, version: version, isInstalled: true, installCommand: "brew install --cask libreoffice")
            }
        }
        return ToolInfo(name: "soffice", executablePath: nil, version: nil, isInstalled: false, installCommand: "brew install --cask libreoffice")
    }

    private func discoverCalibre() -> ToolInfo {
        let candidatePaths = [
            "/Applications/calibre.app/Contents/MacOS/ebook-convert",
            "/Applications/Calibre.app/Contents/MacOS/ebook-convert",
            "/opt/homebrew/bin/ebook-convert",
            "/usr/local/bin/ebook-convert"
        ] + searchPaths(for: "ebook-convert")
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            let version = queryVersion(for: path, args: ["--version"])
            return ToolInfo(
                name: "ebook-convert",
                executablePath: path,
                version: version,
                isInstalled: true,
                installCommand: "brew install --cask calibre"
            )
        }
        return ToolInfo(
            name: "ebook-convert",
            executablePath: nil,
            version: nil,
            isInstalled: false,
            installCommand: "brew install --cask calibre"
        )
    }

    private func searchPaths(for toolName: String) -> [String] {
        var paths: [String] = [
            "/opt/homebrew/bin/\(toolName)",
            "/usr/local/bin/\(toolName)",
            "/usr/bin/\(toolName)",
            "/bin/\(toolName)"
        ]

        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            for dir in envPath.split(separator: ":") {
                let candidate = "\(dir)/\(toolName)"
                if !paths.contains(candidate) {
                    paths.append(candidate)
                }
            }
        }
        return paths
    }

    private func queryVersion(for executablePath: String, args: [String] = ["-version", "--version"]) -> String? {
        for arg in args {
            let process = ExternalProcessAttempt(
                executableURL: URL(fileURLWithPath: executablePath),
                arguments: [arg],
                stdoutCaptureLimit: 64 * 1024,
                timeout: 5
            )

            do {
                let result = try process.runSynchronously()
                let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
                let output = (stdout.isEmpty ? result.stderr : stdout)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !output.isEmpty {
                    let firstLine = output.components(separatedBy: .newlines).first ?? output
                    return firstLine
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private func probeFFmpegEncoders(executableURL: URL) -> Set<String> {
        let process = ExternalProcessAttempt(
            executableURL: executableURL,
            arguments: ["-encoders", "-hide_banner"],
            stdoutCaptureLimit: 4 * 1024 * 1024,
            timeout: 30
        )

        do {
            let result = try process.runSynchronously()
            return result.terminationStatus == 0 ? parseFFmpegEncoders(result.stdout) : []
        } catch {
            AppLogger.backends.error("Failed to probe FFmpeg encoders: \(error.localizedDescription)")
            return []
        }
    }

    private func cachedFFmpegEncoders() -> Set<String>? {
        lock.lock()
        defer { lock.unlock() }
        return probedFFmpegEncoders
    }

    private func cacheFFmpegEncoders(_ encoders: Set<String>) {
        lock.lock()
        probedFFmpegEncoders = encoders
        lock.unlock()
    }

    private func parseFFmpegEncoders(_ data: Data) -> Set<String> {
        let output = String(decoding: data, as: UTF8.self)
        var encoders = Set<String>()
        for line in output.components(separatedBy: .newlines) {
            let parts = line
                .trimmingCharacters(in: .whitespaces)
                .split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2 {
                encoders.insert(String(parts[1]))
            }
        }
        return encoders
    }
}
