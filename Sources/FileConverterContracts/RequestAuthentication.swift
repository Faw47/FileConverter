import CryptoKit
import Foundation

public struct AuthenticatedConversionRequest: Codable, Sendable {
    public let request: ConversionRequest
    public let authenticationTag: Data

    public init(request: ConversionRequest, authenticationTag: Data) {
        self.request = request
        self.authenticationTag = authenticationTag
    }
}

public enum ConversionRequestAuthenticator {
    public static func authenticate(
        _ request: ConversionRequest,
        keyData: Data
    ) throws -> AuthenticatedConversionRequest {
        let key = try symmetricKey(from: keyData)
        let code = HMAC<SHA256>.authenticationCode(for: try encodedRequest(request), using: key)
        return AuthenticatedConversionRequest(request: request, authenticationTag: Data(code))
    }

    public static func verify(
        _ envelope: AuthenticatedConversionRequest,
        keyData: Data
    ) throws -> Bool {
        let key = try symmetricKey(from: keyData)
        return HMAC<SHA256>.isValidAuthenticationCode(
            envelope.authenticationTag,
            authenticating: try encodedRequest(envelope.request),
            using: key
        )
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func encodedRequest(_ request: ConversionRequest) throws -> Data {
        try encoder().encode(request)
    }

    private static func symmetricKey(from data: Data) throws -> SymmetricKey {
        guard data.count >= 32 else {
            throw ConversionRequestAuthenticationError.invalidKey
        }
        return SymmetricKey(data: data)
    }
}

public enum ConversionRequestAuthenticationError: LocalizedError, Sendable {
    case invalidKey

    public var errorDescription: String? {
        "The conversion request authentication key is invalid."
    }
}
