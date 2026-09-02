import Foundation

public final class SecurityScopedLease: @unchecked Sendable {
    public let url: URL

    private let lock = NSLock()
    private var isActive: Bool

    public init(bookmarkData: Data) throws {
        var scopedBookmarkIsStale = false
        if let scopedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &scopedBookmarkIsStale
           ), !scopedBookmarkIsStale,
           scopedURL.startAccessingSecurityScopedResource() {
            url = scopedURL
            isActive = true
            return
        }

        // Finder bookmarks carry implicit scope rather than app-scoped bookmark metadata.
        var ephemeralBookmarkIsStale = false
        let ephemeralURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI, .withoutImplicitStartAccessing],
            relativeTo: nil,
            bookmarkDataIsStale: &ephemeralBookmarkIsStale
        )
        guard !ephemeralBookmarkIsStale else {
            throw SecurityScopedLeaseError.staleBookmark
        }
        guard ephemeralURL.startAccessingSecurityScopedResource() else {
            throw SecurityScopedLeaseError.accessDenied
        }
        url = ephemeralURL
        isActive = true
    }

    public func release() {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        isActive = false
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
