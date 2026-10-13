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
    private var probedFFmpegFilters: Set<String>?
    private var lastRefresh: Date?
    private var isRefreshing = false
    private let lock = NSLock()
    private let capabilitiesCacheURL: URL?
    private let defaults: UserDefaults

    /// UserDefaults key holding user-chosen tool locations, keyed by tool name.
    public static let toolPathOverridesKey = "fc.toolPathOverrides"

    /// Tool names this app looks for, in display order.
    public static let toolNames = ["ffmpeg", "ffprobe", "magick", "gs", "soffice", "ebook-convert"]

    public init(
        capabilitiesCacheURL: URL? = ExternalToolDiscovery.defaultCapabilitiesCacheURL,
        defaults: UserDefaults = .standard
    ) {
        self.capabilitiesCacheURL = capabilitiesCacheURL
        self.defaults = defaults
        prepopulateFastToolPaths()
        loadCachedCapabilities()
    }

    public static var defaultCapabilitiesCacheURL: URL? {
        AppDataLocation.directory?.appendingPathComponent("ffmpeg-capabilities.json")
    }

    // MARK: - Custom tool locations

    public func pathOverride(for tool: String) -> String? {
        (defaults.dictionary(forKey: Self.toolPathOverridesKey) as? [String: String])?[tool]
    }

    /// Stores a user-chosen location after checking it is an executable
    /// regular file. Returns false when the file is not usable.
    @discardableResult
    public func setPathOverride(_ path: String?, for tool: String) -> Bool {
        var overrides = (defaults.dictionary(forKey: Self.toolPathOverridesKey) as? [String: String]) ?? [:]
        if let path {
            guard let validated = Self.validatedExecutable(path) else { return false }
            overrides[tool] = validated
        } else {
            overrides.removeValue(forKey: tool)
        }
        defaults.set(overrides, forKey: Self.toolPathOverridesKey)
        return true
    }

    static func validatedExecutable(_ path: String) -> String? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: resolved) else { return nil }
        return resolved
    }

    private func validOverride(for tool: String) -> String? {
        pathOverride(for: tool).flatMap(Self.validatedExecutable)
    }

    // MARK: - Persisted FFmpeg capabilities

    private struct CapabilitiesCache: Codable {
        let ffmpegPath: String
        let fileSize: Int64
        let modificationDate: Date
        let encoders: [String]
        let filters: [String]
    }

    private static func fingerprint(of path: String) -> (size: Int64, date: Date)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let date = attributes[.modificationDate] as? Date else { return nil }
        return (size, date)
    }

    /// Loads the encoder/filter lists probed on an earlier launch, so presets
    /// that need FFmpeg are usable immediately instead of after a re-probe.
    private func loadCachedCapabilities() {
        guard let capabilitiesCacheURL,
              let ffmpegPath = cachedTools["ffmpeg"]?.executablePath,
              let data = try? Data(contentsOf: capabilitiesCacheURL),
              let cache = try? JSONDecoder().decode(CapabilitiesCache.self, from: data),
              cache.ffmpegPath == ffmpegPath,
              let current = Self.fingerprint(of: ffmpegPath),
              current.size == cache.fileSize,
              abs(current.date.timeIntervalSince(cache.modificationDate)) < 1 else { return }
        lock.withLock {
            probedFFmpegEncoders = Set(cache.encoders)
            probedFFmpegFilters = Set(cache.filters)
        }
    }

    private func storeCapabilities(ffmpegPath: String, encoders: Set<String>, filters: Set<String>) {
        guard let capabilitiesCacheURL,
              !encoders.isEmpty,
              let current = Self.fingerprint(of: ffmpegPath) else { return }
        let cache = CapabilitiesCache(
            ffmpegPath: ffmpegPath,
            fileSize: current.size,
            modificationDate: current.date,
            encoders: encoders.sorted(),
            filters: filters.sorted()
        )
        do {
            try FileManager.default.createDirectory(
                at: capabilitiesCacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(cache).write(to: capabilitiesCacheURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: capabilitiesCacheURL.path)
        } catch {
            AppLogger.backends.error("Could not save FFmpeg capabilities: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func prepopulateFastToolPaths() {
        let tools: [(name: String, command: String, paths: [String])] = [
            ("ffmpeg", "brew install ffmpeg", ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]),
            ("ffprobe", "brew install ffmpeg", ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]),
            ("magick", "brew install imagemagick", ["/opt/homebrew/bin/magick", "/usr/local/bin/magick"]),
            ("gs", "brew install ghostscript", ["/opt/homebrew/bin/gs", "/usr/local/bin/gs"]),
            ("soffice", "brew install --cask libreoffice", [
                "/Applications/LibreOffice.app/Contents/MacOS/soffice",
                "/opt/homebrew/bin/soffice",
                "/usr/local/bin/soffice"
            ]),
            ("ebook-convert", "brew install --cask calibre", [
                "/Applications/calibre.app/Contents/MacOS/ebook-convert",
                "/Applications/Calibre.app/Contents/MacOS/ebook-convert",
                "/opt/homebrew/bin/ebook-convert",
                "/usr/local/bin/ebook-convert"
            ])
        ]

        var fastCached: [String: ToolInfo] = [:]
        for tool in tools {
            var foundPath: String? = validOverride(for: tool.name)
            for path in tool.paths where foundPath == nil {
                if FileManager.default.isExecutableFile(atPath: path) {
                    foundPath = path
                    break
                }
            }
            fastCached[tool.name] = ToolInfo(
                name: tool.name,
                executablePath: foundPath,
                version: nil,
                isInstalled: foundPath != nil,
                installCommand: tool.command
            )
        }
        lock.lock()
        cachedTools = fastCached
        lock.unlock()
    }

    /// When the last completed scan happened, or nil before the first one.
    public var lastRefreshDate: Date? {
        lock.withLock { lastRefresh }
    }

    public func refreshAllTools(force: Bool = false, progress: (@Sendable (String) -> Void)? = nil) {
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
        progress?("Checking FFmpeg…")
        discoveredTools["ffmpeg"] = discoverTool(name: "ffmpeg", installCommand: "brew install ffmpeg")
        discoveredTools["ffprobe"] = discoverTool(name: "ffprobe", installCommand: "brew install ffmpeg")
        progress?("Checking ImageMagick…")
        discoveredTools["magick"] = discoverTool(name: "magick", installCommand: "brew install imagemagick")
        progress?("Checking Ghostscript…")
        discoveredTools["gs"] = discoverTool(name: "gs", installCommand: "brew install ghostscript")
        progress?("Checking LibreOffice…")
        discoveredTools["soffice"] = discoverLibreOffice()
        progress?("Checking Calibre…")
        discoveredTools["ebook-convert"] = discoverCalibre()

        var encoders: Set<String> = []
        var filters: Set<String> = []
        if let ffmpegPath = discoveredTools["ffmpeg"]?.executablePath {
            progress?("Checking FFmpeg encoders…")
            let executable = URL(fileURLWithPath: ffmpegPath)
            encoders = probeFFmpegEncoders(executableURL: executable)
            filters = probeFFmpegFilters(executableURL: executable)
            storeCapabilities(ffmpegPath: ffmpegPath, encoders: encoders, filters: filters)
        }

        lock.lock()
        cachedTools = discoveredTools
        probedFFmpegEncoders = encoders
        probedFFmpegFilters = filters
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

    /// Last probed FFmpeg filter list, or nil before any probe.
    public func cachedFFmpegFilters() -> Set<String>? {
        lock.withLock { probedFFmpegFilters }
    }

    public func hasFFmpegFilter(_ name: String) -> Bool {
        cachedFFmpegFilters()?.contains(name) ?? false
    }

    private func discoverTool(name: String, installCommand: String) -> ToolInfo {
        let candidatePaths = [validOverride(for: name)].compactMap { $0 } + searchPaths(for: name)
        for path in candidatePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                let version = queryVersion(for: path)
                return ToolInfo(name: name, executablePath: path, version: version, isInstalled: true, installCommand: installCommand)
            }
        }
        return ToolInfo(name: name, executablePath: nil, version: nil, isInstalled: false, installCommand: installCommand)
    }

    private func discoverLibreOffice() -> ToolInfo {
        let candidatePaths = [validOverride(for: "soffice")].compactMap { $0 } + [
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
        let candidatePaths = [validOverride(for: "ebook-convert")].compactMap { $0 } + [
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

    private func probeFFmpegFilters(executableURL: URL) -> Set<String> {
        let process = ExternalProcessAttempt(
            executableURL: executableURL,
            arguments: ["-filters", "-hide_banner"],
            stdoutCaptureLimit: 4 * 1024 * 1024,
            timeout: 30
        )
        do {
            let result = try process.runSynchronously()
            guard result.terminationStatus == 0 else { return [] }
            // Lines look like " ... zscale            V->V       Apply resizing…"
            var filters = Set<String>()
            for line in String(decoding: result.stdout, as: UTF8.self).components(separatedBy: .newlines) {
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 3, parts[2].contains("->") {
                    filters.insert(String(parts[1]))
                }
            }
            return filters
        } catch {
            AppLogger.backends.error("Failed to probe FFmpeg filters: \(error.localizedDescription)")
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
