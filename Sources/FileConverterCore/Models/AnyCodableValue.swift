import Foundation

/// A type-erased Codable wrapper used to preserve arbitrary JSON values from newer schemas.
public struct AnyCodableValue: Codable, Hashable, Sendable {
    public let value: Sendable

    public init(_ value: Sendable) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodableValue].self) {
            self.value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodableValue].self) {
            self.value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported AnyCodableValue")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Sendable]:
            let codableArray = array.map { AnyCodableValue($0) }
            try container.encode(codableArray)
        case let dict as [String: Sendable]:
            let codableDict = dict.mapValues { AnyCodableValue($0) }
            try container.encode(codableDict)
        default:
            try container.encode(String(describing: value))
        }
    }

    public static func == (lhs: AnyCodableValue, rhs: AnyCodableValue) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(String(describing: value))
    }

    public static func from(jsonValue: Any) -> AnyCodableValue? {
        if jsonValue is NSNull {
            return AnyCodableValue(NSNull())
        } else if let b = jsonValue as? Bool {
            return AnyCodableValue(b)
        } else if let i = jsonValue as? Int {
            return AnyCodableValue(i)
        } else if let d = jsonValue as? Double {
            return AnyCodableValue(d)
        } else if let s = jsonValue as? String {
            return AnyCodableValue(s)
        } else if let arr = jsonValue as? [Any] {
            let converted = arr.compactMap { from(jsonValue: $0) }
            return AnyCodableValue(converted.map(\.value))
        } else if let dict = jsonValue as? [String: Any] {
            var convertedDict: [String: Sendable] = [:]
            for (k, v) in dict {
                if let converted = from(jsonValue: v) {
                    convertedDict[k] = converted.value
                }
            }
            return AnyCodableValue(convertedDict)
        } else {
            return AnyCodableValue(String(describing: jsonValue))
        }
    }
}
