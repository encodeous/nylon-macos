import SwiftUI

// A network's nylon log, following it as nylon writes, through the helper. Keeps the last few thousand lines.
struct LogView: View {
    let store: NodeStore
    let network: String
    @State private var lines: [String] = []
    @State private var error: String?
    private static let keep = 5000

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { Text(lines[$0]).id($0) }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .onChange(of: lines) { scroll.scrollTo(lines.count - 1, anchor: .bottom) }
        }
        .overlay { if let error { Text(error).foregroundStyle(.red).padding() } }
        .frame(minWidth: 640, minHeight: 360)
        .navigationTitle("\(network) log")
        .task { await follow() }
    }

    private func follow() async {
        var next: UInt64?
        while !Task.isCancelled {
            do {
                let chunk = try await decodeJSON(LogChunk.self, store.helper.perform(.log(network: network, from: next)))
                if chunk.restarted { lines = [] }
                lines = (lines + chunk.text.split(separator: "\n").map(String.init)).suffix(Self.keep)
                next = chunk.next
                error = nil
            } catch {
                self.error = "\(error)"
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
