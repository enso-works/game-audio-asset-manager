import SwiftUI

/// Every editor tool with its name, icon and a plain explanation. Buttons, hover cards and the
/// shortcut table all read from here, so they can't drift apart.
enum EditorTool: String, CaseIterable, Identifiable {
    case trim, cut, silence, addRegion, trimSilence
    case fadeIn, fadeOut, fadeLength, quieter, louder, gainStep, normalize, reverse
    case lowCut, lowCutFrequency, highCut, highCutFrequency, denoise, learnNoise, removeDC, mono
    case pitchSpeed, reverb, compress
    case setLoop, playLoop, seam, snap, seamless, crossfade, trimToLoop, clearLoop, tempo
    case preview, pitchSpread, variations
    case autoSplit, saveRegions

    var id: Self { self }

    var title: String {
        switch self {
        case .trim: "Trim to Selection"
        case .cut: "Delete"
        case .silence: "Silence"
        case .addRegion: "Add Region"
        case .trimSilence: "Trim Silence"
        case .fadeIn: "Fade In"
        case .fadeOut: "Fade Out"
        case .fadeLength: "Fade Length"
        case .quieter: "Quieter"
        case .louder: "Louder"
        case .gainStep: "Gain Step"
        case .normalize: "Normalize"
        case .reverse: "Reverse"
        case .lowCut: "Low Cut"
        case .lowCutFrequency: "Low Cut Frequency"
        case .highCut: "High Cut"
        case .highCutFrequency: "High Cut Frequency"
        case .denoise: "Denoise..."
        case .learnNoise: "Learn Noise"
        case .removeDC: "Remove DC"
        case .mono: "Mono"
        case .pitchSpeed: "Pitch & Speed..."
        case .reverb: "Reverb..."
        case .compress: "Compress..."
        case .setLoop: "Set"
        case .playLoop: "Play"
        case .seam: "Seam"
        case .snap: "Snap"
        case .seamless: "Seamless"
        case .crossfade: "Crossfade Length"
        case .trimToLoop: "Trim"
        case .clearLoop: "Clear"
        case .tempo: "Tempo"
        case .preview: "Preview"
        case .pitchSpread: "Pitch Spread"
        case .variations: "Variations..."
        case .autoSplit: "Auto-Split..."
        case .saveRegions: "Save as Sounds..."
        }
    }

    /// Name shown in the hover card (buttons use shorter titles in the loop row).
    var cardTitle: String {
        switch self {
        case .setLoop: "Set Loop"
        case .playLoop: "Play Loop"
        case .seam: "Hear Seam"
        case .snap: "Snap Loop to Zero"
        case .seamless: "Make Seamless Loop"
        case .trimToLoop: "Trim to Loop"
        case .clearLoop: "Clear Loop"
        case .preview: "Game Preview"
        default: title.replacingOccurrences(of: "...", with: "")
        }
    }

    var icon: String {
        switch self {
        case .trim: "crop"
        case .cut: "scissors"
        case .silence: "speaker.slash"
        case .addRegion: "flag"
        case .trimSilence: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .fadeIn: "arrow.up.right"
        case .fadeOut: "arrow.down.right"
        case .fadeLength, .crossfade: "timer"
        case .quieter: "speaker.wave.1"
        case .louder: "speaker.wave.3"
        case .gainStep: "plusminus"
        case .normalize: "waveform.badge.plus"
        case .reverse: "arrow.uturn.left"
        case .lowCut: "line.diagonal.arrow"
        case .highCut: "line.diagonal"
        case .lowCutFrequency, .highCutFrequency: "tuningfork"
        case .denoise: "wand.and.stars"
        case .learnNoise: "ear.badge.waveform"
        case .removeDC: "arrow.up.and.down.and.sparkles"
        case .mono: "circle.circle"
        case .pitchSpeed: "gauge.with.dots.needle.67percent"
        case .reverb: "building.columns"
        case .compress: "rectangle.compress.vertical"
        case .setLoop: "repeat"
        case .playLoop: "repeat.circle"
        case .seam: "ear"
        case .snap: "scope"
        case .seamless: "infinity"
        case .trimToLoop: "crop"
        case .clearLoop: "xmark"
        case .tempo: "metronome"
        case .preview: "gamecontroller"
        case .pitchSpread: "slider.horizontal.3"
        case .variations: "square.stack.3d.up"
        case .autoSplit: "wand.and.rays"
        case .saveRegions: "square.split.2x1"
        }
    }

    var detail: String {
        switch self {
        case .trim: "Keep only the selected part and remove everything else."
        case .cut: "Remove the selected part; the audio after it moves up."
        case .silence: "Replace the selection with silence, keeping the length."
        case .addRegion: "Mark the selection as a region. Regions export as separate files."
        case .trimSilence: "Cut quiet parts (below -50 dB) from the start and end."
        case .fadeIn: "Fade up from silence over the selection, or over the fade length at the start."
        case .fadeOut: "Fade down to silence over the selection, or over the fade length at the end."
        case .fadeLength: "How long fades are when nothing is selected."
        case .quieter: "Lower the volume by the gain step."
        case .louder: "Raise the volume by the gain step. Watch for clipping."
        case .gainStep: "How much Louder and Quieter change the volume."
        case .normalize: "Raise the loudest peak to -1 dBFS without clipping."
        case .reverse: "Play the selection (or the whole sound) backwards."
        case .lowCut: "Remove rumble, wind and hum below the frequency (24 dB/octave)."
        case .lowCutFrequency: "Everything below this frequency is removed by Low Cut."
        case .highCut: "Remove hiss and harshness above the frequency (24 dB/octave)."
        case .highCutFrequency: "Everything above this frequency is removed by High Cut."
        case .denoise: "Reduce steady background noise like hiss, hum or fans. Learn the noise from a quiet part first for the best result."
        case .learnNoise: "Select a part with only background noise, then learn it as the noise profile for Denoise."
        case .removeDC: "Center the waveform on zero. Fixes clicks at cuts caused by a DC offset."
        case .mono: "Mix both channels into one. Game SFX are usually mono."
        case .pitchSpeed: "Change pitch without changing length, speed without changing pitch, or both like a tape."
        case .reverb: "Add room or hall ambience to make a dry sound sit in a space."
        case .compress: "Even out loud and quiet parts so the sound is punchier and consistent."
        case .setLoop: "Use the selection as the loop. It is saved with the sound and exported."
        case .playLoop: "Repeat the loop. With Shift, play the intro first like the game will."
        case .seam: "Play the end of the loop into its start, to hear whether the join clicks."
        case .snap: "Move both loop points to the nearest zero crossing to avoid clicks."
        case .seamless: "Crossfade the loop end into its start and trim the file to the loop."
        case .crossfade: "Length of the crossfade used by Seamless."
        case .trimToLoop: "Remove everything outside the loop."
        case .clearLoop: "Remove the loop points."
        case .tempo: "Detect BPM, show a beat grid and make loops a whole number of bars."
        case .preview: "Play it 6 times with random pitch and volume, the way a game triggers it."
        case .pitchSpread: "Random pitch range for Preview and Variations, in semitones."
        case .variations: "Save pitched copies (jump_01, jump_02, ...) so the game can pick one at random."
        case .autoSplit: "Find separate sounds by the silence between them and turn them into regions."
        case .saveRegions: "Save every region as its own WAV in a project folder."
        }
    }

    /// Keyboard shortcut label, taken from the key binding table.
    @MainActor
    var shortcut: String? {
        KeyCommands.bindings.first { $0.tool == self }?.label
    }
}

/// A bordered tool button with the tool's title, icon and hover card.
struct ToolButton: View {
    let tool: EditorTool
    var title: String?
    let action: () -> Void

    init(_ tool: EditorTool, title: String? = nil, action: @escaping () -> Void) {
        self.tool = tool
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title ?? tool.title, systemImage: tool.icon, action: action)
            .toolTip(tool)
    }
}

extension View {
    /// Shows a card with the tool's name, explanation and shortcut after hovering for a moment.
    func toolTip(_ tool: EditorTool) -> some View {
        modifier(ToolTipModifier(tool: tool))
    }
}

private struct ToolTipModifier: ViewModifier {
    let tool: EditorTool
    @State private var hovering = false
    @State private var shown = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                pending?.cancel()
                if inside {
                    pending = Task {
                        try? await Task.sleep(for: .milliseconds(650))
                        if !Task.isCancelled && hovering { shown = true }
                    }
                } else {
                    shown = false
                }
            }
            .simultaneousGesture(TapGesture().onEnded {
                pending?.cancel()
                shown = false
            })
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                ToolTipCard(tool: tool)
            }
    }
}

private struct ToolTipCard: View {
    let tool: EditorTool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(tool.cardTitle, systemImage: tool.icon)
                    .font(.headline)
                Spacer(minLength: 12)
                if let shortcut = tool.shortcut {
                    Keycap(text: shortcut)
                }
            }
            Text(tool.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
    }
}

struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.monospaced().weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.tertiary, lineWidth: 0.5))
    }
}
