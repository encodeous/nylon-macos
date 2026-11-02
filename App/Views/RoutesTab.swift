import SwiftUI

// The routes nylon picked, and with internals on, the tables it built from them.
struct RoutesTab: View {
    let status: Proto_StatusResponse
    @State private var filter = ""
    @AppStorage("showRoutingInternals") private var internals = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    TextField("Filter by prefix or node", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Spacer()
                    Toggle("Show routing internals", isOn: $internals)
                }

                TitledGroup("Selected routes") {
                    RoutesTable(rows: status.routes.selected.filter(matches).map(RouteRow.init), showVia: true)
                }

                if internals {
                    TitledGroup("Forward table") { NextHopTable(entries: status.routes.forward.filter { matches($0.prefix, $0.nh) }) }
                    TitledGroup("Exit table") { NextHopTable(entries: status.routes.exit.filter { matches($0.prefix, $0.nh) }) }
                    TitledGroup("Feasibility distances") { RoutesTable(rows: status.feasibilityDistances.map(RouteRow.init)) }
                    TitledGroup("Local seqnos") { SeqnosTable(seqnos: status.node.seqnos) }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func matches(_ route: Proto_SelRoute) -> Bool {
        matches(route.pubRoute.source.prefix, route.pubRoute.source.nodeID, route.nh)
    }

    private func matches(_ fields: String...) -> Bool {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}
