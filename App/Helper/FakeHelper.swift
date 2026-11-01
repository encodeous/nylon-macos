import Foundation

// A pretend helper with two networks, for working on the UI without the real one: launch the app with `-fake YES`
// (the "nylon (fake)" scheme does). It needs no signing, so it works in ad hoc builds.
@MainActor
final class FakeHelper {
    private var networks = [
        HelperState.Network(name: "nylon", status: .running, startAtBoot: true),
        HelperState.Network(name: "lab", status: .stopped, startAtBoot: false),
    ]
    private var commandLineTool = HelperState.CommandLineTool.notInstalled

    func perform(_ action: HelperAction) throws -> Data {
        switch action {
        case .state, .importConfig, .unpair: break
        case .status, .central, .probe: throw Failure("The fake helper only pretends to run networks.")
        case .reload: return try Proto_ReloadResponse.with { $0.result = .noop }.serializedData()
        case .log(_, let from): // a line a second, like a quiet nylon
            let line = "time=\(Date().ISO8601Format()) level=INFO msg=\(from == nil ? "\"nylon started\"" : "\"probe\" peer=bob rtt=1.8ms")\n"
            return try encodeJSON(LogChunk(text: line, next: (from ?? 0) + 1, restarted: false))
        case .stop(let name): set(name) { $0.status = .stopped }
        case .start(let name):
            set(name) { $0.status = .starting }
            Task { // like nylon bringing its interface up
                try? await Task.sleep(for: .seconds(2))
                self.set(name) { if $0.status == .starting { $0.status = .running } }
            }
        case .remove(let name): networks.removeAll { $0.name == name }
        case .setStartAtBoot(let name, let on): set(name) { $0.startAtBoot = on }
        case .setCommandLineTool(let installed): commandLineTool = installed ? .installed : .notInstalled
        }
        return try encodeJSON(HelperState(networks: networks, commandLineTool: commandLineTool))
    }

    private func set(_ name: String, _ change: (inout HelperState.Network) -> Void) {
        if let i = networks.firstIndex(where: { $0.name == name }) { change(&networks[i]) }
    }
}
