import Foundation
import Testing
@testable import NylonApp

@MainActor private final class SetupFixture: SetupDriver {
    var observation: SetupObservation = .stable(.notInstalled)
    var inspect: (() async throws -> SetupObservation)?
    var register: () throws -> Void = {}
    var enrollment: () async throws -> Void = {}
    var verify: () throws -> Void = {}
    var enrollments = 0
    var verifications = 0
    var replacements = 0
    var repairs = 0
    var replacement: () async throws -> Void = {}

    func inspectSetup() async throws -> SetupObservation {
        if let inspect { return try await inspect() }
        return observation
    }
    func registerHelper() throws { try register() }
    func repairRegistration(_ reason: RegistrationRepairReason) { Issue.record("Unexpected registration repair") }
    func replaceRegistration() async throws { replacements += 1; try await replacement() }
    func enroll(replacing: Bool) async throws {
        if replacing { repairs += 1 }
        enrollments += 1
        try await enrollment()
    }
    func verifyAndCommit() async throws {
        verifications += 1
        try verify()
    }
}

@Test @MainActor func latePollDoesNotEraseRegistrationFailure() async {
    let effects = SetupFixture()
    let setup = SetupCoordinator(driver: effects)
    await setup.refresh()
    var delayed: CheckedContinuation<SetupObservation, Never>?
    effects.inspect = { await withCheckedContinuation { delayed = $0 } }
    let oldPoll = Task { await setup.refresh() }
    while delayed == nil { await Task.yield() }
    effects.inspect = nil
    effects.register = { throw Failure("Registration failed") }
    await setup.install()
    delayed?.resume(returning: .stable(.ready))
    await oldPoll.value
    await setup.refresh()
    #expect(setup.status.phase == .notInstalled)
    #expect(setup.status.message == "Registration failed")
}

@Test @MainActor func timedOutInstallInspectionCannotRegisterOrArmPairing() async throws {
    let effects = SetupFixture()
    let setup = SetupCoordinator(driver: effects, deadline: .milliseconds(100))
    await setup.refresh()
    var registrations = 0
    effects.register = { registrations += 1 }

    let (inspectionReturned, completion) = AsyncStream<Void>.makeStream()
    var delayed: CheckedContinuation<SetupObservation, Never>?
    effects.inspect = {
        effects.inspect = nil
        effects.observation = .stable(.waitingForLoginItem)
        defer { completion.finish() }
        return await withCheckedContinuation { delayed = $0 }
    }
    await setup.install()
    #expect(setup.status.phase == .waitingForLoginItem)
    #expect(!setup.willContinueAutomatically)

    let inspection = try #require(delayed)
    inspection.resume(returning: .stable(.notInstalled))
    var completionIterator = inspectionReturned.makeAsyncIterator()
    _ = await completionIterator.next()

    effects.observation = .freshPairingNeeded(version: "1")
    await setup.refresh()
    #expect(setup.status.phase == .notPaired)
    #expect(!setup.willContinueAutomatically)
    #expect(registrations == 0)
    #expect(effects.enrollments == 0)
}

@Test @MainActor func waitsForApprovalAndRetriesSlowHelperWithoutReplacingIt() async {
    let effects = SetupFixture()
    let setup = SetupCoordinator(driver: effects)
    await setup.refresh()
    effects.register = { effects.observation = .stable(.waitingForLoginItem) }
    await setup.install()
    #expect(setup.status.phase == .waitingForLoginItem)
    effects.observation = .unreachable("Timed out")
    await setup.refresh()
    #expect(setup.status.phase == .starting)
    await setup.refresh()
    await setup.refresh()
    #expect(setup.status.phase == .unreachable)
    await setup.retry()
    #expect(setup.status.phase == .starting)
    effects.observation = .stable(.notPaired)
    await setup.refresh()
    #expect(setup.status.phase == .notPaired)
    #expect(effects.replacements == 0)
    effects.register = {}
}

@Test @MainActor func overlappingConnectAndLostReplyRecoverOnce() async {
    let effects = SetupFixture()
    effects.observation = .stable(.notPaired)
    let setup = SetupCoordinator(driver: effects)
    await setup.refresh()
    var resume: CheckedContinuation<Void, Never>?
    effects.enrollment = {
        await withCheckedContinuation { resume = $0 }
        effects.observation = .needsVerification(version: "1")
        throw Failure("Lost reply")
    }
    let connect = Task { await setup.connect() }
    while resume == nil { await Task.yield() }
    #expect(setup.status.phase == .pairing)
    await setup.refresh()
    await setup.connect()
    await #expect(throws: (any Error).self) { try await setup.remove {} }
    resume?.resume()
    await connect.value
    #expect(setup.status.phase == .ready)
    #expect(setup.status.message == nil)
    #expect(effects.enrollments == 1)
    #expect(effects.verifications == 1)
    effects.enrollment = {}
}

@Test @MainActor func lostRemovalReplyStillReconcilesObservedRemoval() async {
    let effects = SetupFixture()
    effects.observation = .stable(.ready)
    let setup = SetupCoordinator(driver: effects)
    var inspections = 0
    var registrations = 0
    effects.inspect = {
        inspections += 1
        return effects.observation
    }
    effects.register = { registrations += 1 }
    defer { effects.inspect = nil }
    await setup.refresh()

    let lostReply = Failure("Lost uninstall reply")
    await #expect(throws: lostReply) {
        try await setup.remove {
            #expect(setup.status.phase == .removing)
            effects.observation = .stable(.notInstalled)
            await setup.refresh()
            await setup.retry()
            await setup.install()
            await setup.connect(replacing: true)
            await #expect(throws: Failure.self) {
                try await setup.remove { Issue.record("An overlapping removal was started") }
            }
            #expect(setup.status.phase == .removing)
            #expect(inspections == 1)
            throw lostReply
        }
    }
    #expect(setup.status.phase == .notInstalled)
    #expect(inspections == 2)
    #expect(registrations == 0)
    #expect(effects.enrollments == 0)
}

@Test @MainActor func cancelledAuthorizationReturnsToConnectWithoutPromptingAgain() async {
    let effects = SetupFixture()
    effects.observation = .stable(.notPaired)
    effects.enrollment = { throw Failure("Cancelled.") }
    let setup = SetupCoordinator(driver: effects)
    await setup.refresh()
    await setup.connect()
    await setup.refresh()
    #expect(setup.status.phase == .notPaired)
    #expect(setup.status.message == "Cancelled.")
    #expect(effects.enrollments == 1)
}

@Test @MainActor func restartResumesVerificationAndBoundsAutomaticRetries() async {
    let effects = SetupFixture()
    effects.observation = .needsVerification(version: "1")
    effects.verify = { throw Failure("Keys locked") }
    let setup = SetupCoordinator(driver: effects)
    for _ in 0..<6 { await setup.refresh() }
    #expect(setup.status.phase == .verificationFailed)
    #expect(setup.status.message == "Keys locked")
    #expect(effects.verifications == 3)
    effects.verify = {}
    await setup.retry()
    #expect(setup.status.phase == .ready)
    #expect(effects.enrollments == 0)
}

@Test func interruptedKeyCommitPreservesPreviousKeysAndCanResume() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let files = PairingFiles(current: folder.appendingPathComponent("keys.json"))
    let old = Data("old".utf8), new = Data("new".utf8)
    do {
        let lock = try files.lock()
        defer { withExtendedLifetime(lock) {} }
        try files.stage(old)
        try files.commit()
        try files.stage(new)
        #expect(try files.read(files.current) == old)
        #expect(try files.read(files.pending) == new)
        #expect(throws: (any Error).self) { try files.lock() }
    }
    let restarted = PairingFiles(current: files.current)
    let lock = try restarted.lock()
    defer { withExtendedLifetime(lock) {} }
    let permissions = try FileManager.default.attributesOfItem(atPath: restarted.pending.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    try restarted.commit()
    #expect(try restarted.read(restarted.current) == new)
    #expect(try restarted.read(restarted.pending) == nil)
    #expect(throws: (any Error).self) { try restarted.commit() }
    #expect(try restarted.read(restarted.current) == new)
}

@Test @MainActor func transientRegistrationRetriesOnlyWhileStillMissing() async {
    for registered in [false, true] {
        let effects = SetupFixture()
        let setup = SetupCoordinator(driver: effects)
        await setup.refresh()
        var calls = 0
        effects.register = {
            calls += 1
            if registered || calls == 2 { effects.observation = .stable(.waitingForLoginItem) }
            if calls == 1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY)) }
        }
        await setup.install()
        #expect(calls == (registered ? 1 : 2))
        #expect(setup.status.phase == .waitingForLoginItem)
        effects.register = {}
    }
}

@Test func reconcilesLegacyAndPendingFilesWithRemotePairings() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let files = PairingFiles(current: folder.appendingPathComponent("keys.json"))
    let lock = try files.lock()
    defer { withExtendedLifetime(lock) {} }
    let legacy = Data(#"{"read":"AQ==","write":"Ag==","publicKeys":{"read":"Aw==","write":"BA=="}}"#.utf8)
    try legacy.write(to: files.current)
    let original = try #require(try files.candidates(accepted: [Data([3])]).first)
    #expect(original.file == files.current)
    let next = AppKeys(read: Data([5]), write: Data([6]), publicKeys: PairingKeys(read: Data([7]), write: Data([8])))
    try Data("{".utf8).write(to: files.pending)
    #expect(try files.candidates(accepted: [Data([3])]).first?.keys == original.keys)
    #expect(try files.preparedKeys() == nil)
    try files.stage(JSONEncoder().encode(next))
    #expect(try files.preparedKeys() == next)
    #expect(try files.candidates(accepted: [Data([3])]).first?.file == files.current)
    #expect(try files.candidates(accepted: [Data([3]), Data([7])]).first?.file == files.pending)
    #expect(try files.read(files.current) == legacy)
    try files.commit()
    #expect(try files.candidates(accepted: [Data([7])]).first?.keys == next)
    #expect(try files.candidates(accepted: [Data([7])]).first?.file == files.current)
}

@Test @MainActor func oneMissedHeartbeatKeepsTheVerifiedSession() async {
    let effects = SetupFixture()
    effects.observation = .stable(.ready)
    let setup = SetupCoordinator(driver: effects)
    await setup.refresh()
    effects.observation = .unreachable("Timed out")
    await setup.refresh()
    #expect(setup.status.phase == .ready)
    effects.observation = .stable(.ready)
    await setup.refresh()
    effects.observation = .unreachable("Timed out")
    await setup.refresh()
    await setup.refresh()
    #expect(setup.status.phase == .ready)
    await setup.refresh()
    #expect(setup.status.phase == .unreachable)
}

@Test @MainActor func fatalPrerequisitesStopAllSetupUntilRelaunch() async {
    for requirement in SetupRequirement.allCases {
        let effects = SetupFixture()
        var inspections = 0
        effects.inspect = {
            inspections += 1
            return .stable(.stopped(requirement))
        }
        let setup = SetupCoordinator(driver: effects)
        await setup.refresh()
        await setup.retry()
        await setup.refresh()
        await setup.install()
        await setup.connect(replacing: true)
        await setup.update()
        await #expect(throws: (any Error).self) { try await setup.remove {} }
        #expect(inspections == 1)
        #expect(setup.status.phase == .stopped(requirement))
        #expect(effects.enrollments == 0 && effects.replacements == 0)
    }
}

@Test @MainActor func lateUpdateCompletionCannotOverwriteRecoveredState() async {
    let effects = SetupFixture()
    effects.observation = .stable(.outdated(helper: "old"))
    let setup = SetupCoordinator(driver: effects, deadline: .milliseconds(100))
    await setup.refresh()
    var resume: CheckedContinuation<Void, Never>?
    var lateMutation = false
    effects.replacement = {
        await withCheckedContinuation { resume = $0 }
        try Task.checkCancellation()
        lateMutation = true
    }
    await setup.update()
    #expect(setup.status.phase == .outdated(helper: "old"))
    #expect(setup.status.message?.contains("timed out") == true)
    effects.observation = .stable(.notInstalled)
    await setup.retry()
    resume?.resume()
    await Task.yield()
    #expect(setup.status.phase == .notInstalled)
    #expect(!lateMutation)
}

@Test @MainActor func failedVerificationAllowsExplicitPerAccountRepair() async {
    let effects = SetupFixture()
    effects.observation = .needsVerification(version: "1")
    effects.verify = { throw Failure("Invalid device key") }
    let setup = SetupCoordinator(driver: effects)
    await setup.refresh()
    #expect(setup.status.phase == .verificationFailed)
    effects.enrollment = { effects.verify = {} }
    await setup.connect(replacing: true)
    #expect(setup.status.phase == .ready)
    #expect(effects.repairs == 1)
    effects.enrollment = {}
}

@Test @MainActor func brokenPendingKeyFallsBackAndInterruptedReplacementCanCommit() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let files = PairingFiles(current: folder.appendingPathComponent("keys.json"))
    let lock = try files.lock()
    defer { withExtendedLifetime(lock) {} }
    func key(_ n: UInt8) -> AppKeys {
        let bytes = Data([n])
        return AppKeys(read: bytes, write: bytes, publicKeys: PairingKeys(read: bytes, write: bytes))
    }
    let old = key(1), pending = key(2), new = key(3)
    try files.stage(JSONEncoder().encode(old))
    try files.commit()
    try files.stage(JSONEncoder().encode(pending))
    var attempted: [AppKeys] = []
    let recovered = try await files.verified(accepted: [old.read, pending.read]) {
        attempted.append($0)
        if $0 == pending { throw Failure("Cannot sign") }
    }
    #expect(attempted == [pending, old])
    #expect(recovered == old)
    try files.stageReplacement(new, accepted: [old.read, pending.read])
    #expect(try files.preparedKeys() == pending)
    #expect(try JSONDecoder().decode(AppKeys.self, from: Data(contentsOf: files.current)) == old)
    // After a lost RPC reply and relaunch, the helper reports just the newly accepted key.
    let restart = PairingFiles(current: files.current)
    let verified = try await restart.verified(accepted: [new.read]) { #expect($0 == new) }
    #expect(verified == new)
    #expect(try restart.candidates(accepted: [new.read]).first?.file == files.current)
}

@Test func accountRepairPreservesOtherUsersAndRejectsStaleRequests() throws {
    func pairing(_ uid: uid_t, _ n: UInt8) -> Pairing {
        let bytes = Data([n])
        return Pairing(keys: PairingKeys(read: bytes, write: bytes), uid: uid, user: "user", since: Date())
    }
    let old = pairing(501, 1), other = pairing(502, 2), replacement = pairing(501, 3)
    let request = AccountRepair(keys: replacement.keys, expected: [old.keys.read])
    let changed = try request.replacing(in: [old, other], with: replacement)
    #expect(changed == [other, replacement])
    #expect(throws: Failure.self) { try request.replacing(in: changed, with: replacement) }
}

@Test func preflightIdentifiesEachMissingPrerequisite() {
    #expect(SetupRequirement.unmet(teamSigned: false, enclave: true, admin: true) == .teamSignature)
    #expect(SetupRequirement.unmet(teamSigned: true, enclave: false, admin: true) == .secureEnclave)
    #expect(SetupRequirement.unmet(teamSigned: true, enclave: true, admin: false) == .adminAccount)
    #expect(SetupRequirement.unmet(teamSigned: true, enclave: true, admin: true) == nil)
}

@Test func unavailableAccountDirectoryIsRetryable() {
    func unavailable() throws -> Bool { throw Failure("Directory unavailable") }
    #expect(throws: Failure.self) {
        _ = try SetupRequirement.unmet(teamSigned: true, enclave: true, admin: unavailable())
    }
}
