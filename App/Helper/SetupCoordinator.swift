import Foundation

enum SetupPhase: Equatable {
    case stopped(SetupRequirement), checking, notInstalled, registering, registrationPending, waitingForLoginItem, repairingRegistration, starting, unreachable, restartingHelper
    case outdated(helper: String), updating, notPaired, pairing, verifying, verificationFailed
    case ready, removing, blocked

    var stopped: Bool {
        if case .stopped = self { return true }
        return false
    }

    var busy: Bool {
        switch self {
        case .checking, .registering, .registrationPending, .repairingRegistration, .restartingHelper, .updating, .pairing, .verifying, .removing: true
        default: false
        }
    }
}

enum SetupRequirement: String, CaseIterable {
    case teamSignature = "Open a team-signed build of nylon to use the helper."
    case adminAccount = "Sign in to a macOS administrator account and reopen nylon."
    case secureEnclave = "This Mac has no available Secure Enclave. Nylon requires one to store its pairing keys."

    static func unmet(teamSigned: Bool, enclave: @autoclosure () -> Bool, admin: @autoclosure () throws -> Bool) rethrows -> Self? {
        guard teamSigned else { return .teamSignature }
        guard enclave() else { return .secureEnclave }
        guard try admin() else { return .adminAccount }
        return nil
    }
}

// Inspection has no side effects. Only an exclusive transition may change a registration or a key file.
enum SetupObservation {
    case stable(SetupPhase, version: String? = nil)
    case unreachable(String)
    case freshPairingNeeded(version: String)
    case needsVerification(version: String)
}

enum RegistrationRepairReason: Equatable {
    case approval, startup
}

@MainActor protocol SetupDriver: AnyObject {
    func inspectSetup() async throws -> SetupObservation
    func registerHelper() async throws
    func repairRegistration(_ reason: RegistrationRepairReason) async throws
    func replaceRegistration() async throws
    func enroll(replacing: Bool) async throws
    func enrollFresh() async throws
    func verifyAndCommit() async throws
}

extension SetupDriver {
    func enrollFresh() async throws { try await enroll(replacing: false) }
}

@MainActor final class SetupCoordinator {
    struct Status: Equatable {
        var phase: SetupPhase = .checking
        var version: String?
        var message: String?
    }

    // Reduces observed state and operation outcomes without making any system calls.
    private struct State {
        var status = Status()
        private enum PairingIntent { case off, requested, registrationAttempted }
        private var pairingIntent = PairingIntent.off
        private var missedHellos = 0
        private var failedVerifications = 0
        private let retryLimit = 3

        var willContinueAutomatically: Bool { pairingIntent == .registrationAttempted }

        mutating func begin(_ phase: SetupPhase) {
            if phase != .repairingRegistration {
                pairingIntent = phase == .registering ? .requested : .off
            }
            resetRetries()
            status = Status(phase: phase, version: status.version)
        }

        mutating func registrationAttempted() {
            if pairingIntent == .requested { pairingIntent = .registrationAttempted }
        }

        mutating func cancelAutomaticSetup() { pairingIntent = .off }

        mutating func resetRetries() {
            missedHellos = 0
            failedVerifications = 0
        }

        // A version returned here requests a signed read before advancing to Ready.
        mutating func observe(_ observation: SetupObservation) -> String? {
            switch observation {
            case .stable(let phase, let version):
                if phase != .waitingForLoginItem && phase != .registrationPending { cancelAutomaticSetup() }
                settle(phase, version: version)
            case .freshPairingNeeded(let version):
                settle(.notPaired, version: version)
            case .unreachable(let reason):
                failedVerifications = 0
                missedHellos = min(retryLimit, missedHellos + 1)
                if missedHellos == retryLimit { cancelAutomaticSetup() }
                // Keep a verified session through brief helper interruptions.
                if status.phase == .ready && missedHellos < retryLimit { return nil }
                let phase: SetupPhase = missedHellos < retryLimit ? .starting : .unreachable
                let message = phase == .unreachable && status.phase == phase ? status.message ?? reason : reason
                status = Status(phase: phase, message: message)
            case .needsVerification(let version):
                cancelAutomaticSetup()
                missedHellos = 0
                guard failedVerifications < retryLimit else { return nil }
                status = Status(phase: .verifying, version: version)
                return version
            }
            return nil
        }

        private mutating func settle(_ phase: SetupPhase, version: String?) {
            resetRetries()
            let message = status.phase == phase ? status.message : nil
            status = Status(phase: phase, version: version, message: message)
        }

        mutating func inspectionFailed(_ error: Error) {
            cancelAutomaticSetup()
            resetRetries()
            status = Status(phase: .blocked, message: error.localizedDescription)
        }

        mutating func verificationFinished(version: String, result: Result<Void, Error>) {
            switch result {
            case .success:
                failedVerifications = 0
                status = Status(phase: .ready, version: version)
            case .failure(let error):
                failedVerifications += 1
                status = Status(phase: .verificationFailed, version: version, message: error.localizedDescription)
            }
        }

        mutating func transitionFailed(_ phase: SetupPhase, error: Error, reportWhileReady: Bool) {
            guard phase != .removing, !status.phase.stopped, reportWhileReady || status.phase != .ready else { return }
            if phase == .registering {
                switch status.phase {
                case .waitingForLoginItem, .starting, .unreachable, .outdated, .notPaired, .verificationFailed:
                    return // Postflight observed registration or a later setup step.
                default: break
                }
            }
            if phase == .restartingHelper, status.phase == .starting {
                missedHellos = retryLimit
                status.phase = .unreachable
            }
            status.message = [error.localizedDescription, status.message].compactMap { $0 }.joined(separator: "\n")
        }
    }

    private var state = State() {
        willSet {
            if newValue.status != state.status || newValue.willContinueAutomatically != state.willContinueAutomatically {
                willChange()
            }
        }
    }
    private unowned let driver: any SetupDriver
    private let willChange: () -> Void
    private var generation = 0
    private var exclusive = false
    private let deadline: Duration

    init(driver: any SetupDriver, deadline: Duration = .seconds(120), willChange: @escaping () -> Void = {}) {
        self.deadline = deadline
        self.driver = driver
        self.willChange = willChange
    }

    var status: Status { state.status }
    var willContinueAutomatically: Bool { state.willContinueAutomatically }

    func refresh() async { await poll() }
    func retry() async { await poll(resetRetries: true) }

    // NodeStore polls at launch and every five seconds. A click supersedes any poll in flight.
    private func poll(resetRetries: Bool = false) async {
        guard !exclusive, !status.phase.stopped else { return }
        if resetRetries { state.resetRetries() }
        generation += 1
        let ticket = generation
        await reconcile(ticket)
        guard generation == ticket else { return }
        await continueFreshSetupIfNeeded()
    }

    func install() async {
        guard status.phase == .notInstalled else { return }
        await changeRegistration(.registering) { try await self.installWithRetry() }
    }

    func update() async {
        guard case .outdated = status.phase else { return }
        await changeRegistration(.updating) { try await self.driver.replaceRegistration() }
    }

    func repairRegistration() async {
        switch status.phase {
        case .waitingForLoginItem:
            await changeRegistration(.repairingRegistration) { try await self.driver.repairRegistration(.approval) }
        case .unreachable:
            await changeRegistration(.restartingHelper) { try await self.driver.repairRegistration(.startup) }
        default: break
        }
    }

    private func changeRegistration(_ progress: SetupPhase, _ work: @escaping @MainActor () async throws -> Void) async {
        let previousPhase = status.phase
        await transition(progress) {
            guard try await self.registrationStillMatches(previousPhase) else { return }
            try await work()
        }
        await continueFreshSetupIfNeeded()
    }

    // A signed XPC reply or a newer system status supersedes the button's snapshot.
    private func registrationStillMatches(_ previousPhase: SetupPhase) async throws -> Bool {
        let observation = try await driver.inspectSetup()
        try Task.checkCancellation()
        switch (previousPhase, observation) {
        case (.unreachable, .unreachable), (.outdated, .stable(.outdated, _)): return true
        case (.unreachable, _): return false
        case (_, .stable(let phase, _)): return previousPhase == phase
        default: return false
        }
    }

    private func installWithRetry() async throws {
        state.registrationAttempted()
        do { try await driver.registerHelper() }
        catch {
            let failure = error as NSError
            guard failure.domain == NSPOSIXErrorDomain,
                  [Int(EAGAIN), Int(EBUSY), Int(EINTR), Int(ETIMEDOUT)].contains(failure.code) else { throw error }
            try await Task.sleep(for: .milliseconds(250))
            if try await registrationStillMatches(.notInstalled) { try await driver.registerHelper() }
        }
    }

    func cancelAutomaticSetup() { state.cancelAutomaticSetup() }

    private func continueFreshSetupIfNeeded() async {
        guard !exclusive, willContinueAutomatically, status.phase == .notPaired else { return }
        // Entering Pairing consumes the original setup action before any RPC or prompt.
        await transition(.pairing) { try await self.driver.enrollFresh() }
    }

    func connect(replacing: Bool = false) async {
        guard status.phase == .notPaired || (replacing && (status.phase == .verificationFailed || status.phase == .ready)) else { return }
        await transition(.pairing, reportWhileReady: replacing) { try await self.driver.enroll(replacing: replacing) }
    }

    // Settings mutations share setup exclusion. Their errors are delivered to the Settings caller.
    func remove(_ work: @escaping @MainActor () async throws -> Void) async throws {
        if let error = await transition(.removing, work: work) { throw error }
    }

    @discardableResult
    private func transition(_ phase: SetupPhase, reportWhileReady: Bool = false, work: @escaping @MainActor () async throws -> Void) async -> Error? {
        guard !exclusive, !status.phase.stopped, phase != .removing || !status.phase.busy else {
            return phase == .removing ? Failure("Another helper setup operation is in progress.") : nil
        }
        generation += 1
        let ticket = generation
        exclusive = true
        defer { exclusive = false }
        state.begin(phase)

        let result = await run(work)
        // Even a failed RPC can have committed remotely. Recover from the observed postcondition.
        await reconcile(ticket)
        guard case .failure(let error) = result else { return nil }
        state.transitionFailed(phase, error: error, reportWhileReady: reportWhileReady)
        return error
    }

    private func run<Value>(_ work: @escaping @MainActor () async throws -> Value) async -> Result<Value, Error> {
        do { return .success(try await SetupDeadline<Value>().run(for: deadline, work)) }
        catch { return .failure(error) }
    }

    private func reconcile(_ ticket: Int) async {
        let inspection = await run { try await self.driver.inspectSetup() }
        guard generation == ticket else { return }
        switch inspection {
        case .success(let observation):
            guard let version = state.observe(observation) else { return }

            let alreadyExclusive = exclusive
            exclusive = true
            defer { exclusive = alreadyExclusive }
            let result = await run { try await self.driver.verifyAndCommit() }
            state.verificationFinished(version: version, result: result)
        case .failure(let error):
            state.inspectionFailed(error)
        }
    }
}

// An OS request may ignore cancellation. Release the waiter at the deadline and ignore a late result.
// Drivers check cancellation before subsequent mutations and serialize outstanding registration requests.
@MainActor final class SetupDeadline<Value> {
    private var waiter: CheckedContinuation<Value, Error>?
    private var operation: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func run(for duration: Duration, _ work: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
                operation = Task {
                    do {
                        try Task.checkCancellation()
                        finish(.success(try await work()))
                    } catch { finish(.failure(error)) }
                }
                timer = Task {
                    do { try await Task.sleep(for: duration) } catch { return }
                    cancel(Failure("Setup timed out. Check the current state before retrying."))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(CancellationError()) }
        }
    }

    private func cancel(_ error: Error) {
        operation?.cancel()
        finish(.failure(error))
    }

    private func finish(_ result: Result<Value, Error>) {
        guard let waiter else { return }
        self.waiter = nil
        timer?.cancel()
        timer = nil
        operation = nil
        waiter.resume(with: result)
    }
}
