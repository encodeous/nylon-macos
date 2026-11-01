import Foundation
import Security

// The apps the helper does what they ask, one pairing each, kept root-only.
enum Pairings {
    // nil when the file is there but can't be read: then nothing pairs and no request is accepted, until uninstalling
    // clears it.
    static func load() -> [Pairing]? {
        guard let data = try? Data(contentsOf: Paths.pairings) else {
            return FileManager.default.fileExists(atPath: Paths.pairings.path) ? nil : []
        }
        return try? decodeJSON([Pairing].self, data)
    }

    // Adds pairing, replacing any with the same read key. Refuses rather than overwrite pairings it can't read.
    static func add(_ pairing: Pairing) throws {
        guard let pairings = load() else { throw Failure("The helper can't read its pairings. Uninstall it to start over.") }
        try save(pairings.filter { $0.keys.read != pairing.keys.read } + [pairing])
    }

    static func remove(_ pairing: Pairing) throws {
        guard let pairings = load() else { throw Failure("The helper can't read its pairings.") }
        try save(pairings.filter { $0.keys.read != pairing.keys.read })
    }

    private static func save(_ pairings: [Pairing]) throws {
        try Paths.writePrivate(encodeJSON(pairings), to: Paths.pairings)
    }

    // Helper.adminRight's rule: an administrator must authenticate, every time.
    private static let rule: [String: Any] = ["class": "user", "group": "admin", "timeout": 0, "shared": false, "version": 1]

    // Puts Helper.adminRight in the authorization database. The app asks for the right, which shows the password
    // prompt; the helper then checks the app got it. The right is never removed: anyone may create a right that
    // doesn't exist, so a missing one could be recreated as "allow".
    static func registerRight() {
        var auth: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &auth) == errAuthorizationSuccess, let auth else { return }
        defer { AuthorizationFree(auth, []) }
        let status = AuthorizationRightSet(auth, Helper.adminRight, rule as CFDictionary,
                                           "nylon needs an administrator to change its helper." as CFString, nil, nil)
        if status != errAuthorizationSuccess { log("couldn't set the admin right: \(status)") }
    }

    // Whether Helper.adminRight still has its rule, so an approval of it really took an administrator.
    static func rightIsIntact() -> Bool {
        var definition: CFDictionary?
        guard AuthorizationRightGet(Helper.adminRight, &definition) == errAuthorizationSuccess,
              let definition = definition as? [String: Any] else { return false }
        return definition["class"] as? String == "user" && definition["group"] as? String == "admin"
            && definition["timeout"] as? Int == 0 && definition["shared"] as? Bool == false
    }

    // Whether externalForm is an authorization holding Helper.adminRight, i.e. an administrator just approved.
    static func authorized(_ externalForm: Data) -> Bool {
        guard externalForm.count == MemoryLayout<AuthorizationExternalForm>.size, rightIsIntact() else { return false }
        var form = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &form) { $0.copyBytes(from: externalForm) }
        var auth: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &auth) == errAuthorizationSuccess, let auth else { return false }
        defer { AuthorizationFree(auth, []) }
        return Helper.adminRight.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { item in
                var rights = AuthorizationRights(count: 1, items: item)
                // no interaction: the app already showed the prompt; this only checks it succeeded
                return AuthorizationCopyRights(auth, &rights, nil, [.extendRights], nil) == errAuthorizationSuccess
            }
        }
    }
}
