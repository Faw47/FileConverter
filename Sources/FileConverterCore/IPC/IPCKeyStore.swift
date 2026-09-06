import FileConverterContracts
import Foundation

enum IPCKeyStore {
    static func ensureKey(configuration: IPCConfiguration) throws -> Data {
        try IPCAuthenticationKeyStore.ensureKey(configuration: configuration)
    }

    static func loadKey(configuration: IPCConfiguration) throws -> Data? {
        try IPCAuthenticationKeyStore.loadKey(configuration: configuration)
    }
}
