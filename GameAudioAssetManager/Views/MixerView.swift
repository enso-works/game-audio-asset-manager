import SwiftUI

/// The project's mixer buses: volumes and nesting, exported to Godot's bus layout and Web Audio gain nodes.
struct MixerView: View {
    @Environment(Library.self) private var library
    @State private var prompt: NamePrompt?
    @State private var promptText = ""
    @State private var confirmReset = false

    var body: some View {
        let buses = library.config.mixBuses
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Every bus feeds its parent, and everything ends in Master. Events play on a bus, so turning a bus down turns all its events down.")
                    .foregroundStyle(.secondary)
                Spacer()
                Menu("Add Bus", systemImage: "plus") {
                    Button("Top Level") { add(parent: nil) }
                    Divider()
                    ForEach(buses) { bus in
                        Button("Inside \(bus.path)") { add(parent: bus.path) }
                    }
                }
                .fixedSize()
                Button("Reset to Defaults") { confirmReset = true }
            }
            List {
                row(name: "Master", depth: 0, volume: nil, events: count(on: "Master"), path: nil)
                ForEach(Mix.sorted(buses)) { bus in
                    row(name: bus.name, depth: bus.depth + 1, volume: Binding(
                        get: { bus.volumeDb },
                        set: { value in
                            var updated = library.config.mixBuses
                            if let index = updated.firstIndex(where: { $0.path == bus.path }) { updated[index].volumeDb = value }
                            library.setBuses(updated)
                        }
                    ), events: count(on: bus.path), path: bus.path)
                }
            }
            .listStyle(.inset)
            Text("Exported as audio_buses.tres (Godot, apply with Sounds.apply_bus_layout()) and as gain nodes in audio_engine.ts (web).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .navigationTitle("Mixer")
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("Name", text: $promptText)
            Button("OK") { prompt?.action(promptText) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Reset buses to the default layout?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { library.setBuses(Mix.defaultBuses) }
        } message: {
            Text("Events on removed buses move to the nearest remaining parent.")
        }
    }

    private func row(name: String, depth: Int, volume: Binding<Double>?, events: Int, path: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: depth == 0 ? "speaker.wave.3.fill" : "slider.horizontal.below.rectangle")
                .foregroundStyle(.secondary)
            Text(name).fontWeight(depth <= 1 ? .semibold : .regular)
                .frame(width: 160 - CGFloat(depth) * 16, alignment: .leading)
            if let volume {
                Slider(value: volume, in: -40...6, step: 0.5)
                Text(String(format: "%+.1f dB", volume.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
            } else {
                Spacer()
            }
            Text(events == 1 ? "1 event" : "\(events) events")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            if let path {
                Button("Remove", systemImage: "trash") { remove(path) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            } else {
                Color.clear.frame(width: 16)
            }
        }
        .padding(.leading, CGFloat(depth) * 16)
    }

    private func count(on bus: String) -> Int {
        library.events.values.filter { $0.bus == bus }.count
    }

    private func add(parent: String?) {
        promptText = ""
        prompt = NamePrompt(title: parent.map { "New Bus Inside \($0)" } ?? "New Bus", initial: "") { raw in
            let name = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
            guard !name.isEmpty, name != "Master" else { return }
            let path = parent.map { "\($0)/\(name)" } ?? name
            var buses = library.config.mixBuses
            guard !buses.contains(where: { $0.path == path }) else { return }
            buses.append(AudioBus(path: path))
            library.setBuses(buses)
        }
    }

    private func remove(_ path: String) {
        library.setBuses(library.config.mixBuses.filter { $0.path != path && !$0.path.hasPrefix(path + "/") })
    }
}
