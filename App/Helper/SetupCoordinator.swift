import Foundation

enum SetupPhase: Equatable {
    case stopped(SetupRequirement), checking, notInstalled, registering, waitingForLoginItem, starting, unreachable
    case outdated(helper: String), updating, notPaired, pairing, verifying, verificationFailed
    case ready, removing, blocked

    var stopped: Bool {
        if case .stopped = self { return true }
        return false
    }

    var busy: Bool {
        switch self {
        case .checking, .registering, .updating, .pairing, .verifying, .removing: true
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
    case needsVerification(version: String)
}

@MainActor protocol SetupDriver: AnyObject {
    func inspectSetup() async throws -> SetupObservation
    func registerHelper() async throws
    func replaceRegistration() async throws
    func enroll(replacing: Bool) async throws
    func verifyAndCommit() async throws
}

@MainActor final class SetupCoordinator {
    struct Status: Equatable {
        var phase: SetupPhase = .checking
        var version: String?
        var message: String?
    }

    private(set) var status = Status() {
        willSet { if newValue != status { willChange() } }
    }
    private unowned let driver: any SetupDriver
    private let willChange: () -> Void
    private var generation = 0
    private var exclusive = false
    private var missedHellos = 0
    private var failedVerifications = 0
    private let retryLimit = 3
    private let deadline: Duration

    init(driver: any SetupDriver, deadline: Duration = .seconds(120), willChange: @escaping () -> Void = {}) {
        self.deadline = deadline
        self.driver = driver
        self.willChange = willChange
    }

    // NodeStore polls at launch and every five seconds. A click supersedes any read-only poll in flight.
    func refresh() async {
        guard !exclusive, !status.phase.stopped else { return }
        generation += 1
        await reconcile(generation)
    }

    func retry() async {
        guard !exclusive, !status.phase.stopped else { return }
        resetRetries()
        await refresh()
    }

    func install() async {
        guard status.phase == .notInstalled else { return }
        await transition(.registering) {
            do { try await self.driver.registerHelper() }
            catch {
                // Only retry a transient system error, and only after confirming that registration did not take.
                let failure = error as NSError
                guard failure.domain == NSPOSIXErrorDomain,
                      [Int(EAGAIN), Int(EBUSY), Int(EINTR), Int(ETIMEDOUT)].contains(failure.code) else { throw error }
                try await Task.sleep(for: .milliseconds(250))
                if case .stable(.notInstalled, _) = try await self.driver.inspectSetup() { try await self.driver.registerHelper() }
            }
        }
    }

    func update() async {
        switch status.phase {
        case .outdated, .unreachable: break
        default: return
        }
        await transition(.updating) { try await self.driver.replaceRegistration() }
    }

    func connect(replacing: Bool = false) async {
        guard status.phase == .notPaired || (replacing && (status.phase == .verificationFailed || status.phase == .ready)) else { return }
        await transition(.pairing, reportWhileReady: replacing) { try await self.driver.enroll(replacing: replacing) }
    }

    // Settings can be open alongside Setup. Its mutations use the same exclusion and reconciliation.
    func remove(_ work: @escaping @MainActor () async throws -> Void) async throws {
        guard !exclusive, !status.phase.stopped, !status.phase.busy else { throw Failure("Another helper setup operation is in progress.") }
        begin(.removing)
        defer { exclusive = false }
        do { try await bounded(work) }
        catch {
            await reconcile(generation)
            throw error
        }
        await reconcile(generation)
    }

    private func begin(_ phase: SetupPhase) {
        generation += 1
        exclusive = true
        resetRetries()
        status = Status(phase: phase, version: status.version)
    }

    private func bounded<T>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        try await SetupDeadline<T>().run(for: deadline, work)
    }

    private func resetRetries() {
        missedHellos = 0
        failedVerifications = 0
    }

    private func transition(_ phase: SetupPhase, reportWhileReady: Bool = false, work: @escaping @MainActor () async throws -> Void) async {
        guard !exclusive, !status.phase.stopped else { return }
        begin(phase)
        defer { exclusive = false }
        var operationError: String?
        do { try await bounded(work) }
        catch { operationError = error.localizedDescription }
        // Even a failed RPC can have committed remotely. Recover from the observed postcondition.
        await reconcile(generation)
        if let operationError, (reportWhileReady || status.phase != .ready), !status.phase.stopped {
            status.message = [operationError, status.message].compactMap { $0 }.joined(separator: "\n")
        }
    }

    private func reconcile(_ ticket: Int) async {
        do {
            let observation = try await bounded { try await self.driver.inspectSetup() }
            guard generation == ticket else { return }
            switch observation {
            case .stable(let phase, let version):
                resetRetries()
                let message = phase == status.phase ? status.message : nil
                status = Status(phase: phase, version: version, message: message)
            case .unreachable(let reason):
                failedVerifications = 0
                missedHellos = min(retryLimit, missedHellos + 1)
                // A single missed heartbeat after setup should not close an already usable main window.
                if status.phase == .ready && missedHellos < retryLimit { return }
                status = Status(phase: missedHellos < retryLimit ? .starting : .unreachable, message: reason)
            case .needsVerification(let version):
                missedHellos = 0
                guard failedVerifications < retryLimit else { return }
                let alreadyExclusive = exclusive
                exclusive = true
                defer { exclusive = alreadyExclusive }
                status = Status(phase: .verifying, version: version)
                do {
                    try await bounded { try await self.driver.verifyAndCommit() }
                    failedVerifications = 0
                    status = Status(phase: .ready, version: version)
                } catch {
                    failedVerifications += 1
                    status = Status(phase: .verificationFailed, version: version, message: error.localizedDescription)
                }
            }
        } catch {
            guard generation == ticket else { return }
            resetRetries()
            status = Status(phase: .blocked, message: error.localizedDescription)
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
