import Foundation
import LocalAuthentication
import ServiceManagement

// The app's side of the helper: installing it, pairing with it, and sending it signed requests.
@MainActor
final class HelperClient: ObservableObject {
    enum Setup: Equatable {
        case unsigned // signed ad hoc, so the helper wouldn't let the app in
        case notInstalled
        case waitingForLoginItem // registered; waiting for the user in System Settings > Login Items
        case notPaired // installed, but this app isn't paired; pairing needs an administrator
        case outdated(helper: String) // left over from another version of the app; update it
        case ready
        case failed(String)
    }

    @Published private(set) var setup = Setup.notInstalled
    @Published private(set) var version: String?

    private let service = SMAppService.daemon(plistName: Helper.plistName)
    // `-fake YES` swaps the helper for a pretend one, to work on the UI without it
    private let fake = UserDefaults.standard.bool(forKey: "fake") ? FakeHelper() : nil
    private let team = ownTeamID()
    private var connection: NSXPCConnection?
    private var keys = AppKeys.load()
    // One Touch ID approval covers the changes the user makes in the next five minutes; changes asked for together
    // wait for the same prompt.
    private var approval: (context: LAContext, until: Date)?
    private var approving: Task<LAContext, Error>?

    // Works out where setup is. The helper may have been registered by another copy of the app (e.g. the one in
    // /Applications, while this is a build from Xcode), so ask it first; this copy's own registration comes second.
    func refresh() async {
        if fake != nil { return setup = .ready }
        guard team != nil else { return setup = .unsigned }
        guard let hello = try? await hello() else {
            switch service.status {
            case .requiresApproval: setup = .waitingForLoginItem
            case .enabled: setup = .failed("The helper is installed but isn't answering. See /Library/Logs/nylon/helper.log.")
            default: setup = .notInstalled
            }
            return
        }
        version = hello.version
        if hello.version != appVersion {
            setup = .outdated(helper: hello.version)
        } else if let keys, hello.paired.contains(keys.publicKeys.read) {
            setup = .ready
        } else {
            setup = .notPaired
        }
    }

    // Registers the launch daemon. macOS then asks the user to allow it in System Settings, which this opens.
    func install() async {
        if fake != nil { return }
        do {
            try service.register()
        } catch where service.status != .requiresApproval { // registered already, waiting to be allowed, is fine
            return setup = .failed(error.localizedDescription)
        } catch {}
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        await refresh()
    }

    // Re-registers the helper, so launchd runs this app's copy instead of one left over from another version.
    func update() async throws {
        try? await service.unregister() // registered by another copy of the app, or already gone, is fine
        disconnect()
        await install()
    }

    // Removes this app's pairing. The helper keeps running other users' networks.
    func unpair() async throws {
        _ = try await perform(.unpair, reason: "unpair this app from nylon's helper")
        await refresh()
    }

    // Uninstalls the helper for everyone, with an administrator's approval: it stops every network and removes every
    // pairing, then the app unregisters it. The networks' config stays. A helper that doesn't answer is unregistered
    // anyway, so a broken install can always be removed.
    func uninstall() async throws {
        let admin = try await Task.detached { try AdminApproval("nylon wants to remove its helper and stop every network on this Mac.") }.value
        let authorization = admin.externalForm
        let cleanup: Error?
        do {
            let reply = try await call { $0.uninstall(authorization: authorization, reply: $1) }
            cleanup = reply.map(Failure.init)
        } catch {
            cleanup = error
        }
        withExtendedLifetime(admin) {} // the helper checks it against the live authorization
        try? await service.unregister() // not registered by this copy, or already gone, is fine
        disconnect()
        await refresh()
        if let cleanup {
            throw Failure("The helper is unregistered, but couldn't clean up (\(cleanup)). See docs/ARCHITECTURE.md to remove what's left by hand.")
        }
    }

    // Makes new keys and gives the helper their public halves, with an administrator's approval: one prompt, the
    // same for every user, the first one too. The read key signs the proof, so there's no Touch ID prompt as well.
    func pair() async throws {
        let admin = try await Task.detached { try AdminApproval("nylon wants to let this app control its networks.") }.value
        let keys = try AppKeys.create()
        try keys.save(pending: true) // saved before the helper pairs them, so they can't be lost after
        let keysData = try encodeJSON(keys.publicKeys)
        let challenge = try await challenge()
        let proof = try await sign(pairingMessage(challenge: challenge, keys: keysData), with: keys, context: nil)
        let authorization = admin.externalForm
        if let error = try await call({ $0.pair(keys: keysData, challenge: challenge, proof: proof, authorization: authorization, reply: $1) }) {
            throw Failure(error)
        }
        withExtendedLifetime(admin) {} // the helper checks it against the live authorization
        try keys.save(pending: false)
        self.keys = keys
        setup = .ready
    }

    // Asks the helper to do action, signed with the key it needs. reason finishes the Touch ID prompt's "nylon wants
    // to …" for actions that need approval.
    func perform(_ action: HelperAction, reason: String = "") async throws -> Data {
        if let fake { return try fake.perform(action) }
        guard let keys else { throw Failure("Pair the app with the helper first.") }
        // Approve first: a challenge is only good for a minute, and the user may take longer than that.
        let context = action.needsWriteKey ? try await approve(reason) : nil
        let request = try await encodeJSON(SignedRequest(challenge: challenge(), pairing: keys.publicKeys.read, action: action))
        let signature = try await sign(request, with: keys, context: context)
        let (data, error): (Data?, String?) = try await call { proxy, reply in
            proxy.perform(request: request, signature: signature) { reply(($0, $1)) }
        }
        if let error { throw Failure(error) }
        return data ?? Data()
    }

    // Touch ID or the user's password, for the write key. One approval covers the next five minutes, so a few changes
    // in a row ask once.
    private func approve(_ reason: String) async throws -> LAContext {
        if let approval, approval.until > Date() { return approval.context }
        if let approving { return try await approving.value }
        let task = Task {
            let context = LAContext()
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return context
        }
        approving = task
        defer { approving = nil }
        let context = try await task.value
        approval = (context, Date().addingTimeInterval(5 * 60))
        return context
    }

    // Signs with the write key, under an approved context, or else the read key.
    private func sign(_ data: Data, with keys: AppKeys, context: LAContext?) async throws -> Data {
        try await Task.detached { try keys.sign(data, write: context) }.value
    }

    private func challenge() async throws -> Data {
        try await call { $0.challenge(reply: $1) }
    }

    private func hello() async throws -> HelperHello {
        try await decodeJSON(HelperHello.self, call { $0.hello(reply: $1) })
    }

    // Calls the helper on a background thread, failing if the connection breaks before it replies.
    private func call<T>(_ body: @escaping (HelperXPC, @escaping (T) -> Void) -> Void) async throws -> T {
        let connection = connect()
        return try await Task.detached {
            var result: Result<T, Error> = .failure(Failure("The helper didn't reply."))
            let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler {
                result = .failure(Failure("Lost the connection to the helper: \($0.localizedDescription)"))
            }
            guard let helper = proxy as? HelperXPC else { throw Failure("The helper doesn't speak this app's protocol.") }
            body(helper) { result = .success($0) }
            return try result.get()
        }.value
    }

    private func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    // The helper must be signed by the same team, or the app won't talk to it.
    private func connect() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: Helper.machService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperXPC.self)
        if let team { connection.setCodeSigningRequirement(signingRequirement(identifier: Helper.helperIdentifier, team: team)) }
        connection.invalidationHandler = { [weak self, weak connection] in
            Task { @MainActor in if self?.connection === connection { self?.connection = nil } }
        }
        connection.resume()
        self.connection = connection
        return connection
    }
}

private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

// An administrator's approval of Helper.adminRight, from the password prompt this shows, saying prompt. The helper
// checks the externalized form, which only works while this is alive. The prompt blocks, so make it off the main thread.
private final class AdminApproval: @unchecked Sendable {
    let externalForm: Data
    private let ref: AuthorizationRef

    init(_ prompt: String) throws {
        var auth: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &auth) == errAuthorizationSuccess, let auth else {
            throw Failure("Couldn't ask for an administrator.")
        }
        let status = Helper.adminRight.withCString { name in
            kAuthorizationEnvironmentPrompt.withCString { promptKey in
                prompt.withCString { promptText in
                    var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                    var promptItem = AuthorizationItem(name: promptKey, valueLength: strlen(promptText),
                                                       value: UnsafeMutableRawPointer(mutating: promptText), flags: 0)
                    return withUnsafeMutablePointer(to: &item) { item in
                        withUnsafeMutablePointer(to: &promptItem) { promptItem in
                            var rights = AuthorizationRights(count: 1, items: item)
                            var environment = AuthorizationEnvironment(count: 1, items: promptItem)
                            return AuthorizationCopyRights(auth, &rights, &environment, [.interactionAllowed, .extendRights, .preAuthorize], nil)
                        }
                    }
                }
            }
        }
        var form = AuthorizationExternalForm()
        guard status == errAuthorizationSuccess, AuthorizationMakeExternalForm(auth, &form) == errAuthorizationSuccess else {
            AuthorizationFree(auth, [])
            throw Failure(status == errAuthorizationCanceled ? "Cancelled." : "An administrator has to approve this.")
        }
        ref = auth
        externalForm = withUnsafeBytes(of: &form) { Data($0) }
    }

    deinit { AuthorizationFree(ref, []) }
}
