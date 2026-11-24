import Foundation
import ServiceManagement
import Testing
@testable import NylonApp

@Test(arguments: [SMAppService.Status.notRegistered, .notFound])
func missingRegistrationOffersInstallWhenBundleIsValid(_ status: SMAppService.Status) throws {
    var bundleChecks = 0
    let observation = try HelperClient.observeRegistration(status, xpcError: Failure("No helper replied")) {
        bundleChecks += 1
    }
    guard case .stable(.notInstalled, _) = observation else {
        Issue.record("A valid bundle without a registration must offer Install")
        return
    }
    #expect(bundleChecks == 1)
}

@Test(arguments: [SMAppService.Status.notRegistered, .notFound])
func missingRegistrationSurfacesBundleFailure(_ status: SMAppService.Status) {
    #expect(throws: Failure.self) {
        _ = try HelperClient.observeRegistration(status, xpcError: Failure("No helper replied")) {
            throw Failure("The bundle does not contain a helper")
        }
    }
}

@Test func registeredHelperDoesNotDependOnCurrentBundlePayload() throws {
    func unavailableBundle() throws { throw Failure("The current app bundle is missing its helper") }
    let error = Failure("XPC handshake stalled")
    let approval = try HelperClient.observeRegistration(.requiresApproval, xpcError: error, mutationInFlight: true,
                                                        validateBundle: unavailableBundle)
    guard case .stable(.waitingForLoginItem, _) = approval else {
        Issue.record("An existing registration needing approval must offer Login Items")
        return
    }
    let approved = try HelperClient.observeRegistration(.enabled, xpcError: error, mutationInFlight: true,
                                                        validateBundle: unavailableBundle)
    guard case .unreachable(let reason) = approved else {
        Issue.record("An enabled registration with a failed handshake must wait for the helper")
        return
    }
    #expect(reason == error.localizedDescription)
}

@MainActor private final class RegistrationFixture: SetupDriver {
    var status: SMAppService.Status = .notFound
    var mutationInFlight = false
    var verifiedSession = false
    var registrations = 0
    var registrationError: Error?

    func inspectSetup() throws -> SetupObservation {
        if verifiedSession { return .stable(.ready, version: "1") }
        return try HelperClient.observeRegistration(status, xpcError: Failure("No helper replied"),
                                                     mutationInFlight: mutationInFlight, validateBundle: {})
    }

    func registerHelper() throws {
        registrations += 1
        status = .requiresApproval
        if let registrationError { throw registrationError }
    }

    func repairRegistration(_ reason: RegistrationRepairReason) throws { Issue.record("Unexpected registration repair") }
    func replaceRegistration() throws { Issue.record("Unexpected replacement") }
    func enroll(replacing: Bool) throws { Issue.record("Unexpected enrollment") }
    func verifyAndCommit() throws { Issue.record("Unexpected pairing verification") }
}

@Test @MainActor func freshNotFoundRegistrationRequiresAClickAndWaitsForApproval() async {
    let effects = RegistrationFixture()
    let setup = SetupCoordinator(driver: effects)
    await setup.refresh()
    #expect(setup.status.phase == .notInstalled)
    #expect(effects.registrations == 0)

    await setup.install()
    #expect(setup.status.phase == .waitingForLoginItem)
    await setup.install()
    await setup.refresh()
    #expect(setup.status.phase == .waitingForLoginItem)
    #expect(effects.registrations == 1)
}

@Test(arguments: [false, true])
@MainActor func staleInstallClickPreservesExistingRegistration(verifiedSession: Bool) async {
    let effects = RegistrationFixture()
    let setup = SetupCoordinator(driver: effects)
    await setup.refresh()
    #expect(setup.status.phase == .notInstalled)

    effects.status = .requiresApproval
    effects.verifiedSession = verifiedSession
    await setup.install()
    #expect(setup.status.phase == (verifiedSession ? .ready : .waitingForLoginItem))
    #expect(effects.registrations == 0)
}

@Test @MainActor func observedApprovalSupersedesRegistrationError() async {
    let effects = RegistrationFixture()
    effects.registrationError = Failure("Registration reply was lost")
    let setup = SetupCoordinator(driver: effects)
    await setup.refresh()
    await setup.install()
    #expect(effects.registrations == 1)
    #expect(setup.status.phase == .waitingForLoginItem)
    #expect(setup.status.message == nil)
}

@Test @MainActor func notFoundWhileSystemMutationIsPendingDoesNotEnableInstall() async {
    let effects = RegistrationFixture()
    effects.mutationInFlight = true
    let setup = SetupCoordinator(driver: effects)
    await setup.refresh()
    #expect(setup.status.phase == .registrationPending)
    await setup.install()
    #expect(effects.registrations == 0)

    effects.mutationInFlight = false
    await setup.refresh()
    #expect(setup.status.phase == .notInstalled)
}

@Test func bundledRegistrationRequiresLaunchDaemonAndExecutable() throws {
    let manager = FileManager.default
    let bundle = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: bundle) }
    let plist = bundle.appendingPathComponent("Contents/Library/LaunchDaemons").appendingPathComponent(Helper.plistName)
    let executable = bundle.appendingPathComponent("Contents/MacOS/nylon-helper")
    try manager.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
    try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)

    #expect(throws: Failure.self) { try HelperClient.validateHelperBundle(at: bundle) }

    let validPlist: [String: Any] = [
        "Label": Helper.machService,
        "BundleProgram": "Contents/MacOS/nylon-helper",
        "MachServices": [Helper.machService: true]
    ]
    func writePlist(_ entries: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
        try data.write(to: plist)
    }

    try writePlist(validPlist)
    #expect(throws: Failure.self) { try HelperClient.validateHelperBundle(at: bundle) }
    try Data([0]).write(to: executable)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
    #expect(throws: Failure.self) { try HelperClient.validateHelperBundle(at: bundle) }
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    try HelperClient.validateHelperBundle(at: bundle)

    for (key, value) in [("Label", "other.helper" as Any),
                         ("BundleProgram", "Contents/MacOS/other-helper" as Any),
                         ("MachServices", [Helper.machService: false] as Any)] {
        var invalidPlist = validPlist
        invalidPlist[key] = value
        try writePlist(invalidPlist)
        #expect(throws: Failure.self) { try HelperClient.validateHelperBundle(at: bundle) }
    }
    try Data("not a plist".utf8).write(to: plist)
    #expect(throws: (any Error).self) { try HelperClient.validateHelperBundle(at: bundle) }
}
