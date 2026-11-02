import AppKit
import SwiftUI

// Small pieces the tabs share.

// A titled group, like a section of a form
struct TitledGroup<Content: View>: View {
    let title: String
    var trailing: AnyView?
    @ViewBuilder let content: Content

    init(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                trailing
            }
            content
        }
    }
}

// A rounded box around rows or a table
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

// A number with its label, e.g. "Peers 4"
struct StatTile: View {
    let label: String
    let value: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .help(help)
    }
}

// A label over a value, for facts like the node's ID and key
struct Fact: View {
    let label: String
    let value: String
    var mono = false
    var copyable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(value)
                    .font(mono ? .system(.body, design: .monospaced) : .body)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if copyable {
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Small capsule labels like ACTIVE and BEST
struct Tag: View {
    let text: String
    var color: Color = .secondary
    var help: String = ""

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.5)))
            .help(help)
    }
}

extension View {
    // Hover help only where there's some: an empty .help still tracks the mouse, which adds up across a table
    @ViewBuilder func help(ifAny text: String?) -> some View {
        if let text, !text.isEmpty { help(text) } else { self }
    }
}

extension View {
    // No scroll edge glass at the top: the content is kept below the toolbar, so there's nothing for it to blur
    @ViewBuilder func belowToolbar() -> some View {
        if #available(macOS 26, *) { scrollEdgeEffectHidden(true, for: .top) } else { self }
    }
}

// Opens the app's Settings, from the windows that otherwise have no way there but the menu bar
struct SettingsButton: View {
    var body: some View {
        SettingsLink { Label("Settings", systemImage: "gearshape") }
            .labelStyle(.iconOnly)
            .help("Settings")
    }
}
