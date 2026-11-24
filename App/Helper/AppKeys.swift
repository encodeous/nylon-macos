import CryptoKit
import Foundation
import LocalAuthentication

// The app's two Secure Enclave keys. Their private halves never leave the chip: what's saved is a blob only this
// Mac's Secure Enclave can use. The write key always needs Touch ID or the user's password.
extension AppKeys {
    static let files: PairingFiles = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PairingFiles(current: support.appendingPathComponent("nylon/keys.json"))
    }()

    static func create() throws -> AppKeys {
        guard SecureEnclave.isAvailable else { throw Failure("This Mac has no Secure Enclave.") }
        let read = try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl([.privateKeyUsage]))
        let write = try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl([.privateKeyUsage, .userPresence]))
        return AppKeys(read: read.dataRepresentation, write: write.dataRepresentation,
                       publicKeys: PairingKeys(read: read.publicKey.x963Representation,
                                               write: write.publicKey.x963Representation))
    }

    // Signs with the write key when given an approved context (see HelperClient.approve), else the read key.
    func sign(_ data: Data, write context: LAContext?) throws -> Data {
        let key = try context.map { try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: write, authenticationContext: $0) }
            ?? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: read)
        return try key.signature(for: data).derRepresentation
    }

    private static func accessControl(_ flags: SecAccessControlCreateFlags) throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return access
    }
}
