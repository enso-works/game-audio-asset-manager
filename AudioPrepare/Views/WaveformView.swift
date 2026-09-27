import AppKit
import SwiftUI

/// Values that affect drawing; passing them in makes SwiftUI redraw the NSView when they change.
struct WaveformDrawState: Equatable {
    var version: Int
    var selection: Range<Int>?
    var cursor: Int
    var playhead: Int?
    var viewStart: Double
    var viewLength: Double
    var regions: [Region]
    var loop: Range<Int>?
}

struct WaveformView: NSViewRepresentable {
    let model: EditorModel
    let mode: WaveformNSView.Mode
    let state: WaveformDrawState

    func makeNSView(context: Context) -> WaveformNSView {
        let view = WaveformNSView()
        view.mode = mode
        view.model = model
        return view
    }

    func updateNSView(_ view: WaveformNSView, context: Context) {
        view.model = model
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

final class WaveformNSView: NSView {
    enum Mode { case main, overview }

    var mode: Mode = .main
    weak var model: EditorModel?

    static let rulerHeight: CGFloat = 18
    static let regionStripHeight: CGFloat = 18
    static let palette: [NSColor] = [.systemOrange, .systemPink, .systemBlue, .systemGreen, .systemPurple, .systemYellow, .systemRed, .systemTeal]

    private enum DragState {
        case none
        case select(anchor: Int)
        case resize(fixed: Int)
        case loop(fixed: Int)
    }

    private var dragState = DragState.none
    private var dragMoved = false
    private var downPoint = NSPoint.zero

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var headerHeight: CGFloat { mode == .main ? Self.rulerHeight + Self.regionStripHeight : 0 }
    private var waveRect: NSRect { NSRect(x: 0, y: headerHeight, width: bounds.width, height: bounds.height - headerHeight) }

    // MARK: - Coordinates

    private func span(_ model: EditorModel) -> (start: Double, length: Double) {
        mode == .main ? (model.viewStart, max(model.viewLength, 1)) : (0, Double(max(model.frameCount, 1)))
    }

    private func frame(atX x: CGFloat) -> Int {
        guard let model else { return 0 }
        let (start, length) = span(model)
        let frame = start + Double(x / max(bounds.width, 1)) * length
        return Int(min(max(frame, 0), Double(model.frameCount)))
    }

    private func x(for frame: Int) -> CGFloat {
        guard let model else { return 0 }
        let (start, length) = span(model)
        return CGFloat((Double(frame) - start) / length) * bounds.width
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.1, alpha: 1).setFill()
        bounds.fill()
        guard let model, let clip = model.clip, let context = NSGraphicsContext.current?.cgContext else { return }
        let wave = waveRect
        let (start, length) = span(model)

        if mode == .main {
            NSColor(white: 0.15, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight).fill()
        }

        for region in model.regions {
            let x0 = x(for: region.start)
            let x1 = x(for: region.end)
            guard x1 >= 0, x0 <= bounds.width else { continue }
            let color = Self.palette[region.colorIndex % Self.palette.count]
            color.withAlphaComponent(mode == .main ? 0.12 : 0.25).setFill()
            NSRect(x: x0, y: wave.minY, width: max(x1 - x0, 1), height: wave.height).fill()
            if mode == .main {
                let label = NSRect(x: x0, y: Self.rulerHeight, width: max(x1 - x0, 1), height: Self.regionStripHeight)
                color.withAlphaComponent(0.7).setFill()
                label.fill()
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: label).addClip()
                (region.name as NSString).draw(
                    at: NSPoint(x: max(x0, 0) + 4, y: label.minY + 2),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white]
                )
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        if let selection = model.selection, !selection.isEmpty {
            let x0 = x(for: selection.lowerBound)
            let x1 = x(for: selection.upperBound)
            NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
            NSRect(x: x0, y: wave.minY, width: max(x1 - x0, 1), height: wave.height).fill()
            if mode == .main {
                NSColor.controlAccentColor.setFill()
                NSRect(x: x0, y: wave.minY, width: 1, height: wave.height).fill()
                NSRect(x: x1 - 1, y: wave.minY, width: 1, height: wave.height).fill()
            }
        }

        NSColor(white: 1, alpha: 0.07).setFill()
        NSRect(x: 0, y: wave.midY, width: bounds.width, height: 1).fill()
        WaveformRenderer.draw(in: context, rect: wave, clip: clip, peaks: model.peaks, start: start, length: length)

        if mode == .main {
            drawRuler(clip: clip, start: start, length: length)
        } else {
            let x0 = x(for: Int(model.viewStart))
            let x1 = x(for: Int(model.viewStart + model.viewLength))
            let visible = NSRect(x: x0, y: 0.5, width: max(x1 - x0, 3), height: bounds.height - 1)
            NSColor(white: 1, alpha: 0.08).setFill()
            visible.fill()
            NSColor(white: 1, alpha: 0.5).setStroke()
            NSBezierPath(rect: visible.insetBy(dx: 0.5, dy: 0)).stroke()
        }

        if let loop = model.loop {
            drawLoop(loop, wave: wave)
        }

        NSColor.systemYellow.withAlphaComponent(0.85).setFill()
        NSRect(x: x(for: model.cursor), y: 0, width: 1, height: bounds.height).fill()

        if model.player.isPlaying {
            NSColor.systemRed.setFill()
            NSRect(x: x(for: model.player.position), y: 0, width: 1.5, height: bounds.height).fill()
        }
    }

    private func drawLoop(_ loop: Range<Int>, wave: NSRect) {
        let green = NSColor.systemGreen
        let x0 = x(for: loop.lowerBound)
        let x1 = x(for: loop.upperBound)
        green.setFill()
        NSRect(x: x0, y: wave.minY, width: 1.5, height: wave.height).fill()
        NSRect(x: x1 - 1.5, y: wave.minY, width: 1.5, height: wave.height).fill()
        guard mode == .main else { return }
        green.withAlphaComponent(0.5).setFill()
        NSRect(x: x0, y: Self.rulerHeight - 3, width: max(x1 - x0, 1), height: 3).fill()
        // Drag handles in the ruler.
        green.setFill()
        for (edge, pointsRight) in [(x0, true), (x1, false)] {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: edge, y: 0))
            path.line(to: NSPoint(x: edge, y: Self.rulerHeight))
            path.line(to: NSPoint(x: edge + (pointsRight ? 9 : -9), y: Self.rulerHeight / 2))
            path.close()
            path.fill()
        }
    }

    private func drawRuler(clip: AudioClip, start: Double, length: Double) {
        let rate = clip.sampleRate
        let secondsPerPixel = length / Double(max(bounds.width, 1)) / rate
        let steps: [Double] = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let step = steps.first { $0 / secondsPerPixel >= 90 } ?? 600
        let decimals = step >= 1 ? 0 : step >= 0.1 ? 1 : step >= 0.01 ? 2 : 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor(white: 1, alpha: 0.6),
        ]

        let first = Int(floor(start / rate / step))
        let last = Int(ceil((start + length) / rate / step))
        for i in first...max(first, last) {
            let seconds = Double(i) * step
            let x = CGFloat((seconds * rate - start) / length) * bounds.width
            NSColor(white: 1, alpha: 0.35).setFill()
            NSRect(x: x, y: Self.rulerHeight - 6, width: 1, height: 6).fill()
            for minor in 1..<5 {
                let mx = x + CGFloat(Double(minor) * step / 5 * rate / length) * bounds.width
                NSColor(white: 1, alpha: 0.15).setFill()
                NSRect(x: mx, y: Self.rulerHeight - 3, width: 1, height: 3).fill()
            }
            (formatTime(seconds, decimals: decimals) as NSString).draw(at: NSPoint(x: x + 3, y: 2), withAttributes: attributes)
        }
    }

    // MARK: - Mouse

    override func resetCursorRects() {
        guard mode == .main, let model else { return }
        if let selection = model.selection, !selection.isEmpty {
            for edge in [x(for: selection.lowerBound), x(for: selection.upperBound)] {
                addCursorRect(NSRect(x: edge - 4, y: headerHeight, width: 8, height: bounds.height - headerHeight), cursor: .resizeLeftRight)
            }
        }
        if let loop = model.loop {
            for edge in [x(for: loop.lowerBound), x(for: loop.upperBound)] {
                addCursorRect(NSRect(x: edge - 9, y: 0, width: 18, height: Self.rulerHeight), cursor: .resizeLeftRight)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let model, model.clip != nil else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let frame = frame(atX: point.x)
        downPoint = point
        dragMoved = false
        dragState = .none

        if mode == .overview {
            model.center(on: Double(frame))
            return
        }

        if point.y < Self.rulerHeight, let loop = model.loop {
            if abs(point.x - x(for: loop.lowerBound)) < 9 {
                dragState = .loop(fixed: loop.upperBound)
                model.beginLoopDrag()
                return
            }
            if abs(point.x - x(for: loop.upperBound)) < 9 {
                dragState = .loop(fixed: loop.lowerBound)
                model.beginLoopDrag()
                return
            }
        }

        let inRegionStrip = point.y >= Self.rulerHeight && point.y < headerHeight
        if inRegionStrip || event.clickCount == 2 {
            if let region = model.regions.last(where: { $0.range.contains(frame) }) {
                model.selectRegion(region)
                return
            }
            if event.clickCount == 2 {
                model.selectAll()
                return
            }
        }

        if let selection = model.selection, !selection.isEmpty {
            if event.modifierFlags.contains(.shift) {
                let fixed = abs(frame - selection.lowerBound) < abs(frame - selection.upperBound) ? selection.upperBound : selection.lowerBound
                dragState = .resize(fixed: fixed)
                model.selection = min(fixed, frame)..<max(fixed, frame)
                return
            }
            if abs(point.x - x(for: selection.lowerBound)) < 5 {
                dragState = .resize(fixed: selection.upperBound)
                return
            }
            if abs(point.x - x(for: selection.upperBound)) < 5 {
                dragState = .resize(fixed: selection.lowerBound)
                return
            }
        }
        dragState = .select(anchor: frame)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, model.clip != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if mode == .overview {
            model.center(on: Double(frame(atX: point.x)))
            return
        }
        if abs(point.x - downPoint.x) > 2 { dragMoved = true }

        let framesPerPixel = model.viewLength / Double(max(bounds.width, 1))
        if point.x < 0 {
            model.pan(by: Double(point.x) * framesPerPixel * 0.5)
        } else if point.x > bounds.width {
            model.pan(by: Double(point.x - bounds.width) * framesPerPixel * 0.5)
        }

        let frame = frame(atX: point.x)
        switch dragState {
        case .select(let anchor) where dragMoved:
            model.selection = anchor == frame ? nil : min(anchor, frame)..<max(anchor, frame)
        case .resize(let fixed):
            model.selection = fixed == frame ? nil : min(fixed, frame)..<max(fixed, frame)
        case .loop(let fixed):
            model.dragLoop(to: min(fixed, frame)..<max(fixed, frame))
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return }
        if case .select(let anchor) = dragState, !dragMoved {
            model.selection = nil
            model.seek(to: anchor)
        }
        if case .loop = dragState {
            model.endLoopDrag()
        }
        dragState = .none
    }

    override func scrollWheel(with event: NSEvent) {
        guard let model, model.clip != nil else { return }
        let scale: Double = event.hasPreciseScrollingDeltas ? 1 : 12
        let dx = Double(event.scrollingDeltaX) * scale
        let dy = Double(event.scrollingDeltaY) * scale
        let width = Double(max(bounds.width, 1))

        if mode == .overview {
            model.pan(by: -(dx != 0 ? dx : dy) * Double(model.frameCount) / width)
            return
        }
        if abs(dy) > abs(dx) {
            let point = convert(event.locationInWindow, from: nil)
            model.zoom(by: pow(1.01, dy), around: Double(frame(atX: point.x)))
        } else {
            model.pan(by: -dx * model.viewLength / width)
        }
    }

    override func magnify(with event: NSEvent) {
        guard let model, model.clip != nil, mode == .main else { return }
        let point = convert(event.locationInWindow, from: nil)
        model.zoom(by: 1 + event.magnification, around: Double(frame(atX: point.x)))
    }
}
