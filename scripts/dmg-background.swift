// Draws the installer window background in Doorstep's palette.
// Usage: swift scripts/dmg-background.swift out.png   (writes a 2x image for a 660x420 window)
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"
let w = 660.0, h = 420.0, scale = 2.0

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}
let night = hex(0x0E0F11), slate = hex(0x1A1C20), paper = hex(0xF2EFE9), ash = hex(0x8A8D93), porch = hex(0xF5B544)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: w, height: h)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Paper, not night: Finder draws icon names in dark text, which a dark background would hide.
NSGradient(starting: paper, ending: hex(0xE6E1D8))!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)
// A soft porchlight glow behind the app icon.
let glow = NSGradient(colors: [porch.withAlphaComponent(0.22), porch.withAlphaComponent(0)])!
glow.draw(fromCenter: NSPoint(x: 180, y: 210), radius: 0, toCenter: NSPoint(x: 180, y: 210), radius: 150, options: [])

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, colour: NSColor, y: CGFloat) {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: colour, .paragraphStyle: p]
    NSAttributedString(string: s, attributes: attrs).draw(in: NSRect(x: 0, y: y, width: w, height: size * 1.5))
}
text("Drag Doorstep into Applications", size: 20, weight: .semibold, colour: night, y: 340)
text("Then open it from Applications. It lives in your menu bar.", size: 12, weight: .regular, colour: hex(0x5E6167), y: 316)

// Arrow from the app (x 180) to Applications (x 480), centred on the icons (y 210).
hex(0xD9962A).setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 268, y: 210))
arrow.line(to: NSPoint(x: 392, y: 210))
arrow.move(to: NSPoint(x: 378, y: 222))
arrow.line(to: NSPoint(x: 394, y: 210))
arrow.line(to: NSPoint(x: 378, y: 198))
arrow.stroke()

text("First time: if macOS says it can't check Doorstep, open System Settings › Privacy & Security", size: 11, weight: .regular, colour: hex(0x5E6167), y: 74)
text("and click Open Anyway. Updates after that install themselves.", size: 11, weight: .regular, colour: hex(0x5E6167), y: 58)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
