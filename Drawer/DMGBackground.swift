// Draws the DMG window's background: a dark backdrop with an arrow from where Drawer.app sits to Applications.
// Used by dmg.sh: `swift DMGBackground.swift out.png scale`.
import AppKit

let out = CommandLine.arguments[1]
let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 1)
let size = CGSize(width: 540, height: 380)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Backdrop, like the README banner.
NSGradient(starting: NSColor(red: 0.165, green: 0.173, blue: 0.22, alpha: 1),
           ending: NSColor(red: 0.07, green: 0.07, blue: 0.1, alpha: 1))!.draw(in: NSRect(origin: .zero, size: size), angle: -60)
NSColor(white: 1, alpha: 0.05).setFill()
for x in stride(from: 12.0, to: size.width, by: 24) {
    for y in stride(from: 12.0, to: size.height, by: 24) { NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 2.4, height: 2.4)).fill() }
}

// Arrow between the icons (centres at x 140 and 400, y 180 from the top).
let y = size.height - 180
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 222, y: y))
arrow.line(to: NSPoint(x: 312, y: y))
arrow.move(to: NSPoint(x: 298, y: y + 14))
arrow.line(to: NSPoint(x: 316, y: y))
arrow.line(to: NSPoint(x: 298, y: y - 14))
arrow.lineWidth = 6
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(red: 1, green: 0.58, blue: 0.25, alpha: 1).setStroke()
arrow.stroke()

// Caption.
let para = NSMutableParagraphStyle()
para.alignment = .center
let caption = NSAttributedString(string: "Drag Drawer to Applications", attributes: [
    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
    .foregroundColor: NSColor(white: 1, alpha: 0.75),
    .paragraphStyle: para,
])
caption.draw(in: NSRect(x: 0, y: 56, width: size.width, height: 22))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
