import AppKit
import SwiftUI

/// Preset buttons plus format, channels, rate and quality pickers. Lives inside a Form section.
struct ExportSettingsEditor: View {
    @Binding var settings: ExportSettings

    var body: some View {
        HStack {
            ForEach(ExportPreset.allCases) { preset in
                Button(preset.title) { settings = settings.applying(preset) }
                    .buttonStyle(.bordered)
                    .tint(settings.preset == preset ? .accentColor : nil)
            }
        }
        Picker("Format", selection: $settings.format) {
            ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        Picker("Channels", selection: $settings.channels) {
            Text("Keep").tag(0)
            Text("Mono").tag(1)
            Text("Stereo").tag(2)
        }
        .pickerStyle(.segmented)
        Picker("Sample rate", selection: $settings.sampleRate) {
            Text("Keep").tag(0)
            Text("22.05 kHz").tag(22050)
            Text("44.1 kHz").tag(44100)
            Text("48 kHz").tag(48000)
        }
        switch settings.format {
        case .wav:
            Picker("Bit depth", selection: $settings.wavBitDepth) {
                Text("16-bit").tag(16)
                Text("24-bit").tag(24)
            }
        case .ogg:
            Picker("Quality", selection: $settings.oggQuality) {
                ForEach([3, 4, 5, 6, 7, 8, 10], id: \.self) { Text("q\($0) (~\(Self.oggKbps($0)) kbps)").tag($0) }
            }
        case .mp3:
            Picker("Bitrate", selection: $settings.mp3Bitrate) {
                ForEach([96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
            }
        }
        Picker("Loudness", selection: $settings.loudness) {
            Text("Off").tag(Double?.none)
            ForEach([-12.0, -14, -16, -18, -20, -23], id: \.self) { Text(String(format: "%g LUFS", $0)).tag(Double?.some($0)) }
        }
        .help("Match every sound to the same perceived loudness. Around -16 LUFS for SFX, -20 for music and ambience.")
        Text(settings.preset?.note ?? "Custom settings.")
            .font(.caption)
            .foregroundStyle(.secondary)
        if settings.loudness != nil {
            Text("Loudness is measured per sound (EBU R128) and matched with a fixed gain, so dynamics stay intact. Peaks are capped at -1 dBTP to avoid clipping.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func oggKbps(_ quality: Int) -> Int {
        [3: 112, 4: 128, 5: 160, 6: 192, 7: 224, 8: 256, 10: 500][quality] ?? 0
    }
}

/// Shows a folder's effective export format and lets you pick a preset, inherit, or customize.
struct FolderSettingsControl: View {
    @Environment(Library.self) private var library
    let folder: URL
    @State private var editingCustom = false

    var body: some View {
        let own = library.ownSettings(forFolder: folder)
        let isRoot = library.relativePath(folder) == ""
        HStack(spacing: 8) {
            Text(library.settings(forFolder: folder).summary)
                .foregroundStyle(own == nil ? .secondary : .primary)
                .lineLimit(1)
            Menu(own == nil ? "Inherited" : own?.preset?.title ?? "Custom") {
                if !isRoot {
                    Button("Inherit from Parent Folder") { library.setSettings(nil, forFolder: folder) }
                    Divider()
                }
                ForEach(ExportPreset.allCases) { preset in
                    Button(preset.title) {
                        library.setSettings(library.settings(forFolder: folder).applying(preset), forFolder: folder)
                    }
                }
                Divider()
                Button("Custom...") { editingCustom = true }
            }
            .fixedSize()
            .popover(isPresented: $editingCustom, arrowEdge: .trailing) {
                Form {
                    Section(library.displayName(forFolder: folder)) {
                        ExportSettingsEditor(settings: Binding(
                            get: { library.settings(forFolder: folder) },
                            set: { library.setSettings($0, forFolder: folder) }
                        ))
                    }
                }
                .formStyle(.grouped)
                .frame(width: 520)
            }
        }
    }
}

/// A folder path with a Choose button.
struct FolderField: View {
    let url: URL?
    var placeholder = "Not set"
    let choose: (URL) -> Void

    var body: some View {
        HStack {
            Text(url?.path(percentEncoded: false) ?? placeholder)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Button("Choose...") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.directoryURL = url
                panel.prompt = "Use Folder"
                if panel.runModal() == .OK, let picked = panel.url { choose(picked) }
            }
        }
    }
}
