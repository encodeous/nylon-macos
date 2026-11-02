import SwiftUI

// A network's nylon log, following it as nylon writes, through the helper, in a console you can select, copy and
// search (⌘F). Keeps the last few thousand lines.
struct ActivityTab: View {
    let store: NodeStore
    let network: String
    let active: Bool // the window builds every tab; this one only fetches while it's the one showing
    @State private var lines: [LogConsole.Line] = []
    @State private var count = 0
    @State private var next: UInt64? // where the log left off, so coming back to the tab carries on from there
    @State private var error: String?
    @State private var follow = true
    @State private var findRequest = 0
    @AppStorage("logWrap") private var wrap = true

    // Old lines are dropped in batches, not one at a time: dropping makes the console rebuild its text
    private static let keep = 5000
    private static let trimAt = 6000

    var body: some View {
        LogConsole(lines: lines, wrap: wrap, follow: follow, findRequest: $findRequest)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        Button("Find", systemImage: "magnifyingglass") { findRequest += 1 }
                            .help("Find in the log (⌘F)")
                        Spacer()
                        Toggle("Wrap Lines", isOn: $wrap)
                        Toggle("Follow", isOn: $follow)
                            .help("Keep the newest lines in view")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    Divider()
                }
                .background(.background)
            }
            .overlay { if let error { Text(error).foregroundStyle(.red).padding() } }
            .task(id: active) {
                if active { await tail() }
            }
    }

    private func tail() async {
        while !Task.isCancelled {
            do {
                let chunk = try await decodeJSON(LogChunk.self, store.helper.perform(.log(network: network, from: next)))
                if chunk.restarted { lines = [] }
                if !chunk.text.isEmpty {
                    let new = chunk.text.split(separator: "\n").map { text in
                        count += 1
                        return LogConsole.Line(id: count, text: ANSILine(String(text)))
                    }
                    lines += new
                    if lines.count > Self.trimAt { lines = Array(lines.suffix(Self.keep)) }
                }
                next = chunk.next
                error = nil
            } catch {
                self.error = "\(error)"
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
