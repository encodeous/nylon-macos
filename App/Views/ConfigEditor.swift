import SwiftUI

// Which file the editor window has open
struct ConfigFile: Codable, Hashable {
    var network: String
    var kind: ConfigKind
}

// A window that edits one of a network's files as YAML. Saving hands both files to the helper, which checks them with
// nylon verify and swaps them in.
struct ConfigEditor: View {
    let store: NodeStore
    let file: ConfigFile
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loadedFile = "" // as loaded, exactly as the helper has it
    @State private var secret: String? // node.yaml's private key, kept out of the editor
    @State private var problems: [ConfigProblem] = []
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var cursorLine = 1
    @State private var keyShown = false

    var body: some View {
        VStack(spacing: 0) {
            if loading {
                Group {
                    if error != nil {
                        Button("Try Again") { Task { await load() } }
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                YAMLTextView(text: $text, keys: ConfigSchema.keys(file.kind), problemLines: Set(problems.map(\.line)), cursorLine: $cursorLine)
            }
            Divider()
            statusBar
            Divider()
            HStack {
                if file.kind == .node && secret != nil {
                    Button(keyShown ? "Hide Private Key" : "Show Private Key", systemImage: keyShown ? "eye.slash" : "eye") { toggleKey() }
                        .disabled(loading)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save and Reload") { save() }
                    .keyboardShortcut("s")
                    .disabled(loading || saving || !problems.isEmpty || restored == loadedFile) // showing the key isn't a change
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle("\(file.network) · \(file.kind.fileName)")
        .task { await load() }
        // checked once typing pauses, not on every redraw: it parses the whole file
        .task(id: text) {
            guard !loading else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            problems = check(restored)
        }
    }

    private func check(_ yaml: String) -> [ConfigProblem] {
        var problems = ConfigValidator.validate(yaml, kind: file.kind)
        // what nylon reads, defaults included: a missing interface_name is "nylon", which would be another network
        if file.kind == .node, problems.isEmpty, let config = try? NodeConfig(yaml: yaml), config.interface != file.network {
            problems.append(ConfigProblem(line: line(of: "interface_name", in: yaml),
                                          message: "interface_name names this network, so it has to stay \(file.network)"))
        }
        return problems
    }

    // the first problem, or what the key under the cursor means
    @ViewBuilder private var statusBar: some View {
        HStack(spacing: 8) {
            if let error {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                Text(error).textSelection(.enabled)
            } else if let problem = problems.first {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text("Line \(problem.line): \(problem.message)")
                if problems.count > 1 { Text("+\(problems.count - 1) more").foregroundStyle(.secondary) }
            } else if let (key, doc) = docAtCursor {
                Text(key).font(.system(.callout, design: .monospaced)).fontWeight(.medium)
                Text(doc).foregroundStyle(.secondary)
            } else {
                Text(" ")
            }
            Spacer()
        }
        .font(.callout)
        .lineLimit(2)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var docAtCursor: (String, String)? {
        let lines = text.components(separatedBy: "\n")
        guard cursorLine - 1 < lines.count,
              let match = lines[cursorLine - 1].range(of: #"^\s*(- )?[A-Za-z_]+(?=:)"#, options: .regularExpression) else { return nil }
        let key = lines[cursorLine - 1][match].trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        return ConfigSchema.keys(file.kind)[key].map { (key, $0) }
    }

    private func load() async {
        error = nil
        do {
            let config = try await store.config(file.network)
            loadedFile = file.kind == .node ? config.node : config.central
            let shown = file.kind == .node ? PrivateKeyMask.hide(loadedFile) : (text: loadedFile, key: nil)
            secret = shown.key
            text = shown.text
            problems = check(loadedFile)
            loading = false
        } catch {
            self.error = "\(error)" // e.g. Touch ID cancelled; Try Again asks once more
        }
    }

    private func save() {
        saving = true
        error = nil
        let mine = restored
        Task {
            do {
                // Both files go back together, so read them again first: nylon may have fetched a newer central.yaml,
                // or another editor saved the other file, since this one opened.
                let now = try await store.config(file.network)
                guard (file.kind == .node ? now.node : now.central) == loadedFile else {
                    throw Failure("\(file.kind.fileName) changed since you opened it. Close this and open it again to see the new version.")
                }
                try await store.saveConfig(file.network, central: file.kind == .central ? mine : now.central,
                                           node: file.kind == .node ? mine : now.node)
                dismiss()
            } catch {
                self.error = "\(error)"
            }
            saving = false
        }
    }

    // Puts the real key on the key line, or the placeholder back. A key edited while shown is the one kept.
    private func toggleKey() {
        if keyShown {
            let hidden = PrivateKeyMask.hide(text)
            text = hidden.text
            secret = hidden.key ?? secret
        } else {
            text = PrivateKeyMask.restore(text, key: secret)
        }
        keyShown.toggle()
    }

    // the text with the private key back in place of the placeholder
    private var restored: String {
        PrivateKeyMask.restore(text, key: secret)
    }

    private func line(of key: String, in yaml: String) -> Int {
        (yaml.components(separatedBy: "\n").firstIndex { $0.hasPrefix("\(key):") } ?? 0) + 1
    }
}
