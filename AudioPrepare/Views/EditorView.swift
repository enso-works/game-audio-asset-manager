import AppKit
import SwiftUI

struct EditorView: View {
    @Environment(EditorModel.self) private var editor
    @Environment(\.undoManager) private var undoManager
    @State private var keyMonitor: Any?

    var body: some View {
        @Bindable var editor = editor
        Group {
            if editor.isLoading {
                ProgressView("Loading audio...")
            } else if editor.clip != nil {
                VStack(alignment: .leading, spacing: 10) {
                    InfoBar()
                    WaveformPanel()
                    EditBar()
                    RegionsPanel()
                }
                .padding(12)
            } else if let error = editor.errorMessage {
                ContentUnavailableView("Could not open file", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ContentUnavailableView("No file open", systemImage: "waveform", description: Text("Pick a file from the library."))
            }
        }
        .navigationTitle(editor.fileName.isEmpty ? "Editor" : editor.fileName)
        .toolbar { EditorToolbar() }
        .sheet(isPresented: $editor.showExport) { ExportView() }
        .sheet(isPresented: $editor.showSaveAs) { SaveAsView() }
        .sheet(isPresented: $editor.showSaveRegions) { SaveRegionsView() }
        .onAppear {
            editor.undoManager = undoManager
            installKeyMonitor()
        }
        .onChange(of: undoManager) { _, manager in editor.undoManager = manager }
        .onDisappear(perform: removeKeyMonitor)
    }

    /// Single-key shortcuts that must not fire while typing in a text field.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let editor = editor
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors always run on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { KeyCommands.handle(event, editor: editor) }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

enum KeyCommands {
    @MainActor
    static func handle(_ event: NSEvent, editor: EditorModel) -> Bool {
        guard editor.clip != nil,
              let window = event.window,
              window.sheetParent == nil, window.attachedSheet == nil,
              !(window.firstResponder is NSText)
        else { return false }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if modifiers == [.command] && key == "a" {
            editor.selectAll()
            return true
        }
        guard modifiers.isEmpty || modifiers == [.shift] else { return false }

        switch event.keyCode {
        case 49: editor.togglePlay()                          // space
        case 51, 117: editor.deleteSelection()                // delete, forward delete
        case 53:                                              // escape
            if editor.player.isPlaying { editor.stop() } else { editor.selection = nil }
        case 36, 115: editor.seek(to: 0)                      // return, home
        default:
            switch key {
            case "r": editor.addRegion()
            case "l": editor.loopPlayback.toggle()
            case "t": editor.trimToSelection()
            case "i": editor.fadeIn()
            case "o": editor.fadeOut()
            case "n": editor.normalize()
            default: return false
            }
        }
        return true
    }
}

private struct EditorToolbar: ToolbarContent {
    @Environment(EditorModel.self) private var editor

    var body: some ToolbarContent {
        @Bindable var editor = editor
        ToolbarItemGroup(placement: .primaryAction) {
            Button(editor.player.isPlaying ? "Stop" : "Play", systemImage: editor.player.isPlaying ? "stop.fill" : "play.fill") {
                editor.togglePlay()
            }
            .help("Play / Stop (Space)")

            Toggle(isOn: $editor.loopPlayback) {
                Label("Loop", systemImage: "repeat")
            }
            .help("Loop playback (L)")

            Button("Zoom Out", systemImage: "minus.magnifyingglass") { editor.zoomOut() }
                .help("Zoom out (Cmd -)")
            Button("Zoom In", systemImage: "plus.magnifyingglass") { editor.zoomIn() }
                .help("Zoom in (Cmd =)")
            Button("Zoom to Fit", systemImage: "arrow.left.and.right") { editor.zoomToFit() }
                .help("Show whole file (Cmd 0)")

            Button("Export", systemImage: "square.and.arrow.up") { editor.showExport = true }
                .help("Export for your game (Cmd E)")
        }
    }
}

private struct InfoBar: View {
    @Environment(EditorModel.self) private var editor

    var body: some View {
        let rate = editor.sampleRate
        HStack(spacing: 14) {
            if let clip = editor.clip {
                Text(formatTime(clip.duration))
                    .font(.headline.monospacedDigit())
                Text("\(Int(clip.sampleRate)) Hz · \(clip.channelCount == 1 ? "Mono" : "Stereo")")
                    .foregroundStyle(.secondary)
            }
            if editor.isDirty {
                Text("Unsaved edits")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.2), in: Capsule())
            }
            if editor.isBusy { ProgressView().controlSize(.small) }
            Spacer()
            Group {
                if editor.player.isPlaying {
                    Text("Playing \(formatTime(Double(editor.player.position) / rate))")
                }
                Text("Cursor \(formatTime(Double(editor.cursor) / rate))")
                if let selection = editor.selection, !selection.isEmpty {
                    Text("Selection \(formatTime(Double(selection.lowerBound) / rate)) – \(formatTime(Double(selection.upperBound) / rate)) (\(String(format: "%.3f", Double(selection.count) / rate)) s)")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .font(.callout.monospacedDigit())
        }
    }
}

private struct WaveformPanel: View {
    @Environment(EditorModel.self) private var editor

    var body: some View {
        let state = WaveformDrawState(
            version: editor.version,
            selection: editor.selection,
            cursor: editor.cursor,
            playhead: editor.player.isPlaying ? editor.player.position : nil,
            viewStart: editor.viewStart,
            viewLength: editor.viewLength,
            regions: editor.regions
        )
        VStack(spacing: 6) {
            WaveformView(model: editor, mode: .overview, state: state)
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            WaveformView(model: editor, mode: .main, state: state)
                .frame(minHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct EditBar: View {
    @Environment(EditorModel.self) private var editor

    var body: some View {
        @Bindable var editor = editor
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Cut").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                Group {
                    Button("Trim to Selection", systemImage: "crop") { editor.trimToSelection() }
                        .help("Keep only the selected part (T)")
                    Button("Delete", systemImage: "scissors") { editor.deleteSelection() }
                        .help("Cut the selected part out (Delete)")
                    Button("Silence", systemImage: "speaker.slash") { editor.silenceSelection() }
                        .help("Replace the selection with silence")
                    Button("Add Region", systemImage: "flag") { editor.addRegion() }
                        .help("Mark the selection as a region to export as its own file (R)")
                }
                .disabled(!editor.hasSelection)
                Button("Trim Silence", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") { editor.trimSilence() }
                    .help("Remove silence (below -50 dB) from start and end")
                Spacer()
            }
            HStack(spacing: 8) {
                Text("Process").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                Button("Fade In", systemImage: "arrow.up.right") { editor.fadeIn() }
                    .help("Fade in over the selection, or the start of the file (I)")
                Button("Fade Out", systemImage: "arrow.down.right") { editor.fadeOut() }
                    .help("Fade out over the selection, or the end of the file (O)")
                Picker("Fade", selection: $editor.fadeMs) {
                    ForEach([10, 25, 50, 100, 250, 500, 1000, 2000], id: \.self) { Text("\($0) ms").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Fade length when nothing is selected")
                Divider().frame(height: 18)
                Button("Quieter", systemImage: "speaker.wave.1") { editor.applyGain(-editor.gainStepDb) }
                Button("Louder", systemImage: "speaker.wave.3") { editor.applyGain(editor.gainStepDb) }
                Picker("Gain", selection: $editor.gainStepDb) {
                    ForEach([1.0, 3.0, 6.0, 12.0], id: \.self) { Text("\(Int($0)) dB").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Divider().frame(height: 18)
                Button("Normalize", systemImage: "waveform.badge.plus") { editor.normalize() }
                    .help("Raise peak to -1 dBFS (N)")
                Button("Reverse", systemImage: "arrow.uturn.left") { editor.reverse() }
                Spacer()
            }
            HStack {
                Text(editor.hasSelection ? "Processing applies to the selection." : "Nothing selected: processing applies to the whole file.")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Drag to select · Shift-click extends · Double-click selects all · Scroll to zoom")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(CompactLabelStyle())
        .disabled(editor.isBusy)
    }
}

private struct RegionsPanel: View {
    @Environment(EditorModel.self) private var editor
    @State private var renaming: Region?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Regions").font(.headline)
                Text("Each region exports as its own file")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !editor.regions.isEmpty {
                    Button("Save as Sounds...", systemImage: "square.split.2x1") { editor.showSaveRegions = true }
                        .help("Save each region as its own WAV in a project folder")
                    Button("Remove All", role: .destructive) { editor.removeAllRegions() }
                }
            }
            .controlSize(.small)
            if editor.regions.isEmpty {
                Text("Select a sound in the waveform and press R to mark it. Use this to cut many sounds out of one long recording, then export them all at once.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(editor.regions) { region in
                            row(region)
                        }
                    }
                }
                .frame(maxHeight: 170)
            }
        }
        .alert("Rename Region", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming { editor.renameRegion(renaming.id, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ region: Region) -> some View {
        let rate = editor.sampleRate
        let selected = editor.selection == region.range
        return HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: WaveformNSView.palette[region.colorIndex % WaveformNSView.palette.count]))
                .frame(width: 9, height: 9)
            Text(region.name).fontWeight(.medium)
            Spacer()
            Text("\(formatTime(Double(region.start) / rate))  ·  \(String(format: "%.3f s", Double(region.range.count) / rate))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Play", systemImage: "play.fill") { editor.playRegion(region) }
            Button("Rename", systemImage: "pencil") {
                newName = region.name
                renaming = region
            }
            Button("Remove", systemImage: "trash") { editor.removeRegion(region.id) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { editor.selectRegion(region) }
    }
}

/// Icon plus title that never truncates the title.
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title.fixedSize()
        }
    }
}
