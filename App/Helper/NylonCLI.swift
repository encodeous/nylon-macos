import Foundation

// The nylon inside the app, run as the user for what needs no root: making a node config and joining a network.
// The files it writes go to the helper afterwards, like any import.
enum NylonCLI {
    static let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/nylon")

    struct Output {
        var central: String?
        var node: String
        var publicKey: String?
    }

    // `nylon init` with args, in a private temporary folder it reads the files back from, then removes
    static func initNode(_ args: [String]) async throws -> Output {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nylon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let node = folder.appendingPathComponent("node.yaml"), central = folder.appendingPathComponent("central.yaml")
        let text = try await run(["init", "-o", node.path, "-c", central.path] + args)
        return Output(
            central: try? String(contentsOf: central, encoding: .utf8),
            node: try String(contentsOf: node, encoding: .utf8),
            publicKey: text.split(separator: "\n").first { $0.hasPrefix("Public key: ") }.map { String($0.dropFirst("Public key: ".count)) }
        )
    }

    private static func run(_ args: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = args
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure(message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message)
            }
            return text
        }.value
    }
}
