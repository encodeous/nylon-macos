import AppKit
import SwiftUI

// A console: read-only text you can select across lines, copy, search with the find bar and scroll back through.
// New lines are appended, not redrawn; the whole text is only rebuilt when old lines were dropped or the log restarted.
struct LogConsole: NSViewRepresentable {
    struct Line: Identifiable, Equatable {
        var id: Int // numbered as it arrived
        var text: ANSILine
    }

    let lines: [Line]
    let wrap: Bool
    let follow: Bool
    @Binding var findRequest: Int // bumped to open the find bar

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.font = ANSILine.font
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.view = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let view = coordinator.view, let storage = view.textStorage else { return }
        coordinator.setWrap(wrap, in: scroll)

        // lines arrive numbered in order: the same first line means only new ones were added at the end
        let appended: [Line]
        if lines.first?.id == coordinator.firstID, let last = coordinator.lastID {
            appended = lines.filter { $0.id > last }
        } else {
            storage.setAttributedString(NSAttributedString())
            appended = lines
        }
        if !appended.isEmpty {
            let text = NSMutableAttributedString()
            for line in appended {
                if storage.length > 0 || text.length > 0 { text.append(NSAttributedString(string: "\n", attributes: [.font: ANSILine.font])) }
                text.append(line.text.styled)
            }
            storage.append(text)
            if follow { view.scrollToEndOfDocument(nil) }
        }
        coordinator.firstID = lines.first?.id
        coordinator.lastID = lines.last?.id

        if findRequest != coordinator.findRequest {
            coordinator.findRequest = findRequest
            view.window?.makeFirstResponder(view)
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            view.performTextFinderAction(item)
        }
    }

    final class Coordinator {
        weak var view: NSTextView?
        var firstID: Int?
        var lastID: Int?
        var findRequest = 0
        private var wrapping: Bool?

        // Wrapped, the text follows the width; unwrapped, each line runs on and the view scrolls sideways
        func setWrap(_ wrap: Bool, in scroll: NSScrollView) {
            guard wrap != wrapping, let view else { return }
            wrapping = wrap
            let container = view.textContainer
            scroll.hasHorizontalScroller = !wrap
            view.isHorizontallyResizable = !wrap
            view.autoresizingMask = wrap ? [.width] : []
            container?.widthTracksTextView = wrap
            container?.containerSize = NSSize(width: wrap ? scroll.contentSize.width : .greatestFiniteMagnitude,
                                              height: .greatestFiniteMagnitude)
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            if wrap { view.frame.size.width = scroll.contentSize.width }
        }
    }
}
