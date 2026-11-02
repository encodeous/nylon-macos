import Foundation

// A network's folder holds its only copy of node.yaml, private key and all, so replacing it must never leave a moment
// where that copy lives anywhere else.

// Puts the folder at new where folder is. If folder exists, the two are swapped in one step (the kernel's
// RENAME_SWAP), so folder always holds a whole config, old or new; only then is the old one, now at new, deleted.
func installFolder(_ new: URL, at folder: URL) throws {
    guard FileManager.default.fileExists(atPath: folder.path) else {
        return try FileManager.default.moveItem(at: new, to: folder)
    }
    guard renamex_np(new.path, folder.path, UInt32(RENAME_SWAP)) == 0 else {
        throw Failure("Couldn't put the new config in place: \(String(cString: strerror(errno))). The old one is unchanged.")
    }
    try? FileManager.default.removeItem(at: new) // the old config, replaced
}

// Earlier helpers moved a network's folder aside to .<name>.old while replacing it. One that failed partway left the
// only copy there, and the next update deleted it. Puts any such copy back where its network has no folder, and leaves
// the rest alone.
func restoreSetAsideFolders(in networks: URL) {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: networks.path)) ?? []
    for entry in entries where entry.hasPrefix(".") && entry.hasSuffix(".old") {
        let name = String(entry.dropFirst().dropLast(".old".count))
        let folder = networks.appendingPathComponent(name)
        guard !name.isEmpty, !FileManager.default.fileExists(atPath: folder.path) else { continue }
        try? FileManager.default.moveItem(at: networks.appendingPathComponent(entry), to: folder)
    }
}
