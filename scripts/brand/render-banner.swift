// The README banner: icon, name, promise, and the Doorstep window in light and dark (from demo mode) on a dusk background.
//   swift scripts/brand/render-banner.swift <repo root>
import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}
let W: CGFloat = 2400, H: CGFloat = 1100
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGradient(colors: [hex(0x2A2D35), hex(0x1A1C20), hex(0x0E0F11)], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
NSGradient(colors: [hex(0xF5B544, 0.22), hex(0xF5B544, 0)])!
    .draw(fromCenter: NSPoint(x: 360, y: 640), radius: 0, toCenter: NSPoint(x: 360, y: 640), radius: 700, options: [])
let icon = NSImage(contentsOf: root.appendingPathComponent("docs/brand/app-icon.png"))!
icon.draw(in: NSRect(x: 150, y: 750, width: 210, height: 210))
func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ c: NSColor, _ x: CGFloat, _ y: CGFloat, width: CGFloat = 1100) {
    let p = NSMutableParagraphStyle(); p.lineSpacing = size * 0.15
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: c, .paragraphStyle: p])
        .draw(with: NSRect(x: x, y: y, width: width, height: size * 2.6), options: [.usesLineFragmentOrigin])
}
text("Doorstep", 150, .bold, hex(0xF2EFE9), 160, 330)
text("Your Ring cameras, on your Mac.\nEvery camera live. Who came. What's coming.", 50, .medium, hex(0xC9C5BE), 166, 370)
text("Free · Open source · Private by design", 38, .semibold, hex(0xF5B544), 166, 231)
// The Doorstep window from demo mode, light behind dark, tilted slightly with a shadow.
let ctx = NSGraphicsContext.current!.cgContext
func window(_ name: String, x: CGFloat, y: CGFloat, height h: CGFloat, tilt: CGFloat) {
    let img = NSImage(contentsOf: root.appendingPathComponent("docs/images/\(name)"))!
    ctx.saveGState()
    ctx.translateBy(x: x, y: y)
    ctx.rotate(by: tilt)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.55); shadow.shadowBlurRadius = 60
    shadow.shadowOffset = NSSize(width: 0, height: -24); shadow.set()
    let w = h * img.size.width / img.size.height
    img.draw(in: NSRect(x: -w / 2, y: -h / 2, width: w, height: h))
    ctx.restoreGState()
}
window("window-light.png", x: 1890, y: 700, height: 590, tilt: -0.035)
window("window-dark.png", x: 1760, y: 430, height: 590, tilt: -0.035)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("docs/images/banner.png"))
print("banner written")
