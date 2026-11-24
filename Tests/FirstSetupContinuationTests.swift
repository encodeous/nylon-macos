import Foundation
import Testing
@testable import NylonApp

@MainActor private final class FirstSetupFixture: SetupDriver {
    var observation: SetupObservation = .stable(.notInstalled)
    var inspect: (() async -> SetupObservation)?
    var enrollmentError: Error?
    var registrations = 0
    var enrollments = 0
    var verifications = 0

    func inspectSetup() async -> SetupObservation {
        if let inspect { return await inspect() }
        return observation
    }

    func registerHelper() {
        registrations += 1
        observation = .stable(.waitingForLoginItem)
    }

    func repairRegistration(_ reason: RegistrationRepairReason) { Issue.record("Unexpected registration repair") }
    func replaceRegistration() { Issue.record("Unexpected replacement") }

    func enroll(replacing: Bool) throws {
        #expect(!replacing)
        enrollments += 1
        if let enrollmentError { throw enrollmentError }
        observation = .needsVerification(version: "1")
    }

    func verifyAndCommit() {
        verifications += 1
        observation = .stable(.ready, version: "1")
    }
}

@Test @MainActor func freshInstallContinuesOnceAfterApprovalAndHandshake() async {
    let driver = FirstSetupFixture()
    let setup = SetupCoordinator(driver: driver)
    await setup.refresh()
    await setup.install()
    #expect(setup.status.phase == .waitingForLoginItem)
    #expect(driver.registrations == 1)
    #expect(driver.enrollments == 0)

    driver.observation = .unreachable("Starting")
    await setup.refresh()
    await setup.refresh()
    #expect(setup.status.phase == .starting)
    #expect(driver.enrollments == 0)

    driver.observation = .freshPairingNeeded(version: "1")
    await setup.refresh()
    await setup.refresh()
    #expect(setup.status.phase == .ready)
    #expect(driver.registrations == 1)
    #expect(driver.enrollments == 1)
    #expect(driver.verifications == 1)
}

@Test(arguments: [false, true])
@MainActor func existingRegistrationKeepsPairingManual(staleInstallClick: Bool) async {
    let driver = FirstSetupFixture()
    let setup = SetupCoordinator(driver: driver)
    if staleInstallClick { await setup.refresh() }
    driver.observation = .freshPairingNeeded(version: "1")
    if staleInstallClick { await setup.install() }
    else { await setup.refresh() }
    #expect(setup.status.phase == .notPaired)
    #expect(driver.registrations == 0)
    #expect(driver.enrollments == 0)

    await setup.connect()
    #expect(setup.status.phase == .ready)
    #expect(driver.enrollments == 1)
}

@Test @MainActor func existingPairingDataKeepsPairingManualAfterInstall() async {
    let driver = FirstSetupFixture()
    let setup = SetupCoordinator(driver: driver)
    await setup.refresh()
    await setup.install()
    driver.observation = .stable(.notPaired, version: "1")
    await setup.refresh()
    await setup.refresh()
    #expect(setup.status.phase == .notPaired)
    #expect(driver.registrations == 1)
    #expect(driver.enrollments == 0)
}

@Test(arguments: [false, true])
@MainActor func failedAutomaticPairingRequiresExplicitRetry(cancelled: Bool) async {
    let driver = FirstSetupFixture()
    let setup = SetupCoordinator(driver: driver)
    if cancelled { driver.enrollmentError = CancellationError() }
    else { driver.enrollmentError = Failure("Could not complete pairing") }
    await setup.refresh()
    await setup.install()
    driver.observation = .freshPairingNeeded(version: "1")
    await setup.refresh()
    #expect(setup.status.phase == .notPaired)
    #expect(driver.enrollments == 1)
    #expect(driver.verifications == 0)

    driver.enrollmentError = nil
    await setup.refresh()
    await setup.retry()
    #expect(setup.status.phase == .notPaired)
    #expect(driver.enrollments == 1)

    await setup.connect()
    #expect(setup.status.phase == .ready)
    #expect(driver.enrollments == 2)
    #expect(driver.verifications == 1)
}

@Test @MainActor func olderPollCannotRepeatAutomaticPairing() async {
    let driver = FirstSetupFixture()
    let setup = SetupCoordinator(driver: driver)
    await setup.refresh()
    await setup.install()

    var delayedPoll: CheckedContinuation<SetupObservation, Never>?
    driver.inspect = {
        await withCheckedContinuation { delayedPoll = $0 }
    }
    let olderPoll = Task { await setup.refresh() }
    while delayedPoll == nil { await Task.yield() }
    driver.inspect = nil
    driver.observation = .freshPairingNeeded(version: "1")
    await setup.refresh()
    delayedPoll?.resume(returning: .freshPairingNeeded(version: "1"))
    await olderPoll.value

    #expect(setup.status.phase == .ready)
    #expect(driver.enrollments == 1)
    #expect(driver.verifications == 1)
}

@Test @MainActor func closingSetupWhileAwaitingApprovalDisarmsAutomaticPairing() async {
    let driver = FirstSetupFixture()
    let setup = SetupCoordinator(driver: driver)
    await setup.refresh()
    await setup.install()
    #expect(setup.willContinueAutomatically)
    setup.cancelAutomaticSetup()
    driver.observation = .freshPairingNeeded(version: "1")
    await setup.refresh()
    #expect(setup.status.phase == .notPaired)
    #expect(driver.enrollments == 0)
}
