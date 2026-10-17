import Foundation

/// The part of a video or audio file a preset keeps, and the settings that go
/// with it (frame time for still images, loudness normalization).
public enum MediaTrim {
    /// EBU R128 target used for "Even out loudness".
    public static let loudnessTargetLUFS = -16.0
    public static let loudnessTruePeakDB = -1.5
    public static let loudnessRangeLU = 11.0

    /// FFmpeg filter for loudness normalization.
    public static var loudnormFilter: String {
        "loudnorm=I=\(format(loudnessTargetLUFS)):TP=\(format(loudnessTruePeakDB)):LRA=\(format(loudnessRangeLU))"
    }

    /// Seconds kept from a file that is `totalSeconds` long. Returns
    /// `totalSeconds` when the preset doesn't trim, and 0 when the trim
    /// starts after the end of the file.
    public static func keptDuration(totalSeconds: Double, preset: ConversionPreset) -> Double {
        guard preset.isTrimmed, totalSeconds > 0 else { return totalSeconds }
        let start = min(max(0, preset.trimStartSeconds ?? 0), totalSeconds)
        let end = min(preset.trimEndSeconds ?? totalSeconds, totalSeconds)
        return max(0, end - start)
    }

    /// The moment a frame preset saves, kept inside the video.
    public static func frameTime(for preset: ConversionPreset, durationSeconds: Double) -> Double {
        let requested = max(0, preset.frameTimeSeconds ?? 0)
        guard durationSeconds > 0 else { return requested }
        return min(requested, durationSeconds)
    }

    /// Problems with the trim and frame settings, in plain words.
    public static func validationErrors(for preset: ConversionPreset) -> [String] {
        var errors: [String] = []
        let start = preset.trimStartSeconds
        let end = preset.trimEndSeconds
        if let start, !start.isFinite || start < 0 {
            errors.append("The start time can't be negative.")
        }
        if let end, !end.isFinite || end <= 0 {
            errors.append("The end time must be after the start of the file.")
        }
        if let start, let end, start.isFinite, end.isFinite, end <= start {
            errors.append("The end time must be after the start time.")
        }
        if let time = preset.frameTimeSeconds, !time.isFinite || time < 0 {
            errors.append("The frame time can't be negative.")
        }
        if preset.isTrimmed && preset.isVideoFrameExport {
            errors.append("A preset that saves a frame can't also trim. Choose the frame time instead.")
        }
        if preset.isTrimmed && preset.audioSplitDurationSeconds != nil {
            errors.append("Choose either trimming or splitting into parts, not both.")
        }
        return errors
    }

    /// Seconds as "1:05.5" or "1:02:03" for labels and fields.
    public static func formatTime(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let whole = Int(clamped)
        let fraction = clamped - Double(whole)
        let hours = whole / 3_600
        let minutes = (whole % 3_600) / 60
        let secs = whole % 60
        var text = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
        let tenths = Int((fraction * 100).rounded())
        if tenths >= 100 {
            return formatTime(Double(whole + 1))
        }
        if tenths > 0 {
            text += tenths % 10 == 0 ? String(format: ".%d", tenths / 10) : String(format: ".%02d", tenths)
        }
        return text
    }

    /// Reads "90", "1:30", "1:30.5", or "1:02:03". Returns nil for anything
    /// else, including negative numbers.
    public static func parseTime(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isNumber || (isLast && $0 == ".") }),
                  let value = Double(part), value >= 0 else { return nil }
            if index > 0, value >= 60 { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Seconds for command-line tools, without exponent notation.
    public static func argument(_ seconds: Double) -> String {
        String(format: "%.3f", max(0, seconds))
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
