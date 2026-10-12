import Foundation

public final class SecurityScopedLease: @unchecked Sendable {
    public let url: URL

    private let lock = NSLock()
    private var _isActive: Bool

    public var isActive: Bool {
        lock.withLock { _isActive }
    }

    public init(bookmarkData: Data) throws {
        guard !bookmarkData.isEmpty else {
            throw SecurityScopedLeaseError.accessDenied
        }

        var scopedBookmarkIsStale = false
        do {
            let scopedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &scopedBookmarkIsStale
            )
            if scopedBookmarkIsStale {
                throw SecurityScopedLeaseError.staleBookmark
            }
            let accessed = scopedURL.startAccessingSecurityScopedResource()
            if Self.isExistingAndReadable(scopedURL, accessed: accessed) {
                url = scopedURL
                _isActive = accessed
                return
            }
            if accessed {
                scopedURL.stopAccessingSecurityScopedResource()
            }
        } catch let error as SecurityScopedLeaseError {
            throw error
        } catch {
            // Finder bookmarks can use implicit scope, so try the fallback
            // resolution below before classifying this as access denied.
        }

        // Finder bookmarks carry implicit scope rather than app-scoped bookmark metadata.
        var ephemeralBookmarkIsStale = false
        do {
            let ephemeralURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI, .withoutImplicitStartAccessing],
                relativeTo: nil,
                bookmarkDataIsStale: &ephemeralBookmarkIsStale
            )
            if ephemeralBookmarkIsStale {
                throw SecurityScopedLeaseError.staleBookmark
            }
            let accessed = ephemeralURL.startAccessingSecurityScopedResource()
            guard Self.isExistingAndReadable(ephemeralURL, accessed: accessed) else {
                if accessed {
                    ephemeralURL.stopAccessingSecurityScopedResource()
                }
                throw SecurityScopedLeaseError.accessDenied
            }
            url = ephemeralURL
            _isActive = accessed
        } catch let error as SecurityScopedLeaseError {
            throw error
        } catch {
            throw SecurityScopedLeaseError.accessDenied
        }
    }

    private static func isExistingAndReadable(_ url: URL, accessed: Bool) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return accessed || FileManager.default.isReadableFile(atPath: url.path)
    }

    public func release() {
        lock.lock()
        guard _isActive else {
            lock.unlock()
            return
        }
        _isActive = false
        lock.unlock()
        url.stopAccessingSecurityScopedResource()
    }

    deinit {
        release()
    }
}

public enum SecurityScopedLeaseError: LocalizedError, Sendable {
    case staleBookmark
    case accessDenied

    public var errorDescription: String? {
        switch self {
        case .staleBookmark:
            return "The selected file authorization is stale."
        case .accessDenied:
            return "File Converter could not access the selected file."
        }
    }
}
