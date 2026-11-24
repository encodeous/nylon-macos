import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// This layout is also the keys.json format written by earlier releases.
struct AppKeys: Codable, Equatable {
    let read: Data
    let write: Data
    let publicKeys: PairingKeys
}

// The current file stays usable until the helper has accepted and verified the pending key.
// Keep the lock file in place. The kernel releases its lock even if the app dies during an admin prompt.
struct PairingFiles {
    let current: URL
    var pending: URL { current.appendingPathExtension("pending") }

    private var replacement: URL { current.appendingPathExtension("replacement") }

    func hasSavedKeys() throws -> Bool {
        try [replacement, pending, current].contains { try read($0) != nil }
    }

    func read(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private func keys(at url: URL) throws -> AppKeys? {
        guard let data = try read(url) else { return nil }
        // An incomplete legacy record has no usable key pair. Keep it in place until a replacement is staged
        // or verified. File access errors propagate so a temporarily inaccessible key never triggers rotation.
        return try? JSONDecoder().decode(AppKeys.self, from: data)
    }

    func candidates(accepted: [Data]) throws -> [(keys: AppKeys, file: URL)] {
        var found: [(AppKeys, URL)] = []
        var readFailure: Error?
        for file in [replacement, pending, current] {
            do {
                if let keys = try keys(at: file), accepted.contains(keys.publicKeys.read) { found.append((keys, file)) }
            } catch { readFailure = error }
        }
        if found.isEmpty, let readFailure { throw readFailure }
        return found
    }

    // Called under the lock before requesting approval. Keep an accepted, interrupted replacement recoverable until
    // its successor is durable. A successful account replacement makes the older UID keys obsolete.
    func stageReplacement(_ keys: AppKeys, accepted: [Data]) throws {
        if let previous = try self.keys(at: replacement), accepted.contains(previous.publicKeys.read) {
            try stage(JSONEncoder().encode(previous), to: pending)
        }
        try stage(JSONEncoder().encode(keys), to: replacement)
    }

    @MainActor func verified(accepted: [Data], verify: (AppKeys) async throws -> Void) async throws -> AppKeys {
        var failure: Error = Failure("The pairing changed. Check the helper again.")
        for candidate in try candidates(accepted: accepted) {
            try Task.checkCancellation()
            do { try await verify(candidate.keys) }
            catch { failure = error; continue }
            try Task.checkCancellation()
            // Commit errors must be retried with the same verified key.
            if candidate.file != current { try commit(from: candidate.file) }
            else { try syncDirectory() } // a previous rename may have succeeded before its directory sync failed
            return candidate.keys
        }
        throw failure
    }

    // Called with the per-user lock held, before requesting authorization.
    func preparedKeys() throws -> AppKeys? {
        let saved = try keys(at: pending)
        if saved != nil { try syncDirectory() }
        return saved
    }

    final class Lock {
        fileprivate let fd: Int32
        fileprivate init(_ fd: Int32) { self.fd = fd }
        deinit { close(fd) }
    }

    func lock() throws -> Lock {
        try FileManager.default.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(current.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError() }
        let lock = Lock(fd)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw Failure("Another copy of nylon is setting up this account. Try again when it finishes.") }
            throw posixError()
        }
        return lock
    }

    // Call while holding the lock. mkstemp creates the file as 0600 before any key material is written.
    func stage(_ data: Data) throws { try stage(data, to: pending) }

    private func stage(_ data: Data, to destination: URL) throws {
        var template = Array(pending.path.appending(".XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw posixError() }
        let temp = String(cString: template)
        defer { unlink(temp) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.synchronize()
        try file.close()
        guard rename(temp, destination.path) == 0 else { throw posixError() }
        try syncDirectory()
    }

    func commit() throws { try commit(from: pending) }

    private func commit(from file: URL) throws {
        guard rename(file.path, current.path) == 0 else { throw posixError() }
        try syncDirectory()
    }

    // Persist the directory entry before sending a pairing RPC or publishing Ready.
    private func syncDirectory() throws {
        let fd = open(current.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        if fsync(fd) != 0, errno != EINVAL, errno != ENOTSUP { throw posixError() }
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
