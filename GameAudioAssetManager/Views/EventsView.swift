import SwiftUI

/// Sound events: what the game triggers, which sounds it uses and how they vary.
struct EventsView: View {
    @Environment(Library.self) private var library
    @State private var selection: String?
    @State private var prompt: NamePrompt?
    @State private var promptText = ""
    @State private var message: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("New Event", systemImage: "plus") { newEvent() }
                    Button("From Groups", systemImage: "square.stack.3d.up") {
                        let created = library.createEventsFromGroups()
                        message = created.isEmpty ? "No new variation groups (sounds named like jump_01, jump_02)." : "Created \(created.count): \(created.joined(separator: ", "))"
                        if selection == nil { selection = created.first }
                    }
                    .help("Create an event for every variation group (jump_01, jump_02 ...) that has none yet")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                List(selection: $selection) {
                    ForEach(library.events.keys.sorted(), id: \.self) { key in
                        let event = library.events[key]!
                        HStack {
                            Image(systemName: event.spatial == nil ? "bolt.horizontal" : "cube.transparent")
                                .foregroundStyle(.secondary)
                            Text(key).lineLimit(1)
                            Spacer()
                            Text("\(event.sounds.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .tag(key)
                        .contextMenu {
                            Button("Rename...") { rename(key) }
                            Button("Duplicate") { duplicate(key) }
                            Divider()
                            Button("Delete", role: .destructive) {
                                library.removeEvent(key)
                                if selection == key { selection = nil }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            .padding(12)
            .frame(width: 280)

            Divider()

            if let selection, library.events[selection] != nil {
                EventEditor(key: selection)
                    .id(selection)
            } else {
                ContentUnavailableView(
                    library.events.isEmpty ? "No sound events yet" : "Select an event",
                    systemImage: "bolt.horizontal",
                    description: Text("An event is what the game triggers, like player/jump. It picks one of its sounds, varies pitch and volume, and plays on a mixer bus. Start with From Groups to turn jump_01, jump_02 ... into events.")
                )
            }
        }
        .navigationTitle("Sound Events")
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("player/jump", text: $promptText)
            Button("OK") { prompt?.action(promptText) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Lowercase letters, numbers, - and _, with / for groups (e.g. player/jump).")
        }
        .onAppear { if selection == nil { selection = library.events.keys.sorted().first } }
    }

    private func ask(_ title: String, initial: String, action: @escaping (String) -> Void) {
        promptText = initial
        prompt = NamePrompt(title: title, initial: initial, action: action)
    }

    private func newEvent() {
        ask("New Event", initial: "") { raw in
            let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard Mix.isValidEventKey(key), library.events[key] == nil else {
                message = "\"\(raw)\" isn't a valid new event name."
                return
            }
            library.setEvent(SoundEvent(bus: library.config.mixBuses.first { $0.path == "SFX" }?.path ?? "Master"), for: key)
            selection = key
        }
    }

    private func rename(_ key: String) {
        ask("Rename Event", initial: key) { raw in
            let newKey = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if library.renameEvent(key, to: newKey) {
                selection = newKey
            } else {
                message = "Couldn't rename to \"\(raw)\" (invalid or already used)."
            }
        }
    }

    private func duplicate(_ key: String) {
        guard let event = library.events[key] else { return }
        var copy = key + "_copy"
        var n = 2
        while library.events[copy] != nil {
            copy = "\(key)_copy\(n)"
            n += 1
        }
        library.setEvent(event, for: copy)
        selection = copy
    }
}

private struct EventEditor: View {
    @Environment(Library.self) private var library
    @Environment(EventAuditioner.self) private var auditioner
    let key: String

    private var event: Binding<SoundEvent> {
        Binding(get: { library.events[key] ?? SoundEvent() }, set: { library.setEvent($0, for: key) })
    }

    private var projectSounds: [String] {
        library.soundFiles(in: library.projectURL).compactMap { library.relativePath($0) }
    }

    var body: some View {
        let event = self.event
        Form {
            Section {
                if event.wrappedValue.sounds.isEmpty {
                    Text("No sounds yet. Add them from the menu below, or drag files here from the sidebar.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(event.wrappedValue.sounds.enumerated()), id: \.offset) { index, sound in
                    HStack {
                        Image(systemName: "waveform").foregroundStyle(.secondary)
                        Text(sound.path).lineLimit(1).truncationMode(.middle)
                        if library.isInInbox(library.projectURL.appendingPathComponent(sound.path)) {
                            Label("Inbox: not exported", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        Text(String(format: "weight %g", sound.weight))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Stepper("Weight", value: event.sounds[index].weight, in: 0.5...10, step: 0.5)
                            .labelsHidden()
                            .help("Higher weight is picked more often")
                        Button("Play", systemImage: "play.fill") {
                            var single = event.wrappedValue
                            single.sounds = [sound]
                            Task { await auditioner.audition(key, single, library: library) }
                        }
                        .labelStyle(.iconOnly)
                        Button("Remove", systemImage: "minus.circle") { event.wrappedValue.sounds.remove(at: index) }
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                }
                Menu("Add Sound", systemImage: "plus") {
                    let grouped = Dictionary(grouping: projectSounds.filter { !event.wrappedValue.sounds.map(\.path).contains($0) }) {
                        ($0 as NSString).deletingLastPathComponent
                    }
                    ForEach(grouped.keys.sorted(), id: \.self) { folder in
                        Menu(folder.isEmpty ? "Project root" : folder) {
                            ForEach(grouped[folder]!.sorted(), id: \.self) { path in
                                Button((path as NSString).lastPathComponent) { event.wrappedValue.sounds.append(EventSound(path: path)) }
                            }
                        }
                    }
                }
                .fixedSize()
            } header: {
                Text("Sounds")
            } footer: {
                Text("One sound is picked per play. Higher weight means picked more often.")
            }
            .dropDestination(for: URL.self) { urls, _ in
                let paths = urls.compactMap { library.relativePath($0) }.filter { Library.audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
                event.wrappedValue.sounds += paths.filter { path in !event.wrappedValue.sounds.contains { $0.path == path } }.map { EventSound(path: $0) }
                return !paths.isEmpty
            }

            Section("Playback") {
                Picker("Pick", selection: event.playback) {
                    ForEach(EventPlayback.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                eventSlider("Random pitch", value: event.pitchSemitones, in: 0...12, step: 0.5, format: "±%.1f st")
                eventSlider("Volume", value: event.volumeDb, in: -30...6, step: 0.5, format: "%+.1f dB")
                eventSlider("Random volume", value: event.volumeRandomDb, in: 0...12, step: 0.5, format: "-0 to -%.1f dB")
                HStack {
                    Button("Audition", systemImage: "play.fill") { Task { await auditioner.audition(key, event.wrappedValue, library: library) } }
                    Button("Audition ×6", systemImage: "play.square.stack") { Task { await auditioner.audition(key, event.wrappedValue, library: library, hits: 6) } }
                    if auditioner.loading { ProgressView().controlSize(.small) }
                    if let error = auditioner.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
                }
                .disabled(event.wrappedValue.sounds.isEmpty)
            }

            Section {
                Picker("Bus", selection: event.bus) {
                    Text("Master").tag("Master")
                    ForEach(library.config.mixBuses) { bus in
                        Text(String(repeating: "    ", count: bus.depth) + bus.name).tag(bus.path)
                    }
                }
                Stepper(value: event.maxInstances, in: 0...32) {
                    LabeledContent("Max instances", value: event.wrappedValue.maxInstances == 0 ? "Unlimited" : "\(event.wrappedValue.maxInstances)")
                }
                eventSlider("Cooldown", value: event.cooldownMs, in: 0...1000, step: 10, format: "%.0f ms")
            } header: {
                Text("Routing and limits")
            } footer: {
                Text("When too many instances play, the oldest stops. Cooldown ignores triggers that come too fast (e.g. footsteps).")
            }

            Section {
                Toggle("Positional (3D)", isOn: Binding(
                    get: { event.wrappedValue.spatial != nil },
                    set: { event.wrappedValue.spatial = $0 ? (event.wrappedValue.spatial ?? SpatialSettings()) : nil }
                ))
                if event.wrappedValue.spatial != nil {
                    let spatial = Binding(get: { event.wrappedValue.spatial ?? SpatialSettings() }, set: { event.wrappedValue.spatial = $0 })
                    Picker("Falloff", selection: spatial.attenuation) {
                        ForEach(Attenuation.allCases) { Text($0.title).tag($0) }
                    }
                    eventSlider("Full volume within", value: spatial.unitSize, in: 1...50, step: 1, format: "%.0f units")
                    eventSlider("Silent beyond", value: spatial.maxDistance, in: 0...500, step: 5, format: "%.0f units (0 = no limit)")
                }
            } header: {
                Text("3D")
            } footer: {
                Text("Exported to AudioStreamPlayer3D in Godot and a PannerNode (HRTF) on the web.")
            }

            Section("Use it in the game") {
                let spatial = event.wrappedValue.spatial != nil
                LabeledContent("Godot") {
                    Text(spatial ? "Sounds.play(\"\(key)\", $AudioStreamPlayer3D)" : "Sounds.play(\"\(key)\", $AudioStreamPlayer)")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Web") {
                    Text(spatial ? "engine.play('\(key)', { position: [x, y, z] })" : "engine.play('\(key)')")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func eventSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, format: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step)
                Text(String(format: format, value.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 150, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
