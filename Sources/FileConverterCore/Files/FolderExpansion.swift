import Foundation
import UniformTypeIdentifiers

/// The files File Converter can convert inside dropped or chosen folders,
/// including subfolders. Hidden files and the insides of packages are
/// skipped; Pages, Numbers, and Keynote packages count as files.
public enum FolderExpansion {
    public static let fileLimit = 10_000

    public struct Result: Sendable {
        public let files: [URL]
        /// More convertible files were found than `fileLimit`.
        public let wasTruncated: Bool
    }

    public static func isPlainFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return !isPackage(url)
    }

    public static func convertibleFiles(in folders: [URL], limit: Int = fileLimit) -> Result {
        var files: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        for folder in folders {
            guard let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: Set(keys))
                let isFile = values?.isRegularFile == true || (values?.isDirectory == true && isPackage(url))
                guard isFile, (values?.fileSize ?? 1) > 0 || values?.isDirectory == true else { continue }
                guard FormatDetector.detect(url: url).format != nil else { continue }
                if files.count == limit { return Result(files: files, wasTruncated: true) }
                files.append(url)
            }
        }
        return Result(files: files, wasTruncated: false)
    }

    private static func isPackage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return UTType(filenameExtension: ext)?.conforms(to: .package) == true
            || ["pages", "numbers", "key", "keynote"].contains(ext)
    }
}
