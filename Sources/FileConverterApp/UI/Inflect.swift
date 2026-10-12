import Foundation

/// Localizable text with automatic plural agreement, e.g.
/// `Inflect.string("^[\(count) file](inflect: true)")` → "1 file" / "3 files".
enum Inflect {
    static func string(_ resource: String.LocalizationValue) -> String {
        String(AttributedString(localized: resource).characters)
    }
}
