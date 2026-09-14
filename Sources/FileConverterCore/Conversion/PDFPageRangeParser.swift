import Foundation

public struct PDFSplitOutputPlan: Equatable, Sendable {
    public let suffix: String
    public let pageIndices: [Int] // 0-based page indices for PDFKit

    public init(suffix: String, pageIndices: [Int]) {
        self.suffix = suffix
        self.pageIndices = pageIndices
    }
}

public enum PDFPageRangeParser {
    /// Parses a human-entered page range string like "1-5, 8, 11-14, 20-end"
    /// against a document's total page count.
    /// Returns sorted, clamped 1-based ranges.
    public static func parseRanges(_ input: String, totalPages: Int) -> [ClosedRange<Int>] {
        guard totalPages > 0 else { return [] }
        let parts = input
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var results: [ClosedRange<Int>] = []

        for part in parts {
            if part.contains("-") {
                let bounds = part.components(separatedBy: "-")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                if bounds.count == 2 {
                    guard let lower = Int(bounds[0]) else { continue }
                    let upper: Int
                    if bounds[1] == "end" || bounds[1] == "last" || bounds[1] == "$" {
                        upper = totalPages
                    } else if let parsedUpper = Int(bounds[1]) {
                        upper = parsedUpper
                    } else {
                        continue
                    }
                    guard lower <= totalPages, upper >= 1, lower >= 1 else { continue }
                    let start = max(1, min(lower, upper))
                    let end = min(totalPages, max(lower, upper))
                    if start <= end {
                        results.append(start...end)
                    }
                }
            } else if let single = Int(part), single >= 1, single <= totalPages {
                results.append(single...single)
            }
        }

        return results
    }

    /// Computes the planned output files and their 0-based page indices according to
    /// the requested split mode and options.
    public static func planOutputs(
        totalPages: Int,
        splitMode: String?,
        pageRanges: String?,
        chunkSize: Int?,
        selectedPages: [Int]?,
        mergeOutputs: Bool,
        namingPattern: String? = nil,
        zeroPadDigits: Int? = nil
    ) -> [PDFSplitOutputPlan] {
        guard totalPages > 0 else { return [] }

        let mode = splitMode ?? "all"
        let padWidth = zeroPadDigits ?? 3

        func formatNumber(_ n: Int) -> String {
            String(format: "%0*d", padWidth, n)
        }

        switch mode {
        case "all":
            return (0..<totalPages).map { pageIndex in
                let pageNumber = pageIndex + 1
                let suffix = ConversionOutputSequence.suffix(
                    prefix: "page",
                    index: pageNumber,
                    totalCount: totalPages,
                    minimumWidth: padWidth
                )
                return PDFSplitOutputPlan(suffix: suffix, pageIndices: [pageIndex])
            }

        case "ranges":
            let parsed = parseRanges(pageRanges ?? "1-\(totalPages)", totalPages: totalPages)
            guard !parsed.isEmpty else {
                return planOutputs(
                    totalPages: totalPages,
                    splitMode: "all",
                    pageRanges: nil,
                    chunkSize: nil,
                    selectedPages: nil,
                    mergeOutputs: false
                )
            }

            if mergeOutputs {
                var uniquePages = Set<Int>()
                var orderedPages: [Int] = []
                for range in parsed {
                    for page in range {
                        if uniquePages.insert(page).inserted {
                            orderedPages.append(page - 1)
                        }
                    }
                }
                return [PDFSplitOutputPlan(suffix: "extracted", pageIndices: orderedPages)]
            } else {
                return parsed.enumerated().map { index, range in
                    let suffix: String
                    if range.count == 1 {
                        suffix = "page-\(formatNumber(range.lowerBound))"
                    } else {
                        suffix = "pages-\(range.lowerBound)-\(range.upperBound)"
                    }
                    let indices = (range.lowerBound...range.upperBound).map { $0 - 1 }
                    return PDFSplitOutputPlan(suffix: suffix, pageIndices: indices)
                }
            }

        case "chunks":
            let size = max(1, chunkSize ?? 1)
            var plans: [PDFSplitOutputPlan] = []
            var part = 1
            for start in stride(from: 0, to: totalPages, by: size) {
                let end = min(start + size, totalPages)
                let indices = Array(start..<end)
                let suffix = "part-\(formatNumber(part))"
                plans.append(PDFSplitOutputPlan(suffix: suffix, pageIndices: indices))
                part += 1
            }
            return plans

        case "evenOdd":
            let oddIndices = (0..<totalPages).filter { $0 % 2 == 0 } // 0-based: 0, 2, 4 -> 1, 3, 5
            let evenIndices = (0..<totalPages).filter { $0 % 2 != 0 } // 0-based: 1, 3, 5 -> 2, 4, 6
            var plans: [PDFSplitOutputPlan] = []
            if !oddIndices.isEmpty {
                plans.append(PDFSplitOutputPlan(suffix: "odd", pageIndices: oddIndices))
            }
            if !evenIndices.isEmpty {
                plans.append(PDFSplitOutputPlan(suffix: "even", pageIndices: evenIndices))
            }
            return plans

        case "selected":
            let pages = (selectedPages ?? Array(1...totalPages))
                .filter { $0 >= 1 && $0 <= totalPages }
                .sorted()
            guard !pages.isEmpty else {
                return planOutputs(
                    totalPages: totalPages,
                    splitMode: "all",
                    pageRanges: nil,
                    chunkSize: nil,
                    selectedPages: nil,
                    mergeOutputs: false
                )
            }

            if mergeOutputs {
                let indices = pages.map { $0 - 1 }
                return [PDFSplitOutputPlan(suffix: "selected", pageIndices: indices)]
            } else {
                return pages.map { page in
                    PDFSplitOutputPlan(
                        suffix: "page-\(formatNumber(page))",
                        pageIndices: [page - 1]
                    )
                }
            }

        default:
            return (0..<totalPages).map { pageIndex in
                let suffix = ConversionOutputSequence.suffix(
                    prefix: "page",
                    index: pageIndex + 1,
                    totalCount: totalPages,
                    minimumWidth: padWidth
                )
                return PDFSplitOutputPlan(suffix: suffix, pageIndices: [pageIndex])
            }
        }
    }
}
