import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Adds a network to this Mac: by joining one with a setup token, from config files, or with a new node config.
struct AddNetworkSheet: View {
    enum Method: String, CaseIterable, Identifiable {
        case join = "Join with a Token", files = "Import Files", new = "New Node Config"
        var id: Self { self }
    }

    let store: NodeStore
    @Environment(\.dismiss) private var dismiss
    @State private var method = Method.join
    @State private var working = false
    @State private var error: String?
    @State private var startAtBoot = true

    // join, and new
    @State private var host = ""
    @State private var token = ""
    @State private var nodeID = nodeIDFor(Host.current().localizedName ?? "")
    @State private var addresses = ""
    @State private var prefixes = ""
    @State private var name = "nylon"
    @State private var port = "57175"
    @State private var dns = ""
    @State private var exclude = ""
    @State private var systemRouting = false
    @State private var noNetConfigure = false
    @State private var created: NylonCLI.Output? // a new node config, waiting for central.yaml
    @State private var joined: NylonCLI.Output? // a join that enrolled but didn't import: retrying mustn't enroll again
    @State private var task: Task<Void, Never>?

    // files
    @State private var centralFile: URL?
    @State private var nodeFile: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a Network").font(.headline)
            Picker("Method", selection: $method) {
                ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(working || created != nil)

            Form {
                switch method {
                case .join: joinForm
                case .files: filesForm
                case .new: newForm
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }

            HStack {
                Toggle("Start when this Mac starts", isOn: $startAtBoot)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) {
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(actionTitle) { go() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || !ready)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { name = unusedName() }
    }

    private var nameTaken: Bool { store.network(name) != nil }

    // nylon, then nylon2, nylon3: the first not already on this Mac
    private func unusedName() -> String {
        (["nylon"] + (2...99).map { "nylon\($0)" }).first { store.network($0) == nil } ?? ""
    }

    private var joinForm: some View {
        Group {
            Group {
                Text("Get a token by running `nylon init --serve` on a node in the network.").foregroundStyle(.secondary)
                TextField("Node to join", text: $host, prompt: Text("host or host:port"))
                TextField("Setup token", text: $token)
                TextField("Node ID", text: $nodeID)
                TextField("Addresses", text: $addresses, prompt: Text("e.g. 10.0.0.5"))
                TextField("Share subnets", text: $prefixes, prompt: Text("e.g. 192.168.50.0/24"))
                nameField
            }
            .disabled(joined != nil) // enrolled already; only the port can still change
            TextField("UDP port", text: $port)
        }
    }

    private var nameField: some View {
        TextField("Network name", text: $name)
            .foregroundStyle(nameTaken ? Color.red : .primary)
            .help(nameTaken ? "\(name) is already on this Mac" : "")
    }

    private var filesForm: some View {
        Group {
            fileRow("central.yaml", $centralFile)
            fileRow("node.yaml", $nodeFile)
        }
    }

    @ViewBuilder private var newForm: some View {
        if let created {
            LabeledContent("Public key") {
                HStack {
                    Text(created.publicKey ?? "—").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(created.publicKey ?? "", forType: .string)
                    }
                    .labelStyle(.iconOnly)
                }
            }
            Text("Send the public key to your network admin, then add their central.yaml.").foregroundStyle(.secondary)
            fileRow("central.yaml", $centralFile)
        } else {
            TextField("Node ID", text: $nodeID)
            nameField
            TextField("UDP port", text: $port)
            TextField("DNS resolvers", text: $dns, prompt: Text("ip:port, comma separated"))
            TextField("Exclude prefixes", text: $exclude, prompt: Text("e.g. 192.168.0.0/24"))
            Toggle("Route peer traffic through the system", isOn: $systemRouting)
            Toggle("Don't change this Mac's network settings", isOn: $noNetConfigure)
        }
    }

    private func fileRow(_ title: String, _ url: Binding<URL?>) -> some View {
        LabeledContent(title) {
            HStack {
                Text(url.wrappedValue?.lastPathComponent ?? "None").foregroundStyle(url.wrappedValue == nil ? .secondary : .primary)
                Button("Choose…") { url.wrappedValue = pick(title) }
            }
        }
    }

    private var actionTitle: String {
        switch method {
        case .join: "Join"
        case .files: "Add"
        case .new: created == nil ? "Create" : "Add"
        }
    }

    private var ready: Bool {
        switch method {
        case .join: !host.isEmpty && !token.isEmpty && !name.isEmpty && !nameTaken && UInt16(port) != nil
        case .files: centralFile != nil && nodeFile != nil
        case .new: created == nil ? !name.isEmpty && !nameTaken && UInt16(port) != nil : centralFile != nil
        }
    }

    private func go() {
        working = true
        error = nil
        task = Task {
            do {
                switch method {
                case .join:
                    if joined == nil {
                        joined = try await NylonCLI.initNode(["--connect", host, "--token", token, "--interface-name", name, "--port", port]
                                                             + flag("--id", nodeID) + list("--address", addresses) + list("--prefix", prefixes))
                    }
                    guard let out = joined, let central = out.central else { throw Failure("Nylon didn't write a central.yaml.") }
                    try await add(central: Data(central.utf8), node: Data(withPort(out.node).utf8))
                case .files:
                    try await add(central: Data(contentsOf: centralFile!), node: Data(contentsOf: nodeFile!))
                case .new:
                    if let created {
                        try await add(central: Data(contentsOf: centralFile!), node: Data(created.node.utf8))
                    } else {
                        var args = ["--interface-name", name, "--port", port] + flag("--id", nodeID) + list("--dns-resolver", dns) + list("--exclude-ip", exclude)
                        if systemRouting { args.append("--use-system-routing") }
                        if noNetConfigure { args.append("--no-net-configure") }
                        created = try await NylonCLI.initNode(args)
                    }
                }
            } catch {
                self.error = "\(error)"
            }
            working = false
        }
    }

    private func add(central: Data, node: Data) async throws {
        try Task.checkCancellation()
        try checkFiles(central: String(decoding: central, as: UTF8.self), node: String(decoding: node, as: UTF8.self))
        // the helper updates a network with the same name in place, so this would replace it, private key and all
        let added = try NodeConfig(yaml: String(decoding: node, as: UTF8.self)).interface
        if store.network(added) != nil { throw Failure("\(added) is already on this Mac. Give the new network another interface_name.") }
        try await store.addNetwork(central: central, node: node)
        if startAtBoot { await store.run(.setStartAtBoot(network: added, true), reason: "start \(added) with this Mac") }
        store.selection = added
        dismiss()
    }

    // Says what's wrong with the files in words, before the helper sees them: which file, which line, and whether
    // they look the wrong way round
    private func checkFiles(central: String, node: String) throws {
        func has(_ key: String, _ yaml: String) -> Bool { yaml.range(of: "(?m)^\(key):", options: .regularExpression) != nil }
        if has("routers", node) && has("key", central) {
            throw Failure("These look swapped: the file chosen as node.yaml is a central.yaml, and the one chosen as central.yaml is a node.yaml.")
        }
        if has("routers", node) { throw Failure("The file chosen as node.yaml is a central.yaml. Choose this Mac's node.yaml.") }
        if has("key", central) && !has("routers", central) {
            throw Failure("The file chosen as central.yaml is a node.yaml. Choose the network's central.yaml.")
        }
        for (name, yaml, kind) in [("node.yaml", node, ConfigKind.node), ("central.yaml", central, .central)] {
            if let problem = ConfigValidator.validate(yaml, kind: kind).first {
                throw Failure("\(name), line \(problem.line): \(problem.message)")
            }
        }
    }

    // a join's node.yaml with the port from the form, which may have changed since it enrolled (a port clash, say)
    private func withPort(_ node: String) -> String {
        node.replacingOccurrences(of: #"(?m)^port:[ \t]*\d+"#, with: "port: \(port)", options: .regularExpression)
    }

    private func flag(_ name: String, _ value: String) -> [String] {
        value.isEmpty ? [] : [name, value]
    }

    // "a, b" as --name a --name b
    private func list(_ name: String, _ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.flatMap { [name, $0] }
    }

    private func pick(_ name: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Choose \(name)"
        panel.allowedContentTypes = [.yaml]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// A node ID nylon accepts (state/validation.go: lower case letters, digits, . _ / -), made from this Mac's name
func nodeIDFor(_ name: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
    let id = String(name.lowercased().map { allowed.contains($0) ? $0 : "-" })
    return id.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
}
