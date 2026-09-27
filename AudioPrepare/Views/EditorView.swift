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
            // Position read-outs change on every drag event and 30 times a second during playback.
            // GeometryReader sizes itself from the proposal, not its content, so these updates never
            // trigger a layout pass for the rest of the window.
            GeometryReader { geometry in
                positions(labels: geometry.size.width > 380, lengths: geometry.size.width > 560)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: 20)
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
        .truncationMode(.head)
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
            row("Repair") { repairButtons }
            row("Effects") { effectButtons }
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

    /// A labeled row of buttons that wraps onto a second line when the pane is too narrow.
    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary).frame(width: 52, height: 22, alignment: .leading)
            FlowLayout(spacing: 8, lineSpacing: 6) { content() }
                .labelStyle(CompactLabelStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var cutButtons: some View {
        Group {
            ToolButton(.trim) { editor.trimToSelection() }
            ToolButton(.cut) { editor.deleteSelection() }
            ToolButton(.silence) { editor.silenceSelection() }
            ToolButton(.addRegion) { editor.addRegion() }
        }
        .disabled(!editor.hasSelection)
        ToolButton(.trimSilence) { editor.trimSilence() }
    }

    @ViewBuilder private var processButtons: some View {
        @Bindable var editor = editor
        ToolButton(.fadeIn) { editor.fadeIn() }
        ToolButton(.fadeOut) { editor.fadeOut() }
        Picker("Fade", selection: $editor.fadeMs) {
            ForEach([10, 25, 50, 100, 250, 500, 1000, 2000], id: \.self) { Text("\($0) ms").tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .toolTip(.fadeLength)
        ToolButton(.quieter) { editor.applyGain(-editor.gainStepDb) }
        ToolButton(.louder) { editor.applyGain(editor.gainStepDb) }
        Picker("Gain", selection: $editor.gainStepDb) {
            ForEach([1.0, 3.0, 6.0, 12.0], id: \.self) { Text("\(Int($0)) dB").tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .toolTip(.gainStep)
        ToolButton(.normalize) { editor.normalize() }
        ToolButton(.reverse) { editor.reverse() }
    }

    @ViewBuilder private var repairButtons: some View {
        @Bindable var editor = editor
        ToolButton(.lowCut) { editor.applyFilter(.lowCut) }
        Picker("Low cut frequency", selection: $editor.lowCutHz) {
            ForEach([40.0, 80, 120, 200, 400, 800], id: \.self) { Text(Self.hertz($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .toolTip(.lowCutFrequency)
        ToolButton(.highCut) { editor.applyFilter(.highCut) }
        Picker("High cut frequency", selection: $editor.highCutHz) {
            ForEach([2000.0, 4000, 6000, 8000, 12000, 16000], id: \.self) { Text(Self.hertz($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .toolTip(.highCutFrequency)
        ToolButton(.denoise) { editor.showDenoise = true }
            .popover(isPresented: $editor.showDenoise, arrowEdge: .bottom) { DenoisePopover() }
        ToolButton(.removeDC) { editor.removeDC() }
        ToolButton(.mono) { editor.makeMono() }
            .disabled((editor.clip?.channelCount ?? 1) < 2)
    }

    @ViewBuilder private var effectButtons: some View {
        @Bindable var editor = editor
        ToolButton(.pitchSpeed) { editor.showPitchSpeed = true }
            .popover(isPresented: $editor.showPitchSpeed, arrowEdge: .bottom) { PitchSpeedPopover() }
        ToolButton(.reverb) { editor.showReverb = true }
            .popover(isPresented: $editor.showReverb, arrowEdge: .bottom) { ReverbPopover() }
        ToolButton(.compress) { editor.showCompress = true }
            .popover(isPresented: $editor.showCompress, arrowEdge: .bottom) { CompressPopover() }
    }

    @ViewBuilder private var gameButtons: some View {
        @Bindable var editor = editor
        ToolButton(.preview) { editor.playGamePreview() }
        Picker("Pitch spread", selection: $editor.pitchSpread) {
            ForEach([0.5, 1, 2, 3, 5], id: \.self) { Text(String(format: "±%g st", $0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .toolTip(.pitchSpread)
        ToolButton(.variations) { editor.showVariations = true }
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
        ToolButton(.setLoop) { editor.setLoopFromSelection() }
            .disabled(!editor.hasSelection)
        Group {
            ToolButton(.playLoop) { editor.playLoop() }
            ToolButton(.seam) { editor.auditionSeam() }
            ToolButton(.snap) { editor.snapLoopToZeroCrossings() }
            ToolButton(.seamless) { editor.makeSeamlessLoop() }
            Picker("Crossfade", selection: $editor.loopCrossfadeMs) {
                ForEach([10, 50, 100, 250, 500, 1000, 2000], id: \.self) { Text("\($0) ms").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .toolTip(.crossfade)
            ToolButton(.trimToLoop) { editor.trimToLoop() }
            ToolButton(.clearLoop) { editor.clearLoop() }
        }
        .disabled(editor.loop == nil)
        ToolButton(.tempo, title: editor.tempo.map { String(format: "%g BPM", $0.bpm) }) { editor.showTempo = true }
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
                ToolButton(.autoSplit) { editor.showAutoSplit = true }
                    .popover(isPresented: $editor.showAutoSplit, arrowEdge: .bottom) { AutoSplitPopover() }
                if !editor.regions.isEmpty {
                    ToolButton(.saveRegions) { editor.showSaveRegions = true }
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
        let selected = editor.selectedRegionID == region.id
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

// MARK: - Repair and effect popovers

/// Shared footer: what the tool will process and an Apply button.
private struct ApplyFooter: View {
    @Environment(EditorModel.self) private var editor
    let title: String
    let action: () -> Void

    var body: some View {
        HStack {
            Text(editor.hasSelection ? "Applies to the selection." : "Applies to the whole sound.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct DenoisePopover: View {
    @Environment(EditorModel.self) private var editor
    @AppStorage("denoiseReduction") private var reduction = 18.0
    @AppStorage("denoiseSensitivity") private var sensitivity = 1.5

    var body: some View {
        Form {
            Section {
                HStack {
                    if let profile = editor.noiseProfile {
                        Label(String(format: "Learned noise (%.1f s)", profile.seconds), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Forget") { editor.clearNoiseProfile() }
                    } else {
                        Label("Automatic: uses the quietest parts", systemImage: "sparkles")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                Button("Learn Noise from Selection", systemImage: EditorTool.learnNoise.icon) { editor.learnNoise() }
                    .disabled(!editor.hasSelection)
                    .toolTip(.learnNoise)
            } header: {
                Text("Denoise")
            } footer: {
                Text("For the best result, select a moment with only background noise and learn it first.")
            }
            Section {
                slider("Reduction", value: $reduction, in: 6...36, step: 1, format: "%.0f dB")
                slider("Sensitivity", value: $sensitivity, in: 1...3, step: 0.1, format: "%.1f×")
                Text("Higher sensitivity removes more noise but can make the sound dull or watery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ApplyFooter(title: "Denoise") {
                    editor.denoise(reductionDb: reduction, sensitivity: sensitivity)
                    editor.showDenoise = false
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
    }
}

private struct PitchSpeedPopover: View {
    @Environment(EditorModel.self) private var editor
    @State private var semitones = 0.0
    @State private var speed = 1.0
    @State private var tape = false

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $tape) {
                    Text("Independent").tag(false)
                    Text("Tape").tag(true)
                }
                .pickerStyle(.segmented)
                if !tape {
                    slider("Pitch", value: $semitones, in: -12...12, step: 0.5, format: "%+.1f st")
                }
                slider("Speed", value: $speed, in: 0.5...2, step: 0.05, format: "%.2f×")
                if let clip = editor.clip {
                    let seconds = Double(editor.hasSelection ? editor.editRange.count : clip.frameCount) / clip.sampleRate
                    Text(String(format: "Length %.2f s → %.2f s", seconds, seconds / speed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Pitch & Speed")
            } footer: {
                Text(tape ? "Tape: pitch and speed change together, like Godot's pitch_scale." : "Independent: change pitch without changing length, or length without changing pitch.")
            }
            Section {
                HStack {
                    Button("Reset") {
                        semitones = 0
                        speed = 1
                    }
                    Spacer()
                }
                ApplyFooter(title: "Apply") {
                    editor.pitchSpeed(semitones: tape ? 0 : semitones, speed: speed, tape: tape)
                    editor.showPitchSpeed = false
                }
                .disabled(speed == 1 && (tape || semitones == 0))
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
    }
}

private struct ReverbPopover: View {
    @Environment(EditorModel.self) private var editor
    @AppStorage("reverbPreset") private var preset: ReverbPreset = .mediumRoom
    @AppStorage("reverbMix") private var mix = 25.0
    @AppStorage("reverbTail") private var addTail = true

    var body: some View {
        Form {
            Section {
                Picker("Space", selection: $preset) {
                    ForEach(ReverbPreset.allCases) { Text($0.title).tag($0) }
                }
                slider("Wet", value: $mix, in: 0...100, step: 1, format: "%.0f%%")
                Toggle("Add a 2.5 s tail so the decay isn't cut", isOn: $addTail)
                    .disabled(editor.hasSelection)
            } header: {
                Text("Reverb")
            } footer: {
                Text(editor.hasSelection ? "On a selection the length stays the same, so the tail is cut at the selection end." : "Small rooms suit footsteps and UI; halls and cathedrals suit impacts, magic and music.")
            }
            Section {
                ApplyFooter(title: "Add Reverb") {
                    editor.reverb(preset: preset, mix: mix, addTail: addTail)
                    editor.showReverb = false
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
    }
}

private struct CompressPopover: View {
    @Environment(EditorModel.self) private var editor
    @State private var settings = CompressorSettings.punchy

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Gentle") { settings = .gentle }
                    Button("Punchy") { settings = .punchy }
                    Button("Limiter") { settings = .limiter }
                }
                .buttonStyle(.bordered)
                slider("Threshold", value: $settings.thresholdDb, in: -40...0, step: 1, format: "%.0f dB")
                slider("Ratio", value: $settings.ratio, in: 1...20, step: 0.5, format: "%.1f:1")
                slider("Attack", value: $settings.attackMs, in: 0.5...100, step: 0.5, format: "%.1f ms")
                slider("Release", value: $settings.releaseMs, in: 10...1000, step: 10, format: "%.0f ms")
                slider("Makeup", value: $settings.makeupDb, in: 0...18, step: 0.5, format: "%+.1f dB")
            } header: {
                Text("Compress")
            } footer: {
                Text("Parts louder than the threshold are turned down by the ratio; makeup gain brings the whole sound back up. Follow with Normalize to avoid clipping.")
            }
            Section {
                ApplyFooter(title: "Compress") {
                    editor.compress(settings)
                    editor.showCompress = false
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}

private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, format: String) -> some View {
    LabeledContent(title) {
        HStack {
            Slider(value: value, in: range, step: step)
            Text(String(format: format, value.wrappedValue))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
    }
}
