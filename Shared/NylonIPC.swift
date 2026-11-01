import Foundation

// A client for nylon's IPC socket, one request per connection like `nylon status`. The wire format
// (nylon/protocol/nylon_ipc.proto): both sides send "NYLN" and a big-endian uint16 version, then frames of a
// big-endian uint32 length and that many bytes of protobuf.
enum NylonIPC {
    static let version: UInt16 = 1
    static let maxFrame = 16 << 20
    static let hello = Data("NYLN".utf8) + [UInt8(version >> 8), UInt8(version & 0xff)]

    // The version in the other side's hello.
    static func readHello(_ data: Data) throws -> UInt16 {
        guard data.count == 6, data.prefix(4) == Data("NYLN".utf8) else { throw Failure("Not a nylon IPC socket.") }
        return UInt16(data[data.startIndex + 4]) << 8 | UInt16(data[data.startIndex + 5])
    }

    static func frame(_ message: Data) throws -> Data {
        guard message.count <= maxFrame else { throw Failure("A \(message.count) byte frame is over the limit.") }
        return withUnsafeBytes(of: UInt32(message.count).bigEndian) { Data($0) } + message
    }

    // The length a frame's 4-byte header announces.
    static func frameLength(_ header: Data) throws -> Int {
        let length = Int(header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard length <= maxFrame else { throw Failure("A \(length) byte frame is over the limit.") }
        return length
    }

    // Whether a nylon answers at path within a second. A nylon that's starting has made its socket but isn't
    // answering yet, and this mustn't wait the full request timeout for it.
    static func answers(_ path: URL) -> Bool {
        guard let fd = try? connect(path, timeout: 1) else { return false }
        close(fd)
        return true
    }

    // The process ID of the nylon answering at path.
    static func serverPID(_ path: URL) -> pid_t? {
        guard let fd = try? connect(path, timeout: 1) else { return nil }
        defer { close(fd) }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 ? pid : nil
    }

    // Sends request and returns the response, or throws nylon's error.
    static func request(_ path: URL, _ request: Proto_IpcRequest) throws -> Proto_IpcResponse {
        let fd = try connect(path)
        defer { close(fd) }
        var request = request
        request.id = 1
        try write(fd, frame(request.serializedData()))
        let response = try Proto_IpcResponse(serializedBytes: read(fd, frameLength(read(fd, 4))))
        if response.hasError { throw Failure(response.error.message) }
        return response
    }

    // Connects and swaps hellos. Each read or write waits at most timeout seconds; a probe takes at most 10.
    private static func connect(_ path: URL, timeout seconds: Int = 15) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixFailure("socket") }
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        do {
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure("Socket path too long: \(path.path)") }
            withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else { throw posixFailure("connect to \(path.path)") }
            try write(fd, hello)
            let theirs = try readHello(read(fd, 6))
            guard theirs == version else { throw Failure("nylon speaks IPC version \(theirs), this app speaks \(version).") }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + sent, buf.count - sent)
                guard n > 0 else { throw posixFailure("write") }
                sent += n
            }
        }
    }

    private static func read(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        let n = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress, count, MSG_WAITALL) }
        guard n == count else { throw n == 0 ? Failure("nylon closed the connection.") : posixFailure("read") }
        return data
    }

    private static func posixFailure(_ what: String) -> Failure {
        Failure("\(what): \(String(cString: strerror(errno)))")
    }
}
