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
    /// Strict diagnostic result. Invalid tokens, reversed ranges,
    /// out-of-bounds pages, and empty selections are reported explicitly
    /// instead of silently falling back to all pages.
    public struct ParseResult: Equatable, Sendable {
        public let validRanges: [ClosedRange<Int>]
        public let invalidTokens: [String]
        public let reversedRanges: [String]
        public let outOfBoundsPages: [String]
        public let isEmptySelection: Bool

        public init(
            validRanges: [ClosedRange<Int>] = [],
            invalidTokens: [String] = [],
            reversedRanges: [String] = [],
            outOfBoundsPages: [String] = [],
            isEmptySelection: Bool = false
        ) {
            self.validRanges = validRanges
            self.invalidTokens = invalidTokens
            self.reversedRanges = reversedRanges
            self.outOfBoundsPages = outOfBoundsPages
            self.isEmptySelection = isEmptySelection
        }

        public var isValid: Bool {
            !validRanges.isEmpty && invalidTokens.isEmpty && reversedRanges.isEmpty && outOfBoundsPages.isEmpty
        }

        public var errorMessage: String? {
            if isEmptySelection { return "Enter page numbers (1 to total pages)." }
            var parts: [String] = []
            if !reversedRanges.isEmpty {
                parts.append("Reversed range(s) \(reversedRanges.joined(separator: ", ")): use start-end in increasing order.")
            }
            if !invalidTokens.isEmpty {
                parts.append("Invalid page selection: \(invalidTokens.joined(separator: ", ")).")
            }
            if !outOfBoundsPages.isEmpty {
                parts.append("Out of bounds: \(outOfBoundsPages.joined(separator: ", ")).")
            }
            if validRanges.isEmpty && !parts.isEmpty {
                return parts.joined(separator: " ")
            }
            if validRanges.isEmpty {
                return "Enter page numbers (1 to total pages)."
            }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    /// Strict parse that never reorders reversed ranges and never clamps
    /// silently. Use for interactive workflows; invalid input must prevent
    /// conversion rather than selecting all pages.
    public static func parseRangesStrict(_ input: String, totalPages: Int) -> ParseResult {
        guard totalPages > 0 else {
            return ParseResult(isEmptySelection: true)
        }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParseResult(isEmptySelection: true)
        }
        let parts = input
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            return ParseResult(isEmptySelection: true)
        }

        var valid: [ClosedRange<Int>] = []
        var invalid: [String] = []
        var reversed: [String] = []
        var oob: [String] = []

        for part in parts {
            if part.contains("-") {
                let bounds = part.components(separatedBy: "-")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                guard bounds.count == 2 else {
                    invalid.append(part)
                    continue
                }
                guard let lower = Int(bounds[0]) else {
                    invalid.append(part)
                    continue
                }
                let upper: Int
                if bounds[1] == "end" || bounds[1] == "last" || bounds[1] == "$" {
                    upper = totalPages
                } else if let parsedUpper = Int(bounds[1]) {
                    upper = parsedUpper
                } else {
                    invalid.append(part)
                    continue
                }
                if lower > upper {
                    reversed.append(part)
                    continue
                }
                if lower < 1 || upper < 1 || lower > totalPages || upper > totalPages {
                    oob.append(part)
                    continue
                }
                valid.append(lower...upper)
            } else if let single = Int(part) {
                if single < 1 || single > totalPages {
                    oob.append(part)
                } else {
                    valid.append(single...single)
                }
            } else {
                invalid.append(part)
            }
        }

        return ParseResult(
            validRanges: valid,
            invalidTokens: invalid,
            reversedRanges: reversed,
            outOfBoundsPages: oob,
            isEmptySelection: valid.isEmpty && invalid.isEmpty && reversed.isEmpty && oob.isEmpty
        )
    }

    /// Parses a human-entered page range string like "1-5, 8, 11-14, 20-end"
    /// against a document's total page count.
    /// Compatibility wrapper returning only valid ranges. Reversed ranges are
    /// excluded (never silently reordered); callers needing diagnostics must
    /// use `parseRangesStrict`.
    public static func parseRanges(_ input: String, totalPages: Int) -> [ClosedRange<Int>] {
        parseRangesStrict(input, totalPages: totalPages).validRanges
    }

    /// The pages picked when a split dialog opens with nothing selected:
    /// the first few pages, or none when the document has no pages.
    public static func defaultSelection(totalPages: Int, limit: Int = 5) -> Set<Int> {
        guard totalPages > 0, limit > 0 else { return [] }
        return Set(1...min(totalPages, limit))
    }

    /// Computes the planned output files and their 0-based page indices according to
    /// the requested split mode and options.
    public static func planOutputs(
        totalPages: Int,
        splitMode: String?,
        pageRanges: String?,
        chunkSize: Int? = nil,
        selectedPages: [Int]? = nil,
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
            // Strict: invalid, reversed, out-of-bounds, or empty selections
            // produce zero outputs so the caller surfaces a validation error
            // instead of silently converting all pages.
            let rangeInput = (pageRanges ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rangeInput.isEmpty else { return [] }
            let parsedResult = parseRangesStrict(rangeInput, totalPages: totalPages)
            // A partially valid input is still invalid. Returning the valid
            // subset would make a typo such as "1-2, abc" silently produce
            // the wrong set of files.
            guard parsedResult.isValid else { return [] }
            let parsed = parsedResult.validRanges

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
                let initialPlans = parsed.map { range -> (baseSuffix: String, indices: [Int]) in
                    let baseSuffix: String
                    if range.count == 1 {
                        baseSuffix = "page-\(formatNumber(range.lowerBound))"
                    } else {
                        baseSuffix = "pages-\(range.lowerBound)-\(range.upperBound)"
                    }
                    let indices = (range.lowerBound...range.upperBound).map { $0 - 1 }
                    return (baseSuffix, indices)
                }
                var suffixCounts: [String: Int] = [:]
                for item in initialPlans {
                    suffixCounts[item.baseSuffix, default: 0] += 1
                }
                var suffixSeen: [String: Int] = [:]
                return initialPlans.map { item in
                    let count = suffixCounts[item.baseSuffix] ?? 1
                    if count > 1 {
                        let seen = (suffixSeen[item.baseSuffix] ?? 0) + 1
                        suffixSeen[item.baseSuffix] = seen
                        return PDFSplitOutputPlan(suffix: "\(item.baseSuffix)-\(seen)", pageIndices: item.indices)
                    } else {
                        return PDFSplitOutputPlan(suffix: item.baseSuffix, pageIndices: item.indices)
                    }
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
            // Strict: an empty or fully out-of-bounds selection yields zero
            // outputs and a visible validation error.
            guard let requested = selectedPages, !requested.isEmpty else { return [] }
            // Selected-page input is strict for the same reason as textual
            // ranges: never discard an invalid page and continue with a
            // silently reduced conversion.
            guard requested.allSatisfy({ $0 >= 1 && $0 <= totalPages }) else { return [] }
            let pages = requested.sorted()
            guard !pages.isEmpty else { return [] }

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

        case "extract":
            // The chosen pages, in page order, saved as one PDF. Strict like
            // "selected": a page outside the document plans nothing.
            guard let requested = selectedPages, !requested.isEmpty,
                  requested.allSatisfy({ $0 >= 1 && $0 <= totalPages }) else { return [] }
            let indices = Array(Set(requested)).sorted().map { $0 - 1 }
            return [PDFSplitOutputPlan(suffix: "extracted", pageIndices: indices)]

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
