import CryptoKit
import Foundation
import LocalAuthentication

// The app's two Secure Enclave keys. Their private halves never leave the chip: what's saved is a blob only this
// Mac's Secure Enclave can use. The write key always needs Touch ID or the user's password.
struct AppKeys {
    private struct Saved: Codable {
        var read: Data // dataRepresentation blobs
        var write: Data
        var publicKeys: PairingKeys
    }

    private let saved: Saved

    var publicKeys: PairingKeys { saved.publicKeys }

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nylon/keys.json")
    }

    static func load() -> AppKeys? {
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        return AppKeys(saved: saved)
    }

    // New keys, saved only by save.
    static func create() throws -> AppKeys {
        guard SecureEnclave.isAvailable else { throw Failure("This Mac has no Secure Enclave.") }
        let read = try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl([.privateKeyUsage]))
        let write = try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl([.privateKeyUsage, .userPresence]))
        return AppKeys(saved: Saved(read: read.dataRepresentation, write: write.dataRepresentation,
                                    publicKeys: PairingKeys(read: read.publicKey.x963Representation,
                                                            write: write.publicKey.x963Representation)))
    }

    // Saves the keys beside the current ones (pending), before pairing them; then in their place, once the helper
    // has them. The current keys stay usable until then.
    func save(pending: Bool) throws {
        let fm = FileManager.default
        let pendingURL = Self.url.appendingPathExtension("pending")
        if pending {
            try fm.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: pendingURL, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingURL.path)
        } else {
            guard rename(pendingURL.path, Self.url.path) == 0 else { throw Failure("Couldn't save the keys: \(String(cString: strerror(errno)))") }
        }
    }

    // Signs with the write key when given an approved context (see HelperClient.approve), else the read key.
    func sign(_ data: Data, write context: LAContext?) throws -> Data {
        let key = try context.map { try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: saved.write, authenticationContext: $0) }
            ?? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: saved.read)
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
