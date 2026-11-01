import Foundation
import Testing
@testable import NylonApp

// A fake nylon on a real Unix socket: answers the hello, then each request with a status for this node, or the
// error the test gives.
private final class FakeNylon {
    let path: URL
    private let fd: Int32

    init(error: String? = nil, hello: Data = NylonIPC.hello) throws {
        path = URL(fileURLWithPath: "/tmp/nylon-test-\(UUID().uuidString.prefix(8)).sock")
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.path.utf8)) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { throw Failure("listen failed") }
        let fd = fd
        Thread.detachNewThread {
            while true {
                let conn = accept(fd, nil, nil)
                guard conn >= 0 else { return }
                FakeNylon.serve(conn, error: error, hello: hello)
                close(conn)
            }
        }
    }

    deinit {
        close(fd)
        unlink(path.path)
    }

    private static func serve(_ conn: Int32, error: String?, hello: Data) {
        guard read(conn, 6) != nil, write(conn, hello),
              let header = read(conn, 4), let length = try? NylonIPC.frameLength(header),
              let body = read(conn, length), let request = try? Proto_IpcRequest(serializedBytes: body) else { return }
        var response = Proto_IpcResponse()
        response.id = request.id
        if let error {
            response.error = .with { $0.code = .notFound; $0.message = error }
        } else {
            response.status = .with { $0.node = .with { $0.nodeID = "alice" } }
        }
        _ = write(conn, try! NylonIPC.frame(response.serializedData()))
    }

    private static func read(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        let n = data.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!, count, MSG_WAITALL) }
        return n == count ? data : nil
    }

    private static func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) } == data.count
    }
}

private func statusRequest() -> Proto_IpcRequest {
    var request = Proto_IpcRequest()
    request.status = Proto_StatusRequest()
    return request
}

@Test func requestsOverTheSocket() throws {
    let nylon = try FakeNylon()
    #expect(NylonIPC.answers(nylon.path))
    let response = try NylonIPC.request(nylon.path, statusRequest())
    #expect(response.id == 1)
    #expect(response.status.node.nodeID == "alice")
}

@Test func reportsNylonsErrors() throws {
    let nylon = try FakeNylon(error: "peer \"bob\" is not a neighbour")
    #expect(throws: Failure.self) { try NylonIPC.request(nylon.path, statusRequest()) }
    do {
        _ = try NylonIPC.request(nylon.path, statusRequest())
    } catch {
        #expect("\(error)" == "peer \"bob\" is not a neighbour")
    }
}

@Test func refusesOtherVersionsAndMissingSockets() throws {
    let newer = try FakeNylon(hello: Data("NYLN".utf8) + Data([0, 2]))
    #expect(throws: Failure("nylon speaks IPC version 2, this app speaks 1.")) { try NylonIPC.request(newer.path, statusRequest()) }
    #expect(!NylonIPC.answers(URL(fileURLWithPath: "/tmp/no-nylon-here.sock")))
}
