import Foundation
import PDFKit

/// Holds passwords for "Protect with a password" in memory only, for as long
/// as the app runs. Presets carry a random token instead, so nothing that is
/// saved, logged, or kept in history ever contains the password.
public final class PDFPasswordVault: @unchecked Sendable {
    public static let shared = PDFPasswordVault()

    private let lock = NSLock()
    private var passwords: [String: String] = [:]

    public init() {}

    /// Keeps `password` and returns the token that names it.
    public func store(_ password: String) -> String {
        let token = UUID().uuidString
        lock.withLock { passwords[token] = password }
        return token
    }

    public func password(for token: String) -> String? {
        lock.withLock { passwords[token] }
    }

    public func remove(_ token: String) {
        lock.withLock { _ = passwords.removeValue(forKey: token) }
    }
}

public enum PDFPasswordProtection {
    /// Rewrites the PDF at `url` so it needs `password` to open. The same
    /// password is the owner password, which unlocks printing and editing.
    public static func protect(fileAt url: URL, password: String) throws {
        guard !password.isEmpty else {
            throw ConversionError.invalidPreset(reason: "The password is empty.")
        }
        guard let document = PDFDocument(url: url) else {
            throw ConversionError.malformedSource(path: url.path, reason: "The PDF could not be opened to add a password.")
        }
        guard !document.isLocked else {
            throw ConversionError.malformedSource(path: url.path, reason: "The PDF already has a password.")
        }
        // Written beside the original, then swapped in: PDFKit may still be
        // reading pages from the original while it writes.
        let protected = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-protected.pdf")
        let written = document.write(to: protected, withOptions: [
            .userPasswordOption: password,
            .ownerPasswordOption: password
        ])
        guard written else {
            try? FileManager.default.removeItem(at: protected)
            throw ConversionError.destinationUnavailable(path: url.path)
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: protected)
        } catch {
            try? FileManager.default.removeItem(at: protected)
            throw ConversionError.destinationUnavailable(path: url.path)
        }
    }

    /// Protects each PDF in `urls` with the password named by `token`.
    /// Fails, rather than saving an unprotected file, when the password is
    /// gone, for example when a job is retried after the app was quit.
    public static func protect(filesAt urls: [URL], token: String, vault: PDFPasswordVault = .shared) throws {
        guard let password = vault.password(for: token) else {
            throw ConversionError.invalidPreset(
                reason: "The password for this PDF is no longer available. Passwords aren’t saved, so start the conversion again and enter it."
            )
        }
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            try protect(fileAt: url, password: password)
        }
    }
}
