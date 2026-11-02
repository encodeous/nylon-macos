import AppKit

// nylon colors its log with ANSI escape codes (SGR: ESC [ … m). This turns a line into styled text for the console,
// and the text without the codes. Codes it doesn't know are dropped.
struct ANSILine: Equatable {
    var plain: String
    var styled: NSAttributedString

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)

    init(_ line: String) {
        var plain = ""
        let styled = NSMutableAttributedString()
        var color: NSColor?
        var faint = false
        var bold = false
        var rest = Substring(line)
        func append(_ text: Substring) {
            guard !text.isEmpty else { return }
            plain += text
            styled.append(NSAttributedString(string: String(text), attributes: [
                .font: bold ? Self.boldFont : Self.font,
                .foregroundColor: color ?? (faint ? NSColor.secondaryLabelColor : NSColor.textColor),
            ]))
        }
        while !rest.isEmpty {
            guard let escape = rest.firstIndex(of: "\u{1B}") else {
                append(rest)
                break
            }
            append(rest[..<escape])
            rest = rest[rest.index(after: escape)...]
            // ESC [ params m; anything else after ESC is skipped with it
            guard rest.first == "[", let end = rest.firstIndex(where: { $0.isLetter }) else { continue }
            if rest[end] == "m" {
                let codes = rest[rest.index(after: rest.startIndex)..<end].split(separator: ";").compactMap { Int($0) }
                for code in codes.isEmpty ? [0] : codes {
                    switch code {
                    case 0: color = nil; faint = false; bold = false
                    case 1: bold = true
                    case 2: faint = true
                    case 22: faint = false; bold = false
                    case 39: color = nil
                    case 30...37, 90...97: color = Self.palette[code % 10]
                    default: break
                    }
                }
            }
            rest = rest[rest.index(after: end)...]
        }
        self.plain = plain
        self.styled = styled
    }

    // black, red, green, yellow, blue, magenta, cyan, white; the bright ones (90 to 97) the same
    private static let palette: [NSColor?] = [nil, .systemRed, .systemGreen, .systemOrange, .systemBlue, .systemPurple, .systemCyan, nil]
}
