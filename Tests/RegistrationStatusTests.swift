import Foundation
import ServiceManagement
import Testing
@testable import NylonApp

@MainActor private final class RegistrationStatusFixture: SetupDriver {
    var registration: SMAppService.Status = .requiresApproval
    var signedObservation: SetupObservation?
    var registrations = 0
    var replacements = 0
    var enrollments = 0
    var verifications = 0

    func inspectSetup() throws -> SetupObservation {
        if let signedObservation { return signedObservation }
        return try HelperClient.observeRegistration(registration, xpcError: Failure("No helper replied"), validateBundle: {})
    }

    func registerHelper() {
        registrations += 1
        registration = .requiresApproval
    }

    func repairRegistration(_ reason: RegistrationRepairReason) { Issue.record("Unexpected registration repair") }
    func replaceRegistration() { replacements += 1 }
    func enroll(replacing: Bool) { enrollments += 1 }

    func verifyAndCommit() {
        verifications += 1
        signedObservation = .stable(.ready, version: "1")
    }
}

@Test(arguments: [SMAppService.Status.notRegistered, .notFound])
@MainActor func disappearingRegistrationReturnsToStartAfterRelaunch(_ missing: SMAppService.Status) async {
    let driver = RegistrationStatusFixture()
    let original = SetupCoordinator(driver: driver)
    await original.refresh()
    #expect(original.status.phase == .waitingForLoginItem)

    let relaunched = SetupCoordinator(driver: driver)
    await relaunched.refresh()
    await relaunched.retry()
    #expect(relaunched.status.phase == .waitingForLoginItem)
    #expect(driver.registrations == 0)

    driver.registration = missing
    await relaunched.refresh()
    #expect(relaunched.status.phase == .notInstalled)
    #expect(driver.registrations == 0)
    #expect(driver.replacements == 0)

    await relaunched.install()
    #expect(relaunched.status.phase == .waitingForLoginItem)
    #expect(driver.registrations == 1)
    #expect(driver.replacements == 0)

    driver.registration = .enabled
    driver.signedObservation = .needsVerification(version: "1")
    await relaunched.refresh()
    #expect(relaunched.status.phase == .ready)
    #expect(driver.enrollments == 0)
    #expect(driver.verifications == 1)
}

@Test @MainActor func resumedApprovalCanProceedWithoutRegistrationMutation() async {
    let driver = RegistrationStatusFixture()
    let relaunched = SetupCoordinator(driver: driver)
    await relaunched.refresh()
    #expect(relaunched.status.phase == .waitingForLoginItem)

    driver.registration = .enabled
    await relaunched.refresh()
    #expect(relaunched.status.phase == .starting)
    await relaunched.refresh()
    await relaunched.refresh()
    #expect(relaunched.status.phase == .unreachable)
    await relaunched.retry()
    #expect(relaunched.status.phase == .starting)

    driver.signedObservation = .freshPairingNeeded(version: "1")
    await relaunched.refresh()
    #expect(relaunched.status.phase == .notPaired)
    #expect(driver.registrations == 0)
    #expect(driver.replacements == 0)
    #expect(driver.enrollments == 0)
}

@Test @MainActor func staleUpdateClickPreservesRecoveredPairing() async {
    let driver = RegistrationStatusFixture()
    driver.signedObservation = .stable(.outdated(helper: "old"))
    let setup = SetupCoordinator(driver: driver)
    await setup.refresh()
    #expect(setup.status.phase == .outdated(helper: "old"))

    driver.signedObservation = .needsVerification(version: "1")
    await setup.update()
    #expect(setup.status.phase == .ready)
    #expect(driver.replacements == 0)
    #expect(driver.enrollments == 0)
    #expect(driver.verifications == 1)
}

@Test func updateRecognizesOnlyMissingRegistration() {
    let missing = NSError(domain: "SMAppServiceErrorDomain", code: Int(kSMErrorJobNotFound))
    let denied = NSError(domain: "SMAppServiceErrorDomain", code: Int(kSMErrorAuthorizationFailure))
    let otherDomain = NSError(domain: NSPOSIXErrorDomain, code: Int(kSMErrorJobNotFound))
    #expect(HelperClient.canRegisterAfterUnregisterFailure(missing, status: .requiresApproval))
    #expect(!HelperClient.canRegisterAfterUnregisterFailure(denied, status: .requiresApproval))
    #expect(!HelperClient.canRegisterAfterUnregisterFailure(denied, status: .notFound))
    #expect(!HelperClient.canRegisterAfterUnregisterFailure(otherDomain, status: .requiresApproval))
    #expect(!HelperClient.canRegisterAfterUnregisterFailure(CancellationError(), status: .notRegistered))
}
