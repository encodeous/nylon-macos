import AppKit
import SwiftUI

// A plain-text YAML editor: highlights keys and comments, marks lines with problems, and offers the schema's keys as
// you type one.
struct YAMLTextView: NSViewRepresentable {
    @Binding var text: String
    let keys: [String: String] // completions, with their docs
    let problemLines: Set<Int>
    @Binding var cursorLine: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.textContainerInset = NSSize(width: 8, height: 10)
        view.string = text
        context.coordinator.highlight(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let view = scroll.documentView as! NSTextView
        // redrawn only when the text came from outside or the marked lines changed, not on every SwiftUI update
        if view.string != text {
            view.string = text
            coordinator.highlight(view)
        } else if coordinator.highlighted != problemLines {
            coordinator.highlight(view)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: YAMLTextView
        var highlighted: Set<Int> = [] // the problem lines last drawn
        private var typedKeyCharacter = false

        private static let keyPattern = try! NSRegularExpression(pattern: #"^[ \t]*(?:- )?([A-Za-z_][A-Za-z0-9_]*)(?=:)"#, options: .anchorsMatchLines)
        private static let commentPattern = try! NSRegularExpression(pattern: #"#.*$"#, options: .anchorsMatchLines)

        init(_ parent: YAMLTextView) { self.parent = parent }

        // Completions are offered when a key character is typed, not on deletes or when choosing from the list (which
        // replaces the word, and would otherwise reopen it)
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            typedKeyCharacter = text.map { $0.count == 1 && $0.allSatisfy { $0.isLetter || $0 == "_" } } ?? false
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            highlight(view)
            // offer keys while a key is being typed: a word alone on its line, before any colon
            if typedKeyCharacter, let word = keyBeingTyped(view), word.count >= 2 {
                typedKeyCharacter = false
                view.complete(nil)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            // in UTF-16, like the selection, and counting only \n so \r\n line endings count once
            let before = (view.string as NSString).substring(to: view.selectedRange().location)
            let line = before.utf16.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
            if parent.cursorLine != line { DispatchQueue.main.async { self.parent.cursorLine = line } }
        }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange range: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let partial = (textView.string as NSString).substring(with: range)
            return parent.keys.keys.filter { $0.hasPrefix(partial) && $0 != partial }.sorted()
        }

        private func keyBeingTyped(_ view: NSTextView) -> String? {
            let text = view.string as NSString
            let caret = view.selectedRange().location
            let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
            let before = text.substring(with: NSRange(location: lineRange.location, length: caret - lineRange.location))
            guard let match = before.range(of: #"^\s*(- )?[a-z_]+$"#, options: .regularExpression) else { return nil }
            return before[match].trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        }

        func highlight(_ view: NSTextView) {
            // restyling during input method composition (Chinese, Japanese) wipes the text being composed
            guard let storage = view.textStorage, !view.hasMarkedText() else { return }
            highlighted = parent.problemLines
            let text = storage.string as NSString
            let all = NSRange(location: 0, length: text.length)
            storage.beginEditing()
            storage.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.textColor], range: all)
            var line = 1
            text.enumerateSubstrings(in: all, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
                if self.parent.problemLines.contains(line) {
                    storage.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.12), range: range)
                }
                line += 1
            }
            for (regex, color) in [(Self.keyPattern, NSColor.systemPurple), (Self.commentPattern, NSColor.secondaryLabelColor)] {
                for match in regex.matches(in: storage.string, range: all) {
                    let range = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                    storage.addAttribute(.foregroundColor, value: color, range: range)
                }
            }
            storage.endEditing()
        }
    }
}
