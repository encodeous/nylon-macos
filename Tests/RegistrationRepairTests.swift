import Testing
@testable import NylonApp

@MainActor private final class RegistrationRepairFixture: SetupDriver {
    var observation: SetupObservation = .stable(.waitingForLoginItem)
    var onRepair: ((RegistrationRepairReason) async throws -> Void)?
    var registrations = 0
    var replacements = 0
    var repairs = 0
    var enrollments = 0
    var verifications = 0

    func inspectSetup() -> SetupObservation { observation }

    func registerHelper() {
        registrations += 1
        observation = .stable(.waitingForLoginItem)
    }

    func replaceRegistration() { replacements += 1 }

    func repairRegistration(_ reason: RegistrationRepairReason) async throws {
        repairs += 1
        try await onRepair?(reason)
    }

    func enroll(replacing: Bool) {
        #expect(!replacing)
        enrollments += 1
        observation = .needsVerification(version: "1")
    }

    func verifyAndCommit() {
        verifications += 1
        observation = .stable(.ready, version: "1")
    }
}

@Test(arguments: [false, true])
@MainActor func relaunchRequiresExplicitRepairForStuckLoginItem(alreadyPaired: Bool) async {
    let driver = RegistrationRepairFixture()
    let setup = SetupCoordinator(driver: driver)
    await setup.refresh()
    await setup.refresh()
    await setup.retry()
    #expect(setup.status.phase == .waitingForLoginItem)
    #expect(driver.repairs == 0)

    driver.onRepair = { reason in
        #expect(reason == .approval)
        #expect(setup.status.phase == .repairingRegistration)
        #expect(setup.status.phase.busy)
        if driver.repairs == 1 { await setup.repairRegistration() }
        if alreadyPaired { driver.observation = .needsVerification(version: "1") }
        else { driver.observation = .freshPairingNeeded(version: "1") }
    }
    defer { driver.onRepair = nil }
    await setup.repairRegistration()
    #expect(setup.status.phase == (alreadyPaired ? .ready : .notPaired))
    await setup.repairRegistration()
    await setup.refresh()
    #expect(driver.repairs == 1)
    #expect(driver.registrations == 0)
    #expect(driver.replacements == 0)
    #expect(driver.enrollments == 0)
    #expect(driver.verifications == (alreadyPaired ? 1 : 0))
}

@Test @MainActor func staleRepairReconcilesWithoutMutatingRegistration() async {
    let outcomes: [(SetupObservation, SetupPhase, Int)] = [
        (.stable(.notInstalled), .notInstalled, 0),
        (.unreachable("No XPC response yet"), .starting, 0),
        (.needsVerification(version: "1"), .ready, 1)
    ]
    for (observation, phase, verifications) in outcomes {
        let driver = RegistrationRepairFixture()
        let setup = SetupCoordinator(driver: driver)
        await setup.refresh()
        #expect(setup.status.phase == .waitingForLoginItem)

        driver.observation = observation
        await setup.repairRegistration()
        #expect(setup.status.phase == phase)
        #expect(driver.repairs == 0)
        #expect(driver.registrations == 0)
        #expect(driver.replacements == 0)
        #expect(driver.enrollments == 0)
        #expect(driver.verifications == verifications)
    }
}

@Test @MainActor func explicitApprovalRepairPreservesFirstSetupContinuation() async {
    let driver = RegistrationRepairFixture()
    driver.observation = .stable(.notInstalled)
    let setup = SetupCoordinator(driver: driver)
    await setup.refresh()
    await setup.install()
    #expect(setup.status.phase == .waitingForLoginItem)
    #expect(setup.willContinueAutomatically)

    await setup.repairRegistration()
    #expect(setup.status.phase == .waitingForLoginItem)
    #expect(setup.willContinueAutomatically)
    driver.observation = .freshPairingNeeded(version: "1")
    await setup.refresh()
    #expect(setup.status.phase == .ready)
    #expect(driver.registrations == 1)
    #expect(driver.repairs == 1)
    #expect(driver.replacements == 0)
    #expect(driver.enrollments == 1)
    #expect(driver.verifications == 1)
}

@Test(arguments: [SetupPhase.waitingForLoginItem, .notInstalled])
@MainActor func failedApprovalRepairKeepsObservedPhaseAndRequiresAnotherClick(phase: SetupPhase) async {
    let driver = RegistrationRepairFixture()
    let setup = SetupCoordinator(driver: driver)
    await setup.refresh()
    driver.onRepair = { reason in
        #expect(reason == .approval)
        driver.observation = .stable(phase)
        throw Failure("Repair declined by macOS")
    }
    defer { driver.onRepair = nil }
    await setup.repairRegistration()
    #expect(setup.status.phase == phase)
    #expect(setup.status.message?.contains("Repair declined by macOS") == true)

    await setup.retry()
    await setup.refresh()
    #expect(setup.status.phase == phase)
    #expect(driver.repairs == 1)

    driver.onRepair = nil
    await setup.repairRegistration()
    #expect(driver.repairs == (phase == .waitingForLoginItem ? 2 : 1))
    #expect(driver.registrations == 0)
    #expect(driver.replacements == 0)
    #expect(driver.enrollments == 0)
}

@Test @MainActor func startupRepairRequiresAnExplicitClickAndKeepsThePairing() async {
    let driver = RegistrationRepairFixture()
    driver.observation = .unreachable("No XPC response yet")
    let setup = SetupCoordinator(driver: driver)
    await setup.refresh()
    await setup.refresh()
    await setup.repairRegistration()
    #expect(setup.status.phase == .starting)
    #expect(driver.repairs == 0)
    await setup.refresh()
    await setup.refresh()
    #expect(setup.status.phase == .unreachable)
    #expect(driver.repairs == 0)

    driver.onRepair = { reason in
        #expect(reason == .startup)
        #expect(setup.status.phase == .restartingHelper)
        #expect(setup.status.phase.busy)
        if driver.repairs == 1 { await setup.repairRegistration() }
        driver.observation = .needsVerification(version: "1")
    }
    defer { driver.onRepair = nil }
    await setup.repairRegistration()
    #expect(setup.status.phase == .ready)
    await setup.repairRegistration()
    #expect(driver.repairs == 1)
    #expect(driver.verifications == 1)
    #expect(driver.registrations == 0)
    #expect(driver.replacements == 0)
    #expect(driver.enrollments == 0)
}

@Test @MainActor func staleStartupRepairDoesNotOverrideApprovalOrAnAnsweringHelper() async {
    let outcomes: [(SetupObservation, SetupPhase, Int)] = [
        (.stable(.waitingForLoginItem), .waitingForLoginItem, 0),
        (.needsVerification(version: "1"), .ready, 1)
    ]
    for (observation, phase, verifications) in outcomes {
        let driver = RegistrationRepairFixture()
        driver.observation = .unreachable("No XPC response yet")
        let setup = SetupCoordinator(driver: driver)
        for _ in 0..<3 { await setup.refresh() }
        #expect(setup.status.phase == .unreachable)

        driver.observation = observation
        await setup.repairRegistration()
        #expect(setup.status.phase == phase)
        #expect(driver.repairs == 0)
        #expect(driver.registrations == 0)
        #expect(driver.replacements == 0)
        #expect(driver.enrollments == 0)
        #expect(driver.verifications == verifications)
    }
}

@Test @MainActor func failedStartupRepairKeepsTheObservedFailureAndDoesNotRetryAutomatically() async {
    let driver = RegistrationRepairFixture()
    driver.observation = .unreachable("No XPC response yet")
    let setup = SetupCoordinator(driver: driver)
    for _ in 0..<3 { await setup.refresh() }
    driver.onRepair = { reason in
        #expect(reason == .startup)
        throw Failure("Restart declined by macOS")
    }

    await setup.repairRegistration()
    #expect(setup.status.phase == .unreachable)
    #expect(setup.status.message?.contains("Restart declined by macOS") == true)
    #expect(setup.status.message?.contains("No XPC response yet") == true)
    await setup.retry()
    await setup.refresh()
    #expect(driver.repairs == 1)
    #expect(driver.enrollments == 0)
}
