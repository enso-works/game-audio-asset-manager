import AppKit

/// One keyboard shortcut. The same table drives key handling and the cheat sheet.
struct KeyBinding: Identifiable {
    enum Key: Equatable {
        case character(String)
        case code(UInt16)
    }

    let id = UUID()
    let keys: [Key]
    let modifiers: NSEvent.ModifierFlags
    let label: String
    let title: String
    let group: String
    /// Nil for shortcuts handled by the menu (listed for reference only).
    let action: (@MainActor (EditorModel) -> Void)?

    func matches(_ event: NSEvent, modifiers eventModifiers: NSEvent.ModifierFlags) -> Bool {
        guard action != nil, eventModifiers == modifiers else { return false }
        let character = event.charactersIgnoringModifiers?.lowercased() ?? ""
        return keys.contains { key in
            switch key {
            case .character(let value): value == character
            case .code(let code): code == event.keyCode
            }
        }
    }
}

enum KeyCommands {
    private static let space: UInt16 = 49, delete: UInt16 = 51, forwardDelete: UInt16 = 117, escape: UInt16 = 53
    private static let returnKey: UInt16 = 36, home: UInt16 = 115, end: UInt16 = 119, left: UInt16 = 123, right: UInt16 = 124

    private static func bind(
        _ keys: [KeyBinding.Key], _ modifiers: NSEvent.ModifierFlags = [], _ label: String, _ title: String, _ group: String,
        _ action: (@MainActor (EditorModel) -> Void)?
    ) -> KeyBinding {
        KeyBinding(keys: keys, modifiers: modifiers, label: label, title: title, group: group, action: action)
    }

    private static func char(_ value: String) -> [KeyBinding.Key] { [.character(value)] }

    static let groups = ["Playback", "Selection", "Edit", "Process", "Regions & Loops", "Game & View"]

    @MainActor
    static let bindings: [KeyBinding] = [
        // Playback
        bind([.code(space)], [], "Space", "Play / stop", "Playback") { $0.togglePlay() },
        bind(char("l"), [], "L", "Toggle loop playback", "Playback") { $0.loopPlayback.toggle() },
        bind([.code(escape)], [], "Esc", "Stop, then clear selection", "Playback") { editor in
            if editor.player.isPlaying { editor.stop() } else { editor.selection = nil }
        },
        bind([.code(returnKey), .code(home)], [], "Return", "Cursor to start", "Playback") { $0.seek(to: 0) },
        bind([.code(end)], [], "End", "Cursor to end", "Playback") { $0.seek(to: $0.frameCount) },
        bind([.code(left)], [], "←", "Cursor back 100 ms", "Playback") { $0.nudgeCursor(milliseconds: -100) },
        bind([.code(right)], [], "→", "Cursor forward 100 ms", "Playback") { $0.nudgeCursor(milliseconds: 100) },
        bind([.code(left)], [.shift], "Shift ←", "Cursor back 1 s", "Playback") { $0.nudgeCursor(milliseconds: -1000) },
        bind([.code(right)], [.shift], "Shift →", "Cursor forward 1 s", "Playback") { $0.nudgeCursor(milliseconds: 1000) },

        // Selection
        bind(char("a"), [.command], "Cmd A", "Select all", "Selection") { $0.selectAll() },
        bind(char("["), [], "[", "Selection start at playhead / cursor", "Selection") { $0.markSelectionStart() },
        bind(char("]"), [], "]", "Selection end at playhead / cursor", "Selection") { $0.markSelectionEnd() },
        bind(char(","), [], ",", "Select previous region", "Selection") { $0.selectAdjacentRegion(forward: false) },
        bind(char("."), [], ".", "Select next region", "Selection") { $0.selectAdjacentRegion(forward: true) },

        // Edit
        bind(char("c") + [.code(delete), .code(forwardDelete)], [], "C / Delete", "Cut the selection out", "Edit") { $0.deleteSelection() },
        bind(char("t"), [], "T", "Trim to selection", "Edit") { $0.trimToSelection() },
        bind(char("t"), [.shift], "Shift T", "Trim silence at both ends", "Edit") { $0.trimSilence() },
        bind(char("s"), [], "S", "Silence the selection", "Edit") { $0.silenceSelection() },
        bind(char("c"), [.command], "Cmd C", "Copy audio", "Edit") { $0.copySelection() },
        bind(char("x"), [.command], "Cmd X", "Cut audio to clipboard", "Edit") { $0.cutSelection() },
        bind(char("v"), [.command], "Cmd V", "Paste at cursor or over selection", "Edit") { $0.paste() },
        bind([], [.command], "Cmd Z", "Undo (Shift Cmd Z redo)", "Edit", nil),
        bind([], [.command], "Cmd S", "Save (Shift Cmd S: Save As)", "Edit", nil),

        // Process
        bind(char("i"), [], "I", "Fade in", "Process") { $0.fadeIn() },
        bind(char("o"), [], "O", "Fade out", "Process") { $0.fadeOut() },
        bind(char("n"), [], "N", "Normalize to -1 dB", "Process") { $0.normalize() },
        bind(char("="), [], "=", "Louder by gain step", "Process") { $0.applyGain($0.gainStepDb) },
        bind(char("-"), [], "-", "Quieter by gain step", "Process") { $0.applyGain(-$0.gainStepDb) },
        bind(char("v"), [], "V", "Reverse", "Process") { $0.reverse() },
        bind(char("b"), [], "B", "Low cut (bass)", "Process") { $0.applyFilter(.lowCut) },
        bind(char("h"), [], "H", "High cut", "Process") { $0.applyFilter(.highCut) },

        // Regions & loops
        bind(char("r"), [], "R", "Add region from selection", "Regions & Loops") { $0.addRegion() },
        bind(char("r"), [.shift], "Shift R", "Auto-split by silence", "Regions & Loops") { $0.showAutoSplit = true },
        bind(char("k"), [], "K", "Set loop from selection", "Regions & Loops") { $0.setLoopFromSelection() },
        bind(char("k"), [.shift], "Shift K", "Clear loop", "Regions & Loops") { $0.clearLoop() },
        bind(char("p"), [], "P", "Play loop", "Regions & Loops") { $0.playLoop() },
        bind(char("p"), [.shift], "Shift P", "Play intro, then loop", "Regions & Loops") { $0.playLoop(withIntro: true) },
        bind(char("j"), [], "J", "Hear the loop seam", "Regions & Loops") { $0.auditionSeam() },
        bind(char("z"), [], "Z", "Snap loop to zero crossings", "Regions & Loops") { $0.snapLoopToZeroCrossings() },
        bind(char("m"), [], "M", "Make loop seamless", "Regions & Loops") { $0.makeSeamlessLoop() },

        // Game & view
        bind(char("g"), [], "G", "Game preview (random pitch)", "Game & View") { $0.playGamePreview() },
        bind(char("g"), [.shift], "Shift G", "Pitch variations...", "Game & View") { $0.showVariations = true },
        bind(char("w"), [], "W", "Waveform / spectrogram / both", "Game & View") { $0.cycleViewMode() },
        bind([], [.command], "Cmd = - 0", "Zoom in / out / fit", "Game & View", nil),
        bind(char("/") + char("?"), [.shift], "?", "Show keyboard shortcuts", "Game & View") { $0.showShortcuts = true },
        bind([], [.command], "Cmd E", "Export (Shift Cmd E: project)", "Game & View", nil),
    ]

    /// Handles single-key editor shortcuts, except while typing in a text field or when a sheet is open.
    @MainActor
    static func handle(_ event: NSEvent, editor: EditorModel) -> Bool {
        guard editor.clip != nil,
              let window = event.window,
              window.sheetParent == nil, window.attachedSheet == nil,
              !(window.firstResponder is NSText)
        else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let binding = bindings.first(where: { $0.matches(event, modifiers: modifiers) }) else { return false }
        binding.action?(editor)
        return true
    }
}
