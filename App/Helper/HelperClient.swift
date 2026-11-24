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
    private var changingRegistration = false
    private var requestingAdminApproval = false
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
        let reply: Data
        do { reply = try await helloReply() }
        catch {
            try Task.checkCancellation()
            return try Self.observeRegistration(service.status, xpcError: error, mutationInFlight: changingRegistration) {
                try Self.validateHelperBundle(at: Bundle.main.bundleURL)
            }
        }
        try Task.checkCancellation()
        // Receiving an undecodable reply still proves an endpoint answered. Keep its protocol error.
        let greeting = try decodeJSON(HelperHello.self, reply)
        guard compatible(greeting) else { return .stable(.outdated(helper: greeting.version), version: greeting.version) }
        let accepted = try acceptedKeys(greeting)
        if accepted.isEmpty, try !AppKeys.files.hasSavedKeys() { return .freshPairingNeeded(version: greeting.version) }
        let candidates = try AppKeys.files.candidates(accepted: accepted)
        guard !candidates.isEmpty else { return .stable(.notPaired, version: greeting.version) }
        if candidates.contains(where: { $0.file == AppKeys.files.current && $0.keys == keys }) {
            return .stable(.ready, version: greeting.version)
        }
        return .needsVerification(version: greeting.version)
    }

    // The local registration describes this copy only. A failed lookup does not tell us whether the
    // bundled files are missing, and we only get here if a signed hello could not establish a connection.
    nonisolated static func observeRegistration(
        _ status: SMAppService.Status, xpcError: Error, mutationInFlight: Bool = false, validateBundle: () throws -> Void
    ) throws -> SetupObservation {
        switch status {
        case .requiresApproval:
            // The service is registered. launchd normally won't load it until macOS grants approval.
            return .stable(.waitingForLoginItem)
        case .enabled: return .unreachable(xpcError.localizedDescription)
        case .notRegistered, .notFound:
            if mutationInFlight { return .stable(.registrationPending) }
            // A valid bundle can offer registration when macOS has no usable record for this copy.
            try validateBundle()
            return .stable(.notInstalled)
        @unknown default:
            throw Failure("Unknown macOS helper registration status (\(status.rawValue)).")
        }
    }

    nonisolated static func validateHelperBundle(at bundleURL: URL) throws {
        let plistURL = bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(Helper.plistName)")
        let contents: Data
        do { contents = try Data(contentsOf: plistURL) }
        catch { throw Failure("Can't read the bundled helper configuration at \(plistURL.path): \(error.localizedDescription)") }
        let program = "Contents/MacOS/nylon-helper"
        guard let plist = try? PropertyListSerialization.propertyList(from: contents, format: nil) as? [String: Any],
              plist["Label"] as? String == Helper.machService,
              plist["BundleProgram"] as? String == program,
              (plist["MachServices"] as? [String: Bool])?[Helper.machService] == true else {
            throw Failure("The bundled helper configuration at \(plistURL.path) is invalid.")
        }
        let executable = bundleURL.appendingPathComponent(program)
        let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw Failure("The bundled helper at \(executable.path) is missing or isn't executable.")
        }
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

    // A status change can advance setup, but only the OS call returning releases the mutation.
    private func changeRegistration(installing: Bool) async throws {
        try Task.checkCancellation()
        try requireNoRegistrationMutation()
        changingRegistration = true
        defer { changingRegistration = false }
        try await Task.detached { [service] in
            if installing { try service.register() } else { try await service.unregister() }
        }.value
        try Task.checkCancellation()
    }

    private func requireNoRegistrationMutation() throws {
        guard !changingRegistration else {
            throw Failure("macOS is still processing the previous helper registration request. Check again after it finishes.")
        }
    }

    func registerHelper() async throws {
        switch service.status {
        case .enabled:
            break
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
        case .notRegistered, .notFound:
            try Self.validateHelperBundle(at: Bundle.main.bundleURL)
            try await submitRegistration()
        @unknown default:
            throw Failure("Unknown macOS helper registration status (\(service.status.rawValue)).")
        }
    }

    private func submitRegistration() async throws {
        do { try await changeRegistration(installing: true) }
        catch {
            try Task.checkCancellation()
            if error is Failure { throw error }
            let status = service.status
            guard status == .enabled || status == .requiresApproval else { throw error }
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    // The coordinator has just checked XPC. Recheck the status at the point of mutation.
    func repairRegistration(_ reason: RegistrationRepairReason) async throws {
        let expected: SMAppService.Status = reason == .approval ? .requiresApproval : .enabled
        guard service.status == expected else { return }
        try Self.validateHelperBundle(at: Bundle.main.bundleURL)
        guard service.status == expected else { return }

        if reason == .startup {
            // A previous bootstrap may have failed before approval caught up. Try submitting the same job first.
            do {
                try await changeRegistration(installing: true)
                return
            } catch where Self.matchesServiceError(error, code: Int(kSMErrorAlreadyRegistered)) {}
            if (try? await helloReply()) != nil { return }
            try Task.checkCancellation()
            guard service.status == expected else { return }
        }

        try await unregisterForReplacement()
        keys = nil // Verify the saved pairing again after connecting to the restarted helper.
        // The approval status can lag the completed unregistration.
        try await submitRegistration()
    }

    // An explicit update replaces a known incompatible helper. Approval can change during the recheck.
    func replaceRegistration() async throws {
        if let greeting = try? await hello(), compatible(greeting) { return }
        try Task.checkCancellation()
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        // Validate the replacement before taking a working or recoverable registration down.
        try Self.validateHelperBundle(at: Bundle.main.bundleURL)
        try await unregisterForReplacement()
        // The unregister call can finish before the status lookup catches up.
        try await submitRegistration()
    }

    private func unregisterForReplacement() async throws {
        do { try await changeRegistration(installing: false) }
        catch where Self.canRegisterAfterUnregisterFailure(error, status: service.status) {}
        try Task.checkCancellation()
        disconnect()
    }

    nonisolated static func canRegisterAfterUnregisterFailure(_ error: Error, status: SMAppService.Status) -> Bool {
        guard !(error is Failure), !(error is CancellationError) else { return false }
        return status == .notRegistered || matchesServiceError(error, code: Int(kSMErrorJobNotFound))
    }

    nonisolated private static func matchesServiceError(_ error: Error, code: Int) -> Bool {
        // Older systems return the same NSError domain without exporting its constant.
        let domain = if #available(macOS 15, *) { SMAppServiceErrorDomain } else { "SMAppServiceErrorDomain" }
        let failure = error as NSError
        return failure.domain == domain && failure.code == code
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
        try requireNoRegistrationMutation()
        let admin = try await administratorApproval("Nylon wants to uninstall its helper. This stops every network on this Mac.")
        let authorization = admin.externalForm
        let cleanup: Result<String?, Error>
        do { cleanup = .success(try await call { $0.uninstall(authorization: authorization, reply: $1) }) }
        catch { cleanup = .failure(error) }
        withExtendedLifetime(admin) {} // the helper checks it against the live authorization
        if case .success(let rejection?) = cleanup { throw Failure(rejection) }
        try Task.checkCancellation()
        do { try await changeRegistration(installing: false) }
        catch where !(error is Failure) && service.status == .notRegistered {}
        try Task.checkCancellation()
        disconnect()
        keys = nil
        if case .failure(let error) = cleanup {
            throw Failure("The helper is uninstalled, but it couldn't stop its networks first (\(error)). Restart this Mac to stop them.")
        }
    }

    func enroll(replacing: Bool) async throws {
        try await enroll(replacing: replacing, onlyIfFresh: false)
    }

    func enrollFresh() async throws {
        try await enroll(replacing: false, onlyIfFresh: true)
    }

    private func enroll(replacing: Bool, onlyIfFresh: Bool) async throws {
        guard try Self.accountIsAdmin() else { throw Failure(SetupRequirement.adminAccount.rawValue) }
        let files = AppKeys.files
        let lock = try files.lock()
        defer { withExtendedLifetime(lock) {} }
        let accepted = try await acceptedKeys(hello())
        try Task.checkCancellation()
        if onlyIfFresh {
            guard accepted.isEmpty, try !files.hasSavedKeys() else { return }
        }
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
        let admin = try await administratorApproval(prompt)
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

    private func administratorApproval(_ prompt: String) async throws -> AdminApproval {
        try Task.checkCancellation()
        guard !requestingAdminApproval else {
            throw Failure("Finish the open macOS administrator prompt before trying again.")
        }
        requestingAdminApproval = true
        defer { requestingAdminApproval = false }
        let approval = try await Task.detached { try AdminApproval(prompt) }.value
        try Task.checkCancellation()
        return approval
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
        try await decodeJSON(HelperHello.self, helloReply())
    }

    private func helloReply() async throws -> Data {
        try await call(timeout: 3) { $0.hello(reply: $1) }
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
