// Renders the app icon: a waveform with loop brackets on a dark gradient squircle.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let context = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824 pt body centered in 1024 with a soft shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
context.addPath(shape)
context.setFillColor(NSColor.black.cgColor)
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(shape)
context.clip()
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(calibratedRed: 0.20, green: 0.10, blue: 0.36, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.14, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])

// Waveform bars.
let teal = NSColor(calibratedRed: 0.36, green: 0.86, blue: 0.78, alpha: 1)
let count = 23
let barWidth: CGFloat = 20
let spacing: CGFloat = 28.5
let startX = 512 - CGFloat(count - 1) * spacing / 2
for i in 0..<count {
    let t = Double(i) / Double(count - 1)
    let envelope = sin(t * .pi) * 0.85 + 0.15
    let wiggle = 0.55 + 0.45 * abs(sin(Double(i) * 1.7) * cos(Double(i) * 0.6))
    let height = CGFloat(envelope * wiggle) * 440 + 30
    let bar = CGRect(x: startX + CGFloat(i) * spacing - barWidth / 2, y: 512 - height / 2, width: barWidth, height: height)
    context.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
}
context.setFillColor(teal.cgColor)
context.fillPath()

// Loop brackets.
let green = NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.40, alpha: 1)
context.setStrokeColor(green.cgColor)
context.setLineWidth(18)
context.setLineCap(.round)
context.setLineJoin(.round)
for (x, direction) in [(CGFloat(290), CGFloat(1)), (CGFloat(734), CGFloat(-1))] {
    context.move(to: CGPoint(x: x + 44 * direction, y: 760))
    context.addLine(to: CGPoint(x: x, y: 760))
    context.addLine(to: CGPoint(x: x, y: 264))
    context.addLine(to: CGPoint(x: x + 44 * direction, y: 264))
}
context.strokePath()
context.restoreGState()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
