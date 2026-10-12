import Foundation

public enum AudioDurationParser {
    /// Formats seconds into `HH:MM:SS.ss` (e.g., 300 -> "00:05:00.00").
    public static func format(seconds: Double) -> String {
        guard !seconds.isNaN, !seconds.isInfinite, seconds >= 0 else {
            return "00:00:00.00"
        }
        let totalCents = Int((seconds * 100).rounded())
        let totalSeconds = totalCents / 100
        let centiseconds = totalCents % 100
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d:%02d.%02d", hours, minutes, secs, centiseconds)
    }

    public static func format(seconds: Int) -> String {
        format(seconds: Double(seconds))
    }

    /// Parses a duration string (e.g. `HH:MM:SS.ss` or `HH:MM:SS`) into seconds.
    /// Returns `nil` if the string is malformed or represents a negative duration.
    public static func parse(_ string: String) -> Double? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("-") else { return nil }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        let hours: Double
        let minutes: Double
        let secondsString: String

        if parts.count == 3 {
            guard let h = Double(parts[0]), h >= 0, parts[0].allSatisfy({ $0.isNumber }) else { return nil }
            guard let m = Double(parts[1]), m >= 0, m < 60, parts[1].allSatisfy({ $0.isNumber }) else { return nil }
            hours = h
            minutes = m
            secondsString = String(parts[2])
        } else {
            hours = 0
            guard let m = Double(parts[0]), m >= 0, parts[0].allSatisfy({ $0.isNumber }) else { return nil }
            minutes = m
            secondsString = String(parts[1])
        }

        // Validate seconds (and optional fractional part)
        let secParts = secondsString.split(separator: ".", omittingEmptySubsequences: false)
        guard secParts.count == 1 || secParts.count == 2 else { return nil }
        guard let s = Double(secondsString), s >= 0, s < 60 else { return nil }

        let total = (hours * 3600.0) + (minutes * 60.0) + s
        guard total >= 0, !total.isNaN, !total.isInfinite else { return nil }
        return total
    }

    /// Parses a duration string into integer seconds (rounded).
    public static func parseSecondsInt(_ string: String) -> Int? {
        guard let seconds = parse(string) else { return nil }
        return Int(seconds.rounded())
    }

    /// Validates a duration string and returns a user-facing error message if invalid.
    public static func validateDurationString(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Enter a duration in HH:MM:SS.ss format."
        }
        if trimmed.contains("-") {
            return "Duration cannot be negative."
        }
        guard let seconds = parse(trimmed) else {
            return "Invalid duration format. Use HH:MM:SS.ss (e.g. 00:05:00.00)."
        }
        if seconds < 1 {
            return "Audio split length must be at least 1 second."
        }
        return nil
    }
}
