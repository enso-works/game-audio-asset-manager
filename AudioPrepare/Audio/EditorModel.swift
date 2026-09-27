import AppKit
import Observation

enum WaveformViewMode: String, CaseIterable, Identifiable {
    case waveform, spectrogram, split
    var id: Self { self }

    var title: String {
        switch self {
        case .waveform: "Waveform"
        case .spectrogram: "Spectrogram"
        case .split: "Both"
        }
    }

    var icon: String {
        switch self {
        case .waveform: "waveform"
        case .spectrogram: "chart.bar.doc.horizontal"
        case .split: "rectangle.split.1x2"
        }
    }
}

struct Region: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var start: Int
    var end: Int
    var colorIndex: Int

    var range: Range<Int> { start..<end }
}

@MainActor
@Observable
final class EditorModel {
    private(set) var url: URL?
    private(set) var clip: AudioClip?
    private(set) var peaks = Peaks()
    private(set) var version = 0
    /// Revision ids: any change bumps `revision`, sample changes also bump `audioRevision`.
    /// Comparing against the saved ids means undoing back to the saved state counts as clean.
    private(set) var revision = 0
    private(set) var audioRevision = 0
    private(set) var savedRevision = 0
    private(set) var savedAudioRevision = 0
    private(set) var regions: [Region] = [] {
        didSet { updateSelectionFlags() }
    }
    /// Loop points in frames; exported as WAV loop markers and in the manifest.
    private(set) var loop: Range<Int>?
    private(set) var spectrogram: Spectrogram?
    private(set) var viewMode = WaveformViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .waveform
    /// Sounds found by auto-split, shown on the waveform before they become regions.
    var splitPreview: [Range<Int>] = []
    /// Tempo and downbeat for music; drives the beat grid and bar-length loops.
    private(set) var tempo: TempoInfo?
    var showBeatGrid = true
    /// Where the sound came from (YouTube link, title, channel), shown for attribution.
    private(set) var source: SoundMeta?
    private(set) var viewStart: Double = 0
    private(set) var viewLength: Double = 1
    private(set) var isLoading = false
    private(set) var isBusy = false
    /// Changes on every mouse move while dragging; views that only care whether something is
    /// selected read `hasSelection` / `selectedRegionID`, which change far less often.
    var selection: Range<Int>? {
        didSet { updateSelectionFlags() }
    }
    private(set) var hasSelection = false
    private(set) var selectedRegionID: Region.ID?
    var cursor = 0
    var errorMessage: String?
    var loopPlayback = false
    var fadeMs = 100
    var gainStepDb = 3.0
    var loopCrossfadeMs = 250
    var lowCutHz = 120.0
    var highCutHz = 8000.0
    /// Random pitch range (± semitones) for the game preview and variations.
    var pitchSpread = 2.0
    var showVariations = false
    var showAutoSplit = false
    var showTempo = false
    var showDenoise = false
    var showPitchSpeed = false
    var showReverb = false
    var showCompress = false
    /// Background noise learned from a selection; kept across files so one take can clean another.
    private(set) var noiseProfile: NoiseProfile?
    var showShortcuts = false
    /// Copied audio, shared across files so sounds can be combined.
    static var clipboard: AudioClip?
    var showExport = false
    var showSaveAs = false
    var showSaveRegions = false

    let player = Player()
    @ObservationIgnored var undoManager: UndoManager? {
        didSet { updateUndoBudget() }
    }

    /// Each undo step keeps a full copy of the audio, so long files get fewer steps (about 1.5 GB total).
    private func updateUndoBudget() {
        let bytes = max(clip?.byteSize ?? 0, 1)
        undoManager?.levelsOfUndo = min(30, max(5, 1_500_000_000 / bytes))
    }
    @ObservationIgnored weak var library: Library?
    @ObservationIgnored weak var exportService: ExportService?
    @ObservationIgnored private var loadToken = UUID()
    @ObservationIgnored private var regionCounter = 0
    @ObservationIgnored private var revisionCounter = 0
    @ObservationIgnored private var loopDragStart: Snapshot?
    @ObservationIgnored private var spectrogramStale = true
    @ObservationIgnored private var spectrogramToken = UUID()

    init() {
        player.onTick = { [weak self] position in self?.follow(position) }
    }

    var fileName: String { url?.deletingPathExtension().lastPathComponent ?? "" }
    var isDirty: Bool { revision != savedRevision }
    var audioDirty: Bool { audioRevision != savedAudioRevision }
    var frameCount: Int { clip?.frameCount ?? 0 }
    var sampleRate: Double { clip?.sampleRate ?? 44100 }
    private func updateSelectionFlags() {
        let has = selection.map { !$0.isEmpty } ?? false
        if has != hasSelection { hasSelection = has }
        let region = selection.flatMap { range in regions.first { $0.range == range }?.id }
        if region != selectedRegionID { selectedRegionID = region }
    }

    /// Target of processing ops: the selection, or the whole file when nothing is selected.
    var editRange: Range<Int> {
        if let selection, !selection.isEmpty { return selection }
        return 0..<frameCount
    }

    // MARK: - Loading

    func open(_ url: URL) async {
        guard url != self.url else { return }
        player.stop()
        let token = UUID()
        loadToken = token
        isLoading = true
        errorMessage = nil
        do {
            let clip = try await AudioDecoder.load(url)
            let peaks = await Task.detached(priority: .userInitiated) { Peaks(clip: clip) }.value
            guard token == loadToken else { return }
            self.url = url
            self.clip = clip
            self.peaks = peaks
            version += 1
            selection = nil
            cursor = 0
            let meta = library?.meta(for: url) ?? SoundMeta()
            source = meta.hasSource ? meta.sourceOnly : nil
            tempo = meta.tempo
            regions = (meta.regions ?? []).filter { $0.end <= clip.frameCount && $0.start < $0.end }
            regionCounter = regions.count
            loop = meta.loop.flatMap { points in
                let start = Int((points.start * clip.sampleRate).rounded())
                let end = min(Int((points.end * clip.sampleRate).rounded()), clip.frameCount)
                return end > start ? start..<end : nil
            }
            markSaved()
            zoomToFit()
            invalidateSpectrogram()
            undoManager?.removeAllActions(withTarget: self)
            updateUndoBudget()
        } catch {
            guard token == loadToken else { return }
            close()
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func close() {
        player.stop()
        url = nil
        clip = nil
        peaks = Peaks()
        regions = []
        loop = nil
        tempo = nil
        source = nil
        selection = nil
        markSaved()
        version += 1
        undoManager?.removeAllActions(withTarget: self)
    }

    func discardChanges() {
        markSaved()
    }

    /// Follows a file that was moved or renamed in the library.
    func fileMoved(from old: URL, to new: URL) {
        guard let url else { return }
        if url == old {
            self.url = new
        } else if url.path.hasPrefix(old.path + "/") {
            self.url = URL(fileURLWithPath: new.path + url.path.dropFirst(old.path.count))
        }
    }

    private func markSaved() {
        savedRevision = revision
        savedAudioRevision = audioRevision
    }

    private func nextRevision() -> Int {
        revisionCounter += 1
        return revisionCounter
    }

    enum SaveResult {
        case saved(URL)
        case needsSaveAs
        case failed
    }

    /// Saves in place when possible: metadata only if the samples are untouched, or overwriting
    /// a WAV that lives in a project folder. Anything else needs Save As.
    func save() async -> SaveResult {
        guard let url, let clip, let library else { return .failed }
        guard library.contains(url) else { return .needsSaveAs }
        if !audioDirty {
            persistMeta(for: url)
            markSaved()
            exportService?.autoExportIfEnabled()
            return .saved(url)
        }
        guard url.pathExtension.lowercased() == "wav", !library.isInInbox(url) else { return .needsSaveAs }
        do {
            try await write(clip, to: url)
            persistMeta(for: url)
            markSaved()
            library.refresh()
            exportService?.autoExportIfEnabled()
            return .saved(url)
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
            return .failed
        }
    }

    /// Writes the edited sound as a WAV into a project folder. Source info and edit data go with it.
    func saveAs(in folder: URL, name: String, removeOriginal: Bool) async -> URL? {
        guard let url, let clip, let library else { return nil }
        let base = Library.cleanName(name).isEmpty ? fileName : Library.cleanName(name)
        var destination = folder.appendingPathComponent(base).appendingPathExtension("wav")
        if destination.standardizedFileURL != url.standardizedFileURL {
            destination = library.uniqueURL(in: folder, base: base, ext: "wav")
        }
        let source = library.meta(for: url)
        do {
            try await write(clip, to: destination)
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
            return nil
        }
        library.updateMeta(for: destination) { $0 = source.sourceOnly }
        persistMeta(for: destination)
        if removeOriginal, destination.standardizedFileURL != url.standardizedFileURL {
            library.trash(url)
        }
        self.url = destination
        markSaved()
        library.refresh()
        exportService?.autoExportIfEnabled()
        return destination
    }

    /// Writes every region as its own WAV, e.g. to split a sound pack into single sounds.
    func saveRegionsAsSounds(in folder: URL, prefix: String) async -> [URL] {
        guard let url, let clip, let library else { return [] }
        let source = library.meta(for: url).sourceOnly
        var results: [URL] = []
        for region in regions {
            let destination = library.uniqueURL(in: folder, base: Library.cleanName(prefix + region.name), ext: "wav")
            let part = AudioOps.slice(clip, region.range)
            do {
                try await write(part, to: destination)
                if source.hasSource { library.updateMeta(for: destination) { $0 = source } }
                results.append(destination)
            } catch {
                errorMessage = "Save failed: \(error.localizedDescription)"
            }
        }
        library.refresh()
        exportService?.autoExportIfEnabled()
        return results
    }

    private func write(_ clip: AudioClip, to destination: URL) async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try await Task.detached { try clip.writeWAV(to: temp, range: 0..<clip.frameCount) }.value
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: destination)
        }
    }

    private func persistMeta(for url: URL) {
        let regions = self.regions
        let rate = sampleRate
        let loop = self.loop.map { LoopPoints(start: Double($0.lowerBound) / rate, end: Double($0.upperBound) / rate) }
        let tempo = self.tempo
        library?.updateMeta(for: url) { meta in
            meta.regions = regions.isEmpty ? nil : regions
            meta.loop = loop
            meta.tempo = tempo
        }
    }

    // MARK: - Edits

    private struct Snapshot {
        var clip: AudioClip
        var peaks: Peaks
        var regions: [Region]
        var loop: Range<Int>?
        var tempo: TempoInfo?
        var selection: Range<Int>?
        var cursor: Int
        var revision: Int
        var audioRevision: Int
    }

    private func snapshot() -> Snapshot? {
        clip.map {
            Snapshot(clip: $0, peaks: peaks, regions: regions, loop: loop, tempo: tempo, selection: selection, cursor: cursor,
                     revision: revision, audioRevision: audioRevision)
        }
    }

    private func apply(_ snapshot: Snapshot, fit: Bool = false) {
        let wasFit = viewLength >= Double(frameCount) - 1
        let audioChanged = snapshot.audioRevision != audioRevision
        clip = snapshot.clip
        peaks = snapshot.peaks
        regions = snapshot.regions
        loop = snapshot.loop
        tempo = snapshot.tempo
        selection = snapshot.selection
        cursor = min(snapshot.cursor, snapshot.clip.frameCount)
        revision = snapshot.revision
        audioRevision = snapshot.audioRevision
        version += 1
        if fit || wasFit { zoomToFit() } else { setView(start: viewStart, length: viewLength) }
        if audioChanged {
            invalidateSpectrogram()
            updateUndoBudget()
        }
    }

    // MARK: - Spectrogram

    func setViewMode(_ mode: WaveformViewMode) {
        viewMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "viewMode")
        refreshSpectrogramIfNeeded()
    }

    func cycleViewMode() {
        let all = WaveformViewMode.allCases
        setViewMode(all[(all.firstIndex(of: viewMode)! + 1) % all.count])
    }

    private func invalidateSpectrogram() {
        spectrogramStale = true
        spectrogram = nil
        refreshSpectrogramIfNeeded()
    }

    /// Computes the spectrogram in the background, only while it is shown.
    private func refreshSpectrogramIfNeeded() {
        guard viewMode != .waveform, spectrogramStale, let clip else { return }
        spectrogramStale = false
        let token = UUID()
        spectrogramToken = token
        Task {
            let result = await Task.detached(priority: .utility) { Spectrogram(clip: clip) }.value
            guard spectrogramToken == token else { return }
            spectrogram = result
        }
    }

    private func registerUndo(restoring snapshot: Snapshot, name: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restore(snapshot, name: name) }
        }
        undoManager.setActionName(name)
    }

    private func restore(_ snapshot: Snapshot, name: String) {
        guard let current = self.snapshot() else { return }
        player.stop()
        apply(snapshot)
        registerUndo(restoring: current, name: name)
    }

    /// Runs an audio transform off the main thread and registers it for undo.
    private func perform(
        _ name: String,
        fit: Bool = false,
        _ transform: @escaping @Sendable (AudioClip) -> AudioClip,
        update: @escaping (inout Snapshot) -> Void = { _ in }
    ) {
        guard let before = snapshot(), !isBusy else { return }
        player.stop()
        isBusy = true
        let source = before.clip
        Task {
            let (newClip, newPeaks) = await Task.detached(priority: .userInitiated) {
                let result = transform(source)
                return (result, Peaks(clip: result))
            }.value
            var after = before
            after.clip = newClip
            after.peaks = newPeaks
            after.revision = nextRevision()
            after.audioRevision = after.revision
            update(&after)
            apply(after, fit: fit)
            registerUndo(restoring: before, name: name)
            isBusy = false
        }
    }

    /// Records a change that doesn't touch the samples (regions), so it stays in the undo history.
    private func changeRegions(_ name: String, _ change: (inout [Region]) -> Void) {
        guard let before = snapshot() else { return }
        change(&regions)
        regions.sort { $0.start < $1.start }
        revision = nextRevision()
        registerUndo(restoring: before, name: name)
    }

    func trimToSelection() {
        guard let range = selection, !range.isEmpty, range.count < frameCount else { return }
        perform("Trim", fit: true, { AudioOps.slice($0, range) }) { s in
            s.regions = RegionMath.afterTrim(s.regions, to: range)
            s.loop = RegionMath.trim(s.loop, to: range)
            s.tempo = s.tempo?.shifted(by: -Double(range.lowerBound) / s.clip.sampleRate)
            s.selection = nil
            s.cursor = 0
        }
    }

    func deleteSelection() {
        guard let range = selection, !range.isEmpty, range.count < frameCount else { return }
        perform("Delete", { AudioOps.delete($0, range) }) { s in
            s.regions = RegionMath.afterDelete(s.regions, range)
            s.loop = RegionMath.delete(s.loop, range)
            s.selection = nil
            s.cursor = range.lowerBound
        }
    }

    func silenceSelection() {
        guard let range = selection, !range.isEmpty else { return }
        perform("Silence") { AudioOps.silence($0, range) }
    }

    func reverse() {
        let range = editRange
        perform("Reverse") { AudioOps.reverse($0, range) }
    }

    func fadeIn() {
        guard let clip else { return }
        let range = hasSelection ? editRange : 0..<min(clip.frameCount, clip.frames(forMilliseconds: fadeMs))
        perform("Fade In") { AudioOps.fade($0, range, fadeIn: true) }
    }

    func fadeOut() {
        guard let clip else { return }
        let n = clip.frameCount
        let range = hasSelection ? editRange : max(0, n - clip.frames(forMilliseconds: fadeMs))..<n
        perform("Fade Out") { AudioOps.fade($0, range, fadeIn: false) }
    }

    func applyGain(_ db: Double) {
        let range = editRange
        perform(db > 0 ? "Louder" : "Quieter") { AudioOps.gain($0, range, db: db) }
    }

    func applyFilter(_ kind: FilterKind) {
        let range = editRange
        let frequency = kind == .lowCut ? lowCutHz : highCutHz
        perform(kind == .lowCut ? "Low Cut" : "High Cut") { AudioOps.filter($0, range, kind: kind, frequency: frequency) }
    }

    // MARK: - Repair and effects

    /// Learns the selection as background noise for Denoise.
    func learnNoise() {
        guard let clip, let selection, selection.count > Denoiser.fftSize else {
            errorMessage = "Select at least 50 ms of background noise (no wanted sound) first."
            return
        }
        noiseProfile = Denoiser.profile(clip, selection)
    }

    func clearNoiseProfile() {
        noiseProfile = nil
    }

    func denoise(reductionDb: Double, sensitivity: Double) {
        let range = editRange
        let profile = noiseProfile
        perform("Denoise") { Denoiser.denoise($0, range, profile: profile, reductionDb: reductionDb, sensitivity: sensitivity) }
    }

    /// Removes a constant offset with a 10 Hz high-pass (safe for long files, unlike subtracting the mean).
    func removeDC() {
        let range = editRange
        perform("Remove DC") { AudioOps.filter($0, range, kind: .lowCut, frequency: 10) }
    }

    func makeMono() {
        guard let clip, clip.channelCount > 1 else { return }
        perform("Make Mono") { $0.conformed(sampleRate: $0.sampleRate, channelCount: 1) }
    }

    func compress(_ settings: CompressorSettings) {
        let range = editRange
        perform("Compress") { Effects.compress($0, range, settings: settings) }
    }

    func pitchSpeed(semitones: Double, speed: Double, tape: Bool) {
        let range = editRange
        replaceRange("Pitch & Speed", range, stretch: true) { Effects.pitchSpeed($0, range, semitones: semitones, speed: speed, tape: tape) }
    }

    /// Reverb on the selection keeps its length; on the whole sound the tail can extend the file.
    func reverb(preset: ReverbPreset, mix: Double, addTail: Bool) {
        let range = editRange
        let tail = addTail && !hasSelection ? 2.5 : 0
        replaceRange("Reverb", range, stretch: false) { Effects.reverb($0, range, preset: preset, mix: mix, tail: tail) }
    }

    /// Replaces a range with processed audio of possibly different length. Regions, the loop and
    /// the tempo grid follow: stretched with a speed change, shifted after a longer range.
    private func replaceRange(_ name: String, _ range: Range<Int>, stretch: Bool, _ render: @escaping @Sendable (AudioClip) -> AudioClip?) {
        guard let clip else { return }
        let rate = clip.sampleRate
        let source = clip
        let lengthBox = LengthBox()
        perform(name, { source in
            guard let processed = render(source) else { return source }
            lengthBox.value = processed.frameCount
            return AudioOps.replace(source, range, with: processed)
        }) { s in
            let count = lengthBox.value ?? range.count
            guard count != range.count else { return }
            let map = RegionMath.replacing(range, count: count, stretch: stretch)
            s.regions = s.regions.compactMap { region in
                var moved = region
                moved.start = map(region.start)
                moved.end = map(region.end)
                return moved.end > moved.start ? moved : nil
            }
            s.loop = s.loop.flatMap { loop in
                let moved = map(loop.lowerBound)..<map(loop.upperBound)
                return moved.isEmpty ? nil : moved
            }
            // A speed change over the whole sound changes its tempo too.
            if stretch, range == 0..<source.frameCount, let tempo = s.tempo {
                let factor = Double(range.count) / Double(count)
                s.tempo = TempoInfo(bpm: (tempo.bpm * factor * 10).rounded() / 10, offset: tempo.offset / factor, beatsPerBar: tempo.beatsPerBar)
            }
            if s.selection != nil { s.selection = range.lowerBound..<(range.lowerBound + count) }
            _ = rate
        }
    }

    func normalize(targetDb: Double = -1) {
        let range = editRange
        perform("Normalize") { AudioOps.normalize($0, range, targetDb: targetDb) }
    }

    func trimSilence(thresholdDb: Double = -50) {
        guard let clip, let keep = AudioOps.nonSilentRange(clip, thresholdDb: thresholdDb),
              keep != 0..<clip.frameCount
        else { return }
        perform("Trim Silence", fit: true, { AudioOps.slice($0, keep) }) { s in
            s.regions = RegionMath.afterTrim(s.regions, to: keep)
            s.loop = RegionMath.trim(s.loop, to: keep)
            s.tempo = s.tempo?.shifted(by: -Double(keep.lowerBound) / s.clip.sampleRate)
            s.selection = nil
            s.cursor = 0
        }
    }

    // MARK: - Loop

    private func changeLoop(_ name: String, _ newLoop: Range<Int>?) {
        guard let before = snapshot(), newLoop != loop else { return }
        loop = newLoop
        revision = nextRevision()
        registerUndo(restoring: before, name: name)
    }

    func setLoopFromSelection() {
        guard let selection, selection.count > 1 else { return }
        changeLoop("Set Loop", selection)
    }

    func clearLoop() {
        changeLoop("Clear Loop", nil)
    }

    /// Moves both loop points to the nearest rising zero crossing (within 10 ms) to avoid clicks.
    func snapLoopToZeroCrossings() {
        guard let clip, let loop else { return }
        let window = clip.frames(forMilliseconds: 10)
        let start = AudioOps.nearestZeroCrossing(clip, near: loop.lowerBound, window: window)
        let end = AudioOps.nearestZeroCrossing(clip, near: loop.upperBound, window: window)
        guard end > start else { return }
        changeLoop("Snap Loop", start..<end)
    }

    /// Crossfades the loop's tail into its head and trims the file to the loop.
    func makeSeamlessLoop() {
        guard let clip, let loop, loop.count > 4 else { return }
        let fade = min(clip.frames(forMilliseconds: loopCrossfadeMs), loop.count / 2)
        perform("Make Seamless Loop", fit: true, { AudioOps.seamlessLoop($0, loop, crossfade: fade) }) { s in
            s.regions = []
            s.loop = 0..<(loop.count - max(fade, 1))
            s.tempo = s.tempo?.shifted(by: -Double(loop.lowerBound + fade) / s.clip.sampleRate)
            s.selection = nil
            s.cursor = 0
        }
    }

    func trimToLoop() {
        guard let loop, loop.count < frameCount else { return }
        perform("Trim to Loop", fit: true, { AudioOps.slice($0, loop) }) { s in
            s.regions = RegionMath.afterTrim(s.regions, to: loop)
            s.loop = 0..<loop.count
            s.tempo = s.tempo?.shifted(by: -Double(loop.lowerBound) / s.clip.sampleRate)
            s.selection = nil
            s.cursor = 0
        }
    }

    /// Plays the loop forever; with intro, plays from the file start first like the game would.
    func playLoop(withIntro: Bool = false) {
        guard let clip, let loop else { return }
        if withIntro {
            player.playIntroLoop(clip, loop: loop)
        } else {
            player.play(clip, range: loop, loop: true)
        }
    }

    /// Plays the end of the loop straight into its start, to judge the seam.
    func auditionSeam(seconds: Double = 1.5) {
        guard let clip, let loop else { return }
        let side = max(1, min(Int(seconds * clip.sampleRate), loop.count / 2))
        let tail = (loop.upperBound - side)..<loop.upperBound
        let head = loop.lowerBound..<(loop.lowerBound + side)
        let seam = AudioClip(
            channels: clip.channels.map { Array($0[tail]) + Array($0[head]) },
            sampleRate: clip.sampleRate
        )
        player.play(seam, range: 0..<(side * 2), loop: false) { played in
            played < side ? tail.lowerBound + played : head.lowerBound + min(played - side, side)
        }
    }

    // MARK: - Tempo

    private func changeTempo(_ name: String, _ newTempo: TempoInfo?) {
        guard let before = snapshot(), newTempo != tempo else { return }
        tempo = newTempo
        revision = nextRevision()
        registerUndo(restoring: before, name: name)
    }

    /// Detects tempo over the loop, the selection, or the whole sound. Returns false if there's no clear beat.
    @discardableResult
    func detectTempo() -> Bool {
        guard let clip else { return false }
        let range = loop ?? (hasSelection ? editRange : 0..<clip.frameCount)
        guard let detected = TempoDetector.detect(clip, range: range, beatsPerBar: tempo?.beatsPerBar ?? 4) else { return false }
        changeTempo("Detect Tempo", detected)
        return true
    }

    func setBPM(_ bpm: Double) {
        guard bpm >= 20, bpm <= 400 else { return }
        var updated = tempo ?? TempoInfo(bpm: bpm, offset: 0, beatsPerBar: 4)
        updated.bpm = bpm
        changeTempo("Set Tempo", updated)
    }

    func setBeatsPerBar(_ beats: Int) {
        guard var updated = tempo else { return }
        updated.beatsPerBar = beats
        changeTempo("Set Meter", updated)
    }

    func setDownbeatAtCursor() {
        guard var updated = tempo else { return }
        updated.offset = Double(player.isPlaying ? player.position : cursor) / sampleRate
        changeTempo("Set Downbeat", updated)
    }

    func clearTempo() {
        changeTempo("Clear Tempo", nil)
    }

    var loopBars: Double? {
        guard let loop, let tempo else { return nil }
        return Double(loop.count) / sampleRate / tempo.barSeconds
    }

    /// Moves the loop start to the nearest downbeat and makes the loop a whole number of bars.
    func snapLoopToBars() {
        guard let loop, let bars = loopBars else { return }
        setLoopBars(max(1, Int(bars.rounded())), from: loop.lowerBound)
    }

    /// Sets the loop to `bars` bars starting at the downbeat nearest to `frame` (loop start or cursor).
    func setLoopBars(_ bars: Int, from frame: Int? = nil) {
        guard let tempo, bars > 0, frameCount > 0 else { return }
        let rate = sampleRate
        let anchor = Double(frame ?? loop?.lowerBound ?? cursor) / rate
        var start = tempo.nearestBeat(to: anchor, bars: true)
        if start < 0 { start += tempo.barSeconds }
        var count = bars
        while count > 1 && start + Double(count) * tempo.barSeconds > Double(frameCount) / rate { count -= 1 }
        let startFrame = Int((start * rate).rounded())
        let endFrame = min(frameCount, Int(((start + Double(count) * tempo.barSeconds) * rate).rounded()))
        guard endFrame > startFrame else { return }
        changeLoop("Loop \(count) Bars", startFrame..<endFrame)
    }

    func beginLoopDrag() {
        loopDragStart = snapshot()
    }

    func dragLoop(to range: Range<Int>) {
        guard range.count > 1 else { return }
        loop = range
    }

    func endLoopDrag() {
        guard let before = loopDragStart else { return }
        loopDragStart = nil
        guard before.loop != loop else { return }
        revision = nextRevision()
        registerUndo(restoring: before, name: "Move Loop")
    }

    // MARK: - Regions

    func addRegion() {
        guard let range = selection, !range.isEmpty else { return }
        regionCounter += 1
        let region = Region(
            id: UUID(),
            name: String(format: "clip_%02d", regionCounter),
            start: range.lowerBound,
            end: range.upperBound,
            colorIndex: regionCounter - 1
        )
        changeRegions("Add Region") { $0.append(region) }
    }

    /// Turns detected sounds into regions named prefix_01, prefix_02, ...
    func createRegions(from ranges: [Range<Int>], prefix: String, replace: Bool) {
        guard !ranges.isEmpty else { return }
        let base = Exporter.sanitize(prefix.isEmpty ? "sound" : prefix)
        let start = replace ? 0 : regions.count
        let new = ranges.enumerated().map { index, range in
            Region(id: UUID(), name: String(format: "%@_%02d", base, start + index + 1),
                   start: range.lowerBound, end: range.upperBound, colorIndex: start + index)
        }
        regionCounter = start + new.count
        changeRegions("Auto-Split") { regions in
            if replace { regions.removeAll() }
            regions.append(contentsOf: new)
        }
        splitPreview = []
    }

    func renameRegion(_ id: Region.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        changeRegions("Rename Region") { regions in
            if let i = regions.firstIndex(where: { $0.id == id }) { regions[i].name = trimmed }
        }
    }

    func removeRegion(_ id: Region.ID) {
        changeRegions("Remove Region") { $0.removeAll { $0.id == id } }
    }

    func removeAllRegions() {
        guard !regions.isEmpty else { return }
        changeRegions("Remove Regions") { $0.removeAll() }
    }

    func selectRegion(_ region: Region) {
        selection = region.range
        cursor = region.start
        if Double(region.start) < viewStart || Double(region.end) > viewStart + viewLength {
            zoomToSelection()
        }
    }

    // MARK: - Playback

    func togglePlay() {
        if player.isPlaying { player.stop() } else { play() }
    }

    func play() {
        guard let clip else { return }
        let range: Range<Int>
        if let selection, !selection.isEmpty {
            range = selection
        } else {
            let start = cursor >= clip.frameCount ? 0 : cursor
            range = start..<clip.frameCount
        }
        player.play(clip, range: range, loop: loopPlayback)
    }

    /// Plays the selection (or whole sound) 6 times with random pitch and volume, like a game would.
    func playGamePreview() {
        guard let clip else { return }
        player.playGamePreview(clip, range: editRange, hits: 6, semitones: pitchSpread, volumeJitterDb: 2, gap: 0.25)
    }

    /// Evenly spaced pitch offsets, e.g. 5 variants at ±2 semitones -> -2, -1, 0, +1, +2.
    static func variationPitches(count: Int, spread: Double) -> [Double] {
        guard count > 1 else { return [0] }
        return (0..<count).map { -spread + 2 * spread * Double($0) / Double(count - 1) }
    }

    /// Renders pitched copies of the selection (or whole sound) into a project folder with ffmpeg.
    /// Pitch changes speed too (like a game engine), unless keepLength time-stretches it back.
    func saveVariations(in folder: URL, name: String, count: Int, keepLength: Bool) async -> [URL] {
        guard let url, let clip, let library, let ffmpeg = Tools.ffmpeg else { return [] }
        let range = editRange
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try await Task.detached { try clip.writeWAV(to: temp, range: range) }.value
        } catch {
            errorMessage = "Variations failed: \(error.localizedDescription)"
            return []
        }
        let source = library.meta(for: url).sourceOnly
        let base = Library.cleanName(name).isEmpty ? Exporter.sanitize(fileName) : Library.cleanName(name)
        let rate = Int(clip.sampleRate)
        var results: [URL] = []
        for (index, pitch) in Self.variationPitches(count: count, spread: pitchSpread).enumerated() {
            let ratio = pow(2, pitch / 12)
            var filters = ["asetrate=\(Double(rate) * ratio)", "aresample=\(rate)"]
            if keepLength { filters.append("atempo=\(1 / ratio)") }
            let destination = library.uniqueURL(in: folder, base: String(format: "%@_%02d", base, index + 1), ext: "wav")
            let log = LogTail()
            let status = try? await ProcessRunner().run(
                ffmpeg, ["-y", "-v", "error", "-i", temp.path, "-af", filters.joined(separator: ","), "-c:a", "pcm_f32le", destination.path]
            ) { log.append($0) }
            guard status == 0 else {
                errorMessage = "Variation \(index + 1) failed: \(log.text)"
                continue
            }
            if source.hasSource { library.updateMeta(for: destination) { $0 = source } }
            results.append(destination)
        }
        library.refresh()
        exportService?.autoExportIfEnabled()
        return results
    }

    // MARK: - Clipboard

    func copySelection() {
        guard let clip, let selection, !selection.isEmpty else { return }
        Self.clipboard = AudioOps.slice(clip, selection)
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    /// Inserts the clipboard at the cursor, or replaces the selection. Converts rate and channels to match.
    func paste() {
        guard let clip, let copied = Self.clipboard?.conformed(sampleRate: clip.sampleRate, channelCount: clip.channelCount),
              copied.frameCount > 0
        else { return }
        let replaced = hasSelection ? selection! : cursor..<cursor
        let count = copied.frameCount
        perform("Paste", { AudioOps.replace($0, replaced, with: copied) }) { s in
            s.regions = RegionMath.afterDelete(s.regions, replaced).compactMap { RegionMath.insert($0, at: replaced.lowerBound, count: count) }
            s.loop = RegionMath.delete(s.loop, replaced).map { RegionMath.insert($0, at: replaced.lowerBound, count: count) }
            s.selection = replaced.lowerBound..<(replaced.lowerBound + count)
            s.cursor = replaced.lowerBound
        }
    }

    // MARK: - Cursor and selection keys

    func nudgeCursor(milliseconds: Int) {
        guard let clip else { return }
        let base = player.isPlaying ? player.position : cursor
        seek(to: base + clip.frames(forMilliseconds: milliseconds))
        let c = Double(cursor)
        if c < viewStart || c > viewStart + viewLength { center(on: c) }
    }

    /// The playhead while playing (to mark on the fly), otherwise the cursor.
    private var markPosition: Int { player.isPlaying ? player.position : cursor }

    func markSelectionStart() {
        let start = markPosition
        let end = selection.map { max($0.upperBound, start + 1) } ?? frameCount
        selection = start < end ? start..<min(end, frameCount) : nil
    }

    func markSelectionEnd() {
        let end = markPosition
        let start = selection.map { min($0.lowerBound, end - 1) } ?? cursor
        selection = start < end ? max(0, start)..<end : nil
    }

    func selectAdjacentRegion(forward: Bool) {
        guard !regions.isEmpty else { return }
        let anchor = selection?.lowerBound ?? cursor
        let target = forward
            ? regions.first { $0.start > anchor } ?? regions.first!
            : regions.last { $0.start < anchor } ?? regions.last!
        selectRegion(target)
    }

    func playRegion(_ region: Region) {
        selection = region.range
        play()
    }

    func seek(to frame: Int) {
        cursor = min(max(frame, 0), frameCount)
        if player.isPlaying { play() }
    }

    func stop() {
        player.stop()
    }

    func selectAll() {
        guard frameCount > 0 else { return }
        selection = 0..<frameCount
    }

    // MARK: - View

    func setView(start: Double, length: Double) {
        let n = Double(max(frameCount, 1))
        let len = min(max(length, min(32, n)), n)
        viewLength = len
        viewStart = min(max(start, 0), n - len)
    }

    func zoom(by factor: Double, around frame: Double) {
        let n = Double(max(frameCount, 1))
        let ratio = (frame - viewStart) / viewLength
        let newLength = min(max(viewLength / factor, min(32, n)), n)
        setView(start: frame - ratio * newLength, length: newLength)
    }

    private var zoomAnchor: Double {
        if let selection, !selection.isEmpty { return Double(selection.lowerBound + selection.count / 2) }
        let c = Double(cursor)
        if c >= viewStart && c <= viewStart + viewLength { return c }
        return viewStart + viewLength / 2
    }

    func zoomIn() { zoom(by: 2, around: zoomAnchor) }
    func zoomOut() { zoom(by: 0.5, around: zoomAnchor) }
    func zoomToFit() { setView(start: 0, length: Double(frameCount)) }

    func zoomToSelection() {
        guard let selection, !selection.isEmpty else { return }
        let pad = Double(selection.count) * 0.05
        setView(start: Double(selection.lowerBound) - pad, length: Double(selection.count) + pad * 2)
    }

    func pan(by frames: Double) {
        setView(start: viewStart + frames, length: viewLength)
    }

    func center(on frame: Double) {
        setView(start: frame - viewLength / 2, length: viewLength)
    }

    /// Pages the view along with the playhead during playback.
    private func follow(_ position: Int) {
        let p = Double(position)
        guard viewLength < Double(frameCount), p < viewStart || p > viewStart + viewLength else { return }
        setView(start: p - viewLength * 0.05, length: viewLength)
    }
}

/// Carries the processed length out of the background transform.
private final class LengthBox: @unchecked Sendable {
    var value: Int?
}
