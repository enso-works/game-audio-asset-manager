import AppKit
import Observation

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
    private(set) var regions: [Region] = []
    /// Loop points in frames; exported as WAV loop markers and in the manifest.
    private(set) var loop: Range<Int>?
    /// Where the sound came from (YouTube link, title, channel), shown for attribution.
    private(set) var source: SoundMeta?
    private(set) var viewStart: Double = 0
    private(set) var viewLength: Double = 1
    private(set) var isLoading = false
    private(set) var isBusy = false
    var selection: Range<Int>?
    var cursor = 0
    var errorMessage: String?
    var loopPlayback = false
    var fadeMs = 100
    var gainStepDb = 3.0
    var loopCrossfadeMs = 250
    var lowCutHz = 120.0
    var highCutHz = 8000.0
    var showExport = false
    var showSaveAs = false
    var showSaveRegions = false

    let player = Player()
    @ObservationIgnored var undoManager: UndoManager? {
        didSet { undoManager?.levelsOfUndo = 30 }
    }
    @ObservationIgnored weak var library: Library?
    @ObservationIgnored private var loadToken = UUID()
    @ObservationIgnored private var regionCounter = 0
    @ObservationIgnored private var revisionCounter = 0
    @ObservationIgnored private var loopDragStart: Snapshot?

    init() {
        player.onTick = { [weak self] position in self?.follow(position) }
    }

    var fileName: String { url?.deletingPathExtension().lastPathComponent ?? "" }
    var isDirty: Bool { revision != savedRevision }
    var audioDirty: Bool { audioRevision != savedAudioRevision }
    var frameCount: Int { clip?.frameCount ?? 0 }
    var sampleRate: Double { clip?.sampleRate ?? 44100 }
    var hasSelection: Bool { selection.map { !$0.isEmpty } ?? false }

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
            regions = (meta.regions ?? []).filter { $0.end <= clip.frameCount && $0.start < $0.end }
            regionCounter = regions.count
            loop = meta.loop.flatMap { points in
                let start = Int((points.start * clip.sampleRate).rounded())
                let end = min(Int((points.end * clip.sampleRate).rounded()), clip.frameCount)
                return end > start ? start..<end : nil
            }
            markSaved()
            zoomToFit()
            undoManager?.removeAllActions(withTarget: self)
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
            return .saved(url)
        }
        guard url.pathExtension.lowercased() == "wav", !library.isInInbox(url) else { return .needsSaveAs }
        do {
            try await write(clip, to: url)
            persistMeta(for: url)
            markSaved()
            library.refresh()
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
        library?.updateMeta(for: url) { meta in
            meta.regions = regions.isEmpty ? nil : regions
            meta.loop = loop
        }
    }

    // MARK: - Edits

    private struct Snapshot {
        var clip: AudioClip
        var peaks: Peaks
        var regions: [Region]
        var loop: Range<Int>?
        var selection: Range<Int>?
        var cursor: Int
        var revision: Int
        var audioRevision: Int
    }

    private func snapshot() -> Snapshot? {
        clip.map {
            Snapshot(clip: $0, peaks: peaks, regions: regions, loop: loop, selection: selection, cursor: cursor,
                     revision: revision, audioRevision: audioRevision)
        }
    }

    private func apply(_ snapshot: Snapshot, fit: Bool = false) {
        let wasFit = viewLength >= Double(frameCount) - 1
        clip = snapshot.clip
        peaks = snapshot.peaks
        regions = snapshot.regions
        loop = snapshot.loop
        selection = snapshot.selection
        cursor = min(snapshot.cursor, snapshot.clip.frameCount)
        revision = snapshot.revision
        audioRevision = snapshot.audioRevision
        version += 1
        if fit || wasFit { zoomToFit() } else { setView(start: viewStart, length: viewLength) }
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
            s.selection = nil
            s.cursor = 0
        }
    }

    func trimToLoop() {
        guard let loop, loop.count < frameCount else { return }
        perform("Trim to Loop", fit: true, { AudioOps.slice($0, loop) }) { s in
            s.regions = RegionMath.afterTrim(s.regions, to: loop)
            s.loop = 0..<loop.count
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
