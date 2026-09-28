import SwiftUI

/// Cheat sheet built from the same table that handles the keys.
struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Grid(alignment: .topLeading, horizontalSpacing: 28, verticalSpacing: 18) {
                ForEach(Array(stride(from: 0, to: KeyCommands.groups.count, by: 3)), id: \.self) { start in
                    GridRow {
                        ForEach(KeyCommands.groups[start..<min(start + 3, KeyCommands.groups.count)], id: \.self) { group in
                            section(group)
                        }
                    }
                }
            }
            Text("Single-key shortcuts work in the editor whenever you're not typing in a text field.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 1000)
    }

    private func section(_ group: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group).font(.headline)
            ForEach(KeyCommands.bindings.filter { $0.group == group }) { binding in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(binding.label)
                        .font(.callout.monospaced().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize()
                        .frame(width: 118, alignment: .leading)
                    Text(binding.title).font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
