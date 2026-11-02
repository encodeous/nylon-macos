import Foundation

// Keeps node.yaml's private key out of the editor: the value on its top-level `key:` line becomes a placeholder, and
// only that line's placeholder is put back. The same text anywhere else in the file (a hook, a comment) stays as typed.
enum PrivateKeyMask {
    static let placeholder = "(hidden)"

    // a top-level `key:` line: its value, then maybe a comment. Spaces and tabs only, so it never runs onto the next line.
    private static let keyLine = try! NSRegularExpression(pattern: #"^key:[ \t]*([^\s#]+)[ \t]*(#.*)?$"#, options: .anchorsMatchLines)

    // The text with the key swapped for the placeholder, and the key
    static func hide(_ yaml: String) -> (text: String, key: String?) {
        let ns = yaml as NSString
        guard let match = keyLine.firstMatch(in: yaml, range: NSRange(location: 0, length: ns.length)) else { return (yaml, nil) }
        let value = match.range(at: 1)
        return (ns.replacingCharacters(in: value, with: placeholder), ns.substring(with: value))
    }

    // The text with the key back, if its line still holds the placeholder. A key the user typed in its place stays.
    static func restore(_ text: String, key: String?) -> String {
        let ns = text as NSString
        guard let key, let match = keyLine.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              ns.substring(with: match.range(at: 1)) == placeholder else { return text }
        return ns.replacingCharacters(in: match.range(at: 1), with: key)
    }
}
