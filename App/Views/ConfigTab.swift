import SwiftUI

// A network's config files, edited as YAML, and the things that aren't in them.
struct ConfigTab: View {
    @ObservedObject var store: NodeStore
    let network: HelperState.Network
    @Environment(\.openWindow) private var openWindow
    @State private var removing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Card {
                    Toggle(isOn: Binding(
                        get: { network.startAtBoot },
                        set: { on in Task { await store.run(.setStartAtBoot(network: network.name, on), reason: "change when \(network.name) starts") } }
                    )) {
                        Text("Start when this Mac starts").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .padding(12)
                }

                TitledGroup("Config files") {
                    Card {
                        VStack(spacing: 0) {
                            fileRow(.node)
                            Divider()
                            fileRow(.central)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Remove Network…", role: .destructive) { removing = true }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Remove \(network.name)?", isPresented: $removing) {
            Button("Remove", role: .destructive) { Task { await store.run(.remove(network: network.name), reason: "remove \(network.name)") } }
        } message: {
            Text("This stops it and deletes its config, including this Mac's private key for it.")
        }
    }

    private func fileRow(_ kind: ConfigKind) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text").font(.title2).foregroundStyle(.secondary)
            Text(kind.fileName).font(.system(.body, design: .monospaced)).fontWeight(.semibold)
            Spacer()
            Button("Edit…") { showWindow { openWindow(id: "editor", value: ConfigFile(network: network.name, kind: kind)) } }
        }
        .padding(12)
    }
}
