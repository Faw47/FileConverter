import Foundation

/// Represents inert, unvalidated fields from newer preset schemas or imported documents.
/// Preserved byte-for-byte across import and export to maintain forward compatibility,
/// but never passed to conversion backends or command-line builders.
public struct PresetOpaqueFields: Codable, Hashable, Sendable {
    public var fields: [String: AnyCodableValue]

    public init(fields: [String: AnyCodableValue] = [:]) {
        self.fields = fields
    }

    public subscript(key: String) -> AnyCodableValue? {
        get { fields[key] }
        set { fields[key] = newValue }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.fields = try container.decode([String: AnyCodableValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }
}
