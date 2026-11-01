import Foundation

// Where the helper keeps things. Everything under support is root-only, since node.yaml holds the node's private key.
enum Paths {
    static let support = URL(fileURLWithPath: "/Library/Application Support/nylon")
    static let networks = support.appendingPathComponent("networks") // one folder per network, named by its interface
    static let staging = support.appendingPathComponent("import") // config waiting for `nylon verify`
    static let pairings = support.appendingPathComponent("pairings.json")
    static let logs = URL(fileURLWithPath: "/Library/Logs/nylon")
    static let sockets = URL(fileURLWithPath: "/var/run/nylon")
    static let commandLineTool = URL(fileURLWithPath: "/usr/local/bin/nylon")

    // The helper's own binary, inside nylon.app. If it's gone, so is the app.
    static let helper = Bundle.main.executableURL!.resolvingSymlinksInPath()

    // The nylon binary in the same app: the helper is nylon.app/Contents/MacOS/nylon-helper, nylon is
    // nylon.app/Contents/Helpers/nylon. The app belongs to a user, so the helper never runs this one as root; it
    // checks its signature and runs a copy in installedNylon.
    static let bundledNylon = helper.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/nylon")

    // Where the helper keeps the nylon it runs, and the nylon command links to: owned by root, readable by everyone.
    static let installedNylonFolder = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.encodeous.nylon")
    static let installedNylon = installedNylonFolder.appendingPathComponent("nylon")

    static func socket(_ network: String) -> URL { sockets.appendingPathComponent("\(network).sock") }

    // Makes folder, readable by root only.
    static func makePrivate(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.ownerAccountID: 0, .posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    // Writes data where only root can read it: the folder is made root-only first, so the file is never readable by
    // anyone else, even before its own mode is set.
    static func writePrivate(_ data: Data, to url: URL) throws {
        try makePrivate(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
