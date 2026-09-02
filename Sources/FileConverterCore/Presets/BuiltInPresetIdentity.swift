import CryptoKit
import Foundation

enum BuiltInPresetIdentity {
    private static let namespace = "io.fileconverter.builtin-preset.v1:"

    static func id(for key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data((namespace + key).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
