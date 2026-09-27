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
                    if let source = editor.source { SourceLine(source: source) }
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
        .sheet(isPresented: $editor.showVariations) { VariationsView() }
        .sheet(isPresented: $editor.showShortcuts) { ShortcutsView() }
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

            Picker("View", selection: Binding(get: { editor.viewMode }, set: { editor.setViewMode($0) })) {
                ForEach(WaveformViewMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Waveform, spectrogram or both (W)")

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
        HStack(spacing: 14) {
            if let clip = editor.clip {
                Text(formatTime(clip.duration))
                    .font(.headline.monospacedDigit())
                Text("\(Int(clip.sampleRate)) Hz · \(clip.channelCount == 1 ? "Mono" : "Stereo")")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if editor.isDirty {
                Text("Unsaved")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.2), in: Capsule())
            }
            if editor.isBusy { ProgressView().controlSize(.small) }
            if let error = editor.player.outputError {
                Label(error, systemImage: "speaker.slash.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(error)
                    .onTapGesture { editor.player.clearOutputError() }
            }
            Spacer(minLength: 8)
            // Drops lengths first, then labels, when the pane is narrow.
            ViewThatFits(in: .horizontal) {
                positions(labels: true, lengths: true)
                positions(labels: true, lengths: false)
                positions(labels: false, lengths: false)
            }
            .font(.callout.monospacedDigit())
        }
    }

    private func positions(labels: Bool, lengths: Bool) -> some View {
        let rate = editor.sampleRate
        func span(_ range: Range<Int>) -> String {
            let text = "\(formatTime(Double(range.lowerBound) / rate))–\(formatTime(Double(range.upperBound) / rate))"
            return lengths ? text + String(format: " (%.3f s)", Double(range.count) / rate) : text
        }
        return HStack(spacing: 12) {
            if editor.player.isPlaying {
                Text((labels ? "Playing " : "▶ ") + formatTime(Double(editor.player.position) / rate))
            }
            if let loop = editor.loop {
                Text((labels ? "Loop " : "⟳ ") + span(loop)).foregroundStyle(.green)
            }
            Text((labels ? "Cursor " : "") + formatTime(Double(editor.cursor) / rate))
            if let selection = editor.selection, !selection.isEmpty {
                Text((labels ? "Selection " : "") + span(selection)).foregroundStyle(Color.accentColor)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

private struct SourceLine: View {
    let source: SoundMeta

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "link").foregroundStyle(.secondary)
            Text(description).lineLimit(1).truncationMode(.tail)
            if let link = source.sourceURL.flatMap(URL.init(string:)) {
                Link("Open", destination: link)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var description: String {
        var text = "Source: \"\(source.sourceTitle ?? source.sourceURL ?? "")\""
        if let channel = source.sourceChannel { text += " by \(channel)" }
        if let range = source.sourceRange { text += " (\(range))" }
        return text
    }
}

private struct WaveformPanel: View {
    @Environment(EditorModel.self) private var editor

    var body: some View {
        VStack(spacing: 6) {
            WaveformView(model: editor, mode: .overview)
                .frame(height: 44)
            WaveformView(model: editor, mode: .main)
                .frame(minHeight: 220)
        }
    }
}

private struct EditBar: View {
    @Environment(EditorModel.self) private var editor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Cut") { cutButtons }
            row("Process") { processButtons }
            row("Filter") { filterButtons }
            row("Loop") { loopButtons }
            row("Game") { gameButtons }
            HStack {
                Text(editor.hasSelection ? "Processing applies to the selection." : "Nothing selected: processing applies to the whole file.")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Drag to select · Shift-click extends · Double-click selects all · Scroll to zoom")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(editor.isBusy)
    }

    /// A labeled row of buttons that falls back to icons only when the pane is too narrow.
    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        let buttons = content()
        return HStack(spacing: 8) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }.labelStyle(CompactLabelStyle())
                HStack(spacing: 6) { buttons }.labelStyle(.iconOnly)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var cutButtons: some View {
        Group {
            Button("Trim to Selection", systemImage: "crop") { editor.trimToSelection() }
                .help("Keep only the selected part (T)")
            Button("Delete", systemImage: "scissors") { editor.deleteSelection() }
                .help("Cut the selected part out (C or Delete)")
            Button("Silence", systemImage: "speaker.slash") { editor.silenceSelection() }
                .help("Replace the selection with silence (S)")
            Button("Add Region", systemImage: "flag") { editor.addRegion() }
                .help("Mark the selection as a region to export as its own file (R)")
        }
        .disabled(!editor.hasSelection)
        Button("Trim Silence", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") { editor.trimSilence() }
            .help("Remove silence (below -50 dB) from start and end (Shift T)")
    }

    @ViewBuilder private var processButtons: some View {
        @Bindable var editor = editor
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
        Button("Quieter", systemImage: "speaker.wave.1") { editor.applyGain(-editor.gainStepDb) }
            .help("Lower the volume by the gain step (-)")
        Button("Louder", systemImage: "speaker.wave.3") { editor.applyGain(editor.gainStepDb) }
            .help("Raise the volume by the gain step (=)")
        Picker("Gain", selection: $editor.gainStepDb) {
            ForEach([1.0, 3.0, 6.0, 12.0], id: \.self) { Text("\(Int($0)) dB").tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .help("Gain step")
        Button("Normalize", systemImage: "waveform.badge.plus") { editor.normalize() }
            .help("Raise peak to -1 dBFS (N)")
        Button("Reverse", systemImage: "arrow.uturn.left") { editor.reverse() }
            .help("Reverse the selection or the whole file (V)")
    }

    @ViewBuilder private var filterButtons: some View {
        @Bindable var editor = editor
        Button("Low Cut", systemImage: "line.diagonal.arrow") { editor.applyFilter(.lowCut) }
            .help("Remove rumble and hum below the frequency, 24 dB/octave (B)")
        Picker("Low cut frequency", selection: $editor.lowCutHz) {
            ForEach([40.0, 80, 120, 200, 400, 800], id: \.self) { Text(Self.hertz($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        Button("High Cut", systemImage: "line.diagonal") { editor.applyFilter(.highCut) }
            .help("Remove hiss and harshness above the frequency, 24 dB/octave (H)")
        Picker("High cut frequency", selection: $editor.highCutHz) {
            ForEach([2000.0, 4000, 6000, 8000, 12000, 16000], id: \.self) { Text(Self.hertz($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder private var gameButtons: some View {
        @Bindable var editor = editor
        Button("Preview", systemImage: "gamecontroller") { editor.playGamePreview() }
            .help("Play it 6 times with random pitch and volume, like the game would (G)")
        Picker("Pitch spread", selection: $editor.pitchSpread) {
            ForEach([0.5, 1, 2, 3, 5], id: \.self) { Text(String(format: "±%g st", $0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .help("Random pitch range in semitones")
        Button("Variations...", systemImage: "square.stack.3d.up") { editor.showVariations = true }
            .help("Save several pitched copies (jump_01, jump_02, ...) into a project folder (Shift G)")
        if let pitch = editor.player.previewPitch {
            Text(String(format: "%+.1f st", pitch))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private static func hertz(_ value: Double) -> String {
        value >= 1000 ? String(format: "%g kHz", value / 1000) : "\(Int(value)) Hz"
    }

    @ViewBuilder private var loopButtons: some View {
        @Bindable var editor = editor
        Button("Set", systemImage: "repeat") { editor.setLoopFromSelection() }
            .disabled(!editor.hasSelection)
            .help("Use the selection as loop start and end (K)")
        Group {
            Button("Play", systemImage: "repeat.circle") { editor.playLoop() }
                .help("Repeat the loop (P). Shift P plays the intro first, like the game.")
            Button("Seam", systemImage: "ear") { editor.auditionSeam() }
                .help("Play the end of the loop into its start to check the join (J)")
            Button("Snap", systemImage: "scope") { editor.snapLoopToZeroCrossings() }
                .help("Move loop points to the nearest zero crossing to avoid clicks (Z)")
            Button("Seamless", systemImage: "infinity") { editor.makeSeamlessLoop() }
                .help("Crossfade the loop end into its start and trim the file to the loop (M)")
            Picker("Crossfade", selection: $editor.loopCrossfadeMs) {
                ForEach([10, 50, 100, 250, 500, 1000, 2000], id: \.self) { Text("\($0) ms").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Crossfade length for Make Seamless")
            Button("Trim", systemImage: "crop") { editor.trimToLoop() }
                .help("Cut everything outside the loop")
            Button("Clear", systemImage: "xmark") { editor.clearLoop() }
                .help("Remove the loop points (Shift K)")
        }
        .disabled(editor.loop == nil)
        Button(editor.tempo.map { String(format: "%g BPM", $0.bpm) } ?? "Tempo", systemImage: "metronome") { editor.showTempo = true }
            .help("Detect BPM, show a beat grid, and make loops a whole number of bars")
            .popover(isPresented: $editor.showTempo, arrowEdge: .bottom) { TempoPopover() }
    }
}

private struct RegionsPanel: View {
    @Environment(EditorModel.self) private var editor
    @State private var renaming: Region?
    @State private var newName = ""

    var body: some View {
        @Bindable var editor = editor
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Regions").font(.headline)
                Text("Each region exports as its own file")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Auto-Split...", systemImage: "wand.and.rays") { editor.showAutoSplit = true }
                    .help("Find separate sounds by silence and turn them into regions (Shift R)")
                    .popover(isPresented: $editor.showAutoSplit, arrowEdge: .bottom) { AutoSplitPopover() }
                if !editor.regions.isEmpty {
                    Button("Save as Sounds...", systemImage: "square.split.2x1") { editor.showSaveRegions = true }
                        .help("Save each region as its own WAV in a project folder")
                    Button("Remove All", role: .destructive) { editor.removeAllRegions() }
                }
            }
            .controlSize(.small)
            if editor.regions.isEmpty {
                Text("Select a sound in the waveform and press R to mark it, or use Auto-Split to find every sound in a pack. Then save them as separate sounds or export them all at once.")
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

/// Detects sounds separated by silence, previews them on the waveform, then creates regions.
private struct AutoSplitPopover: View {
    @Environment(EditorModel.self) private var editor
    @AppStorage("splitThreshold") private var threshold = -40.0
    @AppStorage("splitMinSilence") private var minSilence = 150.0
    @AppStorage("splitMinSound") private var minSound = 60.0
    @AppStorage("splitPadding") private var padding = 20.0
    @State private var prefix = "sound"
    @State private var replace = true

    var body: some View {
        Form {
            Section {
                slider("Threshold", value: $threshold, in: -70 ... -15, step: 1, unit: "dB",
                       help: "Anything quieter counts as silence")
                slider("Min silence", value: $minSilence, in: 30...1500, step: 10, unit: "ms",
                       help: "Shorter gaps stay inside one sound")
                slider("Min sound", value: $minSound, in: 10...1000, step: 10, unit: "ms",
                       help: "Shorter blips are ignored")
                slider("Padding", value: $padding, in: 0...300, step: 5, unit: "ms",
                       help: "Extra room kept before and after each sound")
            } header: {
                Text("Auto-Split")
            } footer: {
                Text("Found \(editor.splitPreview.count) sound\(editor.splitPreview.count == 1 ? "" : "s"), outlined in yellow on the waveform.")
            }
            Section {
                TextField("Name prefix", text: $prefix)
                Toggle("Replace existing regions", isOn: $replace)
                Button("Create \(editor.splitPreview.count) Regions") {
                    editor.createRegions(from: editor.splitPreview, prefix: prefix, replace: replace)
                }
                .buttonStyle(.borderedProminent)
                .disabled(editor.splitPreview.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear {
            prefix = Exporter.sanitize(editor.fileName).split(separator: "_").prefix(2).joined(separator: "_")
            detect()
        }
        .onDisappear { editor.splitPreview = [] }
        .onChange(of: threshold) { detect() }
        .onChange(of: minSilence) { detect() }
        .onChange(of: minSound) { detect() }
        .onChange(of: padding) { detect() }
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, unit: String, help: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step)
                Text("\(Int(value.wrappedValue)) \(unit)")
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }
        }
        .help(help)
    }

    private func detect() {
        guard let clip = editor.clip else { return }
        editor.splitPreview = AudioOps.detectSounds(
            clip, thresholdDb: threshold, minSilenceMs: Int(minSilence), minSoundMs: Int(minSound), paddingMs: Int(padding)
        )
    }
}

/// Tempo tools for music loops: detect BPM, beat grid, and bar-length loops.
private struct TempoPopover: View {
    @Environment(EditorModel.self) private var editor
    @State private var bpmText = ""
    @State private var message: String?
    @State private var bars = 4

    var body: some View {
        @Bindable var editor = editor
        Form {
            Section {
                HStack {
                    TextField("BPM", text: $bpmText, prompt: Text("BPM"))
                        .frame(width: 90)
                        .onSubmit(applyBPM)
                    Button("Set", action: applyBPM)
                        .disabled(Double(bpmText) == nil)
                    Spacer()
                    Button("Detect", systemImage: "waveform.badge.magnifyingglass") {
                        message = editor.detectTempo() ? nil : "No clear beat found. Type the BPM instead."
                        bpmText = editor.tempo.map { String(format: "%g", $0.bpm) } ?? bpmText
                    }
                    .help("Analyzes the loop, the selection, or the whole sound")
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                if let tempo = editor.tempo {
                    Picker("Beats per bar", selection: Binding(get: { tempo.beatsPerBar }, set: { editor.setBeatsPerBar($0) })) {
                        ForEach([2, 3, 4, 6, 8], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Toggle("Show beat grid", isOn: $editor.showBeatGrid)
                    HStack {
                        Text(String(format: "Beat %.3f s · Bar %.3f s", tempo.beatSeconds, tempo.barSeconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Downbeat at Cursor") { editor.setDownbeatAtCursor() }
                            .help("Move the grid so a bar starts at the cursor (or playhead)")
                    }
                }
            } header: {
                Text("Tempo")
            }

            if editor.tempo != nil {
                Section {
                    if let loopBars = editor.loopBars {
                        LabeledContent("Current loop", value: String(format: "%.2f bars", loopBars))
                        Button("Snap Loop to Whole Bars") { editor.snapLoopToBars() }
                            .help("Start on the nearest downbeat and round the length to whole bars")
                    }
                    HStack {
                        Stepper("\(bars) bar\(bars == 1 ? "" : "s")", value: $bars, in: 1...64)
                        Spacer()
                        Button("Set Loop") { editor.setLoopBars(bars) }
                            .help("Loop this many bars from the downbeat nearest the loop start or cursor")
                    }
                } header: {
                    Text("Loop in bars")
                } footer: {
                    Text("Loops that are whole bars repeat in time with the music. Use Make Seamless afterwards if the join clicks.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onAppear { bpmText = editor.tempo.map { String(format: "%g", $0.bpm) } ?? "" }
    }

    private func applyBPM() {
        guard let bpm = Double(bpmText.replacingOccurrences(of: ",", with: ".")) else { return }
        editor.setBPM(bpm)
        message = nil
    }
}
