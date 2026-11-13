// Renders the app icon: `swift Icon.swift out.png` (1024×1024). Not compiled into the app.
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// macOS icon grid: 824pt body centred in 1024, ~185pt corner radius.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.22, alpha: 1),
           ending: NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.10, alpha: 1))!.draw(in: shape, angle: -90)
NSGraphicsContext.current?.restoreGraphicsState()

// Main window (top pane).
let top = NSRect(x: 190, y: 470, width: 644, height: 360)
NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
NSBezierPath(roundedRect: top, xRadius: 44, yRadius: 44).fill()
NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
for (i, w) in [380.0, 300.0, 420.0].enumerated() {
    NSBezierPath(roundedRect: NSRect(x: 250, y: 740 - Double(i) * 70, width: w, height: 30), xRadius: 15, yRadius: 15).fill()
}

// Drawer (bottom pane) sliding up.
let bottom = NSRect(x: 190, y: 190, width: 644, height: 250)
NSGradient(starting: NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.25, alpha: 1),
           ending: NSColor(calibratedRed: 0.95, green: 0.33, blue: 0.36, alpha: 1))!
    .draw(in: NSBezierPath(roundedRect: bottom, xRadius: 44, yRadius: 44), angle: -90)
NSColor.white.withAlphaComponent(0.85).setFill()
NSBezierPath(roundedRect: NSRect(x: 452, y: 400, width: 120, height: 16), xRadius: 8, yRadius: 8).fill()   // grabber
// Terminal prompt: chevron + cursor.
let glyph = NSBezierPath()
glyph.move(to: NSPoint(x: 255, y: 345)); glyph.line(to: NSPoint(x: 320, y: 295)); glyph.line(to: NSPoint(x: 255, y: 245))
glyph.move(to: NSPoint(x: 355, y: 245)); glyph.line(to: NSPoint(x: 445, y: 245))
glyph.lineWidth = 26; glyph.lineCapStyle = .round; glyph.lineJoinStyle = .round
NSColor.white.setStroke()
glyph.stroke()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
