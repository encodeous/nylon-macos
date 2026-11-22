import Combine
import CryptoKit
import Foundation
import LocalAuthentication
import ServiceManagement

// The app's side of the helper: installing it, pairing with it, and sending it signed requests.
@MainActor
final class HelperClient: ObservableObject, SetupDriver {
    let objectWillChange = ObservableObjectPublisher()
    private(set) lazy var coordinator = SetupCoordinator(driver: self) { [weak self] in self?.objectWillChange.send() }
    var setup: SetupPhase { coordinator.status.phase }
    var version: String? { coordinator.status.version }
    var checked: Bool { setup != .checking }

    private let service = SMAppService.daemon(plistName: Helper.plistName)
    // `-fake YES` swaps the helper for a pretend one, to work on the UI without it
    #if DEBUG
    private let fake = UserDefaults.standard.bool(forKey: "fake") ? FakeHelper() : nil
    #else
    private let fake: FakeHelper? = nil
    #endif
    private var team: String?
    private var registration: (id: UUID, installing: Bool, initial: SMAppService.Status)?
    private var connection: NSXPCConnection?
    private var keys: AppKeys? // last verified by a signed read
    // One Touch ID approval covers the changes the user makes in the next five minutes; changes asked for together
    // wait for the same prompt.
    private var approval: (context: LAContext, until: Date)?
    private var approving: Task<LAContext, Error>?

    func refresh() async { await coordinator.refresh() }

    func inspectSetup() async throws -> SetupObservation {
        if fake != nil { return .stable(.ready) }
        let (identity, requirement) = try await Task.detached { [team] in
            let identity = try team ?? signingTeamID()
            let requirement = try SetupRequirement.unmet(teamSigned: identity != nil, enclave: SecureEnclave.isAvailable, admin: Self.accountIsAdmin())
            return (identity, requirement)
        }.value
        try Task.checkCancellation()
        team = identity
        if let requirement { return .stable(.stopped(requirement)) }
        // A compatible helper registered by another copy is usable too.
        let greeting: HelperHello
        do { greeting = try await hello() }
        catch {
            switch service.status {
            case .requiresApproval: return .stable(.waitingForLoginItem)
            case .enabled: return .unreachable(error.localizedDescription)
            case .notRegistered: return .stable(.notInstalled)
            case .notFound: throw Failure("macOS could not find the bundled helper. Open the installed copy of nylon in Applications.")
            @unknown default: throw Failure("Unknown macOS helper registration status.")
            }
        }
        guard compatible(greeting) else { return .stable(.outdated(helper: greeting.version), version: greeting.version) }
        let accepted = try acceptedKeys(greeting)
        let candidates = try AppKeys.files.candidates(accepted: accepted)
        guard !candidates.isEmpty else { return .stable(.notPaired, version: greeting.version) }
        if candidates.contains(where: { $0.file == AppKeys.files.current && $0.keys == keys }) {
            return .stable(.ready, version: greeting.version)
        }
        return .needsVerification(version: greeting.version)
    }

    nonisolated private static func accountIsAdmin() throws -> Bool {
        guard let member = administratorMembership(geteuid()) else {
            throw Failure("macOS could not look up this account's administrator membership. Try again.")
        }
        return member
    }

    private func compatible(_ greeting: HelperHello) -> Bool {
        greeting.version == appVersion && greeting.accountRepair == true
    }

    private func acceptedKeys(_ greeting: HelperHello) throws -> [Data] {
        guard compatible(greeting) else { throw Failure("Update the helper to use this version of setup.") }
        guard greeting.pairingsReadable != false else {
            throw Failure("The helper cannot read its pairing database. An administrator must restore it or uninstall the helper for all users in Settings.")
        }
        return greeting.paired
    }

    // A timeout stops waiting. macOS may still finish its request. Block another mutation until its callback or a confirmed status change establishes the outcome.
    private func changeRegistration(installing: Bool) async throws {
        try Task.checkCancellation()
        if let pending = registration {
            let state = service.status
            let applied = pending.installing ? (state == .enabled || state == .requiresApproval) : state == .notRegistered
            if applied && state != pending.initial {
                registration = nil
                if installing == pending.installing { return }
            } else {
                throw Failure("macOS is still processing the previous helper registration request. Check again after it finishes.")
            }
        }
        let id = UUID(), initial = service.status
        registration = (id, installing, initial)
        defer { if registration?.id == id { registration = nil } }
        try await Task.detached { [service] in
            if installing { try service.register() } else { try await service.unregister() }
        }.value
        try Task.checkCancellation()
    }

    func registerHelper() async throws {
        do { try await changeRegistration(installing: true) }
        catch {
            try Task.checkCancellation()
            if error is Failure { throw error }
            switch service.status {
            case .enabled, .requiresApproval: break
            default: throw error
            }
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    // Only an explicit repair/update can remove a registration. Recheck in case the helper just finished starting.
    func replaceRegistration() async throws {
        if let greeting = try? await hello(), compatible(greeting) { return }
        try Task.checkCancellation()
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        do { try await changeRegistration(installing: false) }
        catch where !(error is Failure) && service.status == .notRegistered {} // another copy may own the old registration
        try Task.checkCancellation()
        disconnect()
        try await registerHelper()
    }

    func unpair() async throws {
        try await coordinator.remove {
            _ = try await self.perform(.unpair, reason: "disconnect this app from nylon's helper")
            try Task.checkCancellation()
            self.keys = nil
        }
    }

    // Uninstalls the helper for everyone, with an administrator's approval: it stops every network and removes every
    // pairing, then the app unregisters it. The networks' config stays. A helper that doesn't answer is unregistered
    // anyway, so a broken install can always be removed.
    func uninstall() async throws {
        try await coordinator.remove { try await self.removeHelper() }
    }

    private func removeHelper() async throws {
        let admin = try await Task.detached { try AdminApproval("Nylon wants to uninstall its helper. This stops every network on this Mac.") }.value
        let authorization = admin.externalForm
        let cleanup: Error?
        let rejection: String?
        do {
            let reply = try await call { $0.uninstall(authorization: authorization, reply: $1) }
            rejection = reply
            cleanup = nil
        } catch {
            rejection = nil
            cleanup = error
        }
        withExtendedLifetime(admin) {} // the helper checks it against the live authorization
        if let rejection { throw Failure(rejection) }
        try Task.checkCancellation()
        do { try await changeRegistration(installing: false) }
        catch where !(error is Failure) && service.status == .notRegistered {}
        try Task.checkCancellation()
        disconnect()
        keys = nil
        if let cleanup {
            throw Failure("The helper is uninstalled, but it couldn't stop its networks first (\(cleanup)). Restart this Mac to stop them.")
        }
    }

    func enroll(replacing: Bool) async throws {
        guard try Self.accountIsAdmin() else { throw Failure(SetupRequirement.adminAccount.rawValue) }
        let files = AppKeys.files
        let lock = try files.lock()
        defer { withExtendedLifetime(lock) {} }
        let accepted = try await acceptedKeys(hello())
        try Task.checkCancellation()
        if !replacing, try !files.candidates(accepted: accepted).isEmpty { return }

        let create: () async throws -> AppKeys = {
            try await SetupDeadline<AppKeys>().run(for: .seconds(30)) {
                try await Task.detached { try AppKeys.create() }.value
            }
        }
        let candidate: AppKeys
        if !replacing, let pending = try files.preparedKeys() { candidate = pending }
        else {
            candidate = try await create()
            try Task.checkCancellation()
            if !replacing { try files.stage(encodeJSON(candidate)) }
        }

        // Finish disk I/O before the short-lived administrator right is granted. An unapproved
        // replacement has no matching remote key, so a cancelled prompt leaves the old pairing usable.
        if replacing { try files.stageReplacement(candidate, accepted: accepted) }
        let keysData = replacing ? try encodeJSON(AccountRepair(keys: candidate.publicKeys, expected: accepted)) : try encodeJSON(candidate.publicKeys)
        let prompt = replacing ? "Nylon wants to replace the helper pairing for this macOS account." : "Nylon wants to connect to its helper."
        let admin = try await SetupDeadline<AdminApproval>().run(for: .seconds(120)) {
            try await Task.detached { try AdminApproval(prompt) }.value
        }
        defer { withExtendedLifetime(admin) {} }
        try Task.checkCancellation()
        let challenge = try await challenge()
        let proof = try await SetupDeadline<Data>().run(for: .seconds(30)) {
            try await self.sign(pairingMessage(challenge: challenge, keys: keysData), with: candidate, context: nil)
        }
        let authorization = admin.externalForm
        let rejection: String?
        do {
            rejection = try await call { $0.pair(keys: keysData, challenge: challenge, proof: proof, authorization: authorization, reply: $1) }
        } catch {
            // A lost reply can follow a successful replacement. Check for this exact key.
            if let greeting = try? await hello(), (try? acceptedKeys(greeting))?.contains(candidate.publicKeys.read) == true { return }
            throw error
        }
        if let rejection { throw Failure(rejection) }
    }

    // Re-read both sides under the same lock used by every app copy that enrolls. A lost RPC reply or an
    // interrupted commit resumes here on the next observation, without displaying another password prompt.
    func verifyAndCommit() async throws {
        let lock = try AppKeys.files.lock()
        defer { withExtendedLifetime(lock) {} }
        let accepted = try await acceptedKeys(hello())
        let verified = try await AppKeys.files.verified(accepted: accepted) { candidate in
            try await SetupDeadline<Void>().run(for: .seconds(35)) {
                let state = try await self.perform(.state, with: candidate, reason: "")
                _ = try decodeJSON(HelperState.self, state)
            }
        }
        keys = verified
    }

    // Asks the helper to do action, signed with the key it needs. reason finishes the Touch ID prompt's "nylon wants
    // to …" for actions that need approval.
    func perform(_ action: HelperAction, reason: String = "") async throws -> Data {
        if let fake { return try fake.perform(action) }
        guard let keys else { throw Failure("Connect to the helper first.") }
        return try await perform(action, with: keys, reason: reason)
    }

    private func perform(_ action: HelperAction, with keys: AppKeys, reason: String) async throws -> Data {
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

    // short: it's how the app finds out whether the helper is there at all, every few seconds
    private func hello() async throws -> HelperHello {
        try await decodeJSON(HelperHello.self, call(timeout: 3) { $0.hello(reply: $1) })
    }

    // Calls the helper, failing if the connection breaks or it doesn't answer in time. Without a limit, a helper launchd
    // can't start (signed unlike the copy that registered it, say) leaves the call, and whatever waits on it, hanging.
    private func call<T>(timeout: TimeInterval = 30, _ body: @escaping (HelperXPC, @escaping (T) -> Void) -> Void) async throws -> T {
        try Task.checkCancellation()
        let connection = try connect()
        return try await withCheckedThrowingContinuation { continuation in
            let reply = Reply(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler {
                reply.finish(.failure(Failure("Lost the connection to the helper: \($0.localizedDescription)")))
            }
            guard let helper = proxy as? HelperXPC else {
                return reply.finish(.failure(Failure("The helper doesn't speak this app's protocol.")))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                reply.finish(.failure(Failure("The helper didn't answer.")))
            }
            body(helper) { reply.finish(.success($0)) }
        }
    }

    private func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    // The helper must be signed by the same team, or the app won't talk to it.
    private func connect() throws -> NSXPCConnection {
        guard let team else { throw Failure("Could not establish the app’s signing team.") }
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: Helper.machService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperXPC.self)
        connection.setCodeSigningRequirement(signingRequirement(identifier: Helper.helperIdentifier, team: team))
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

// The one answer to a call: the helper's reply, a broken connection or the timeout, whichever comes first
private final class Reply<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
