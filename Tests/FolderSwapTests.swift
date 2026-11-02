import Foundation
import Testing
@testable import NylonApp

private func folder(_ files: [String: String], in parent: URL, named name: String) throws -> URL {
    let url = parent.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    for (file, text) in files { try Data(text.utf8).write(to: url.appendingPathComponent(file)) }
    return url
}

private func read(_ url: URL, _ file: String) -> String? {
    try? String(contentsOf: url.appendingPathComponent(file), encoding: .utf8)
}

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nylon-swap-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// Replacing a network's folder swaps the two whole, then drops the old one
@Test func replacesAFolderInOneStep() throws {
    let root = try scratch()
    let live = try folder(["node.yaml": "old key"], in: root, named: "lab")
    let staged = try folder(["node.yaml": "new key"], in: root, named: "import")
    try installFolder(staged, at: live)
    #expect(read(live, "node.yaml") == "new key")
    #expect(!FileManager.default.fileExists(atPath: staged.path))
}

@Test func movesANewFolderIntoPlace() throws {
    let root = try scratch()
    let staged = try folder(["node.yaml": "key"], in: root, named: "import")
    let live = root.appendingPathComponent("lab")
    try installFolder(staged, at: live)
    #expect(read(live, "node.yaml") == "key")
}

// A failed swap leaves the old config where it was
@Test func keepsTheOldFolderWhenTheSwapFails() throws {
    let root = try scratch()
    let live = try folder(["node.yaml": "old key"], in: root, named: "lab")
    #expect(throws: Failure.self) { try installFolder(root.appendingPathComponent("missing"), at: live) }
    #expect(read(live, "node.yaml") == "old key")
}

// A copy an older helper set aside goes back where its network has no folder; one beside a live folder stays put
@Test func restoresSetAsideFolders() throws {
    let root = try scratch()
    _ = try folder(["node.yaml": "only copy"], in: root, named: ".lab.old")
    _ = try folder(["node.yaml": "live"], in: root, named: "work")
    _ = try folder(["node.yaml": "stale"], in: root, named: ".work.old")
    restoreSetAsideFolders(in: root)
    #expect(read(root.appendingPathComponent("lab"), "node.yaml") == "only copy")
    #expect(read(root.appendingPathComponent("work"), "node.yaml") == "live")
    #expect(read(root.appendingPathComponent(".work.old"), "node.yaml") == "stale")
}
