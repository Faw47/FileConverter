import FileConverterCore
import Foundation

/// Text field format for times in a video or audio file: "1:30", "90",
/// "1:02:03.5". An empty field means no time.
struct MediaTimeFormat: ParseableFormatStyle {
    var parseStrategy: Strategy { Strategy() }

    func format(_ value: Double) -> String {
        MediaTrim.formatTime(value)
    }

    struct Strategy: ParseStrategy {
        struct InvalidTime: Error {}

        func parse(_ value: String) throws -> Double {
            guard let seconds = MediaTrim.parseTime(value) else { throw InvalidTime() }
            return seconds
        }
    }
}
