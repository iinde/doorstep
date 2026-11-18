// Renders Doorstep's brand assets from code, so they can be regenerated exactly.
//   swift scripts/brand/render-brand.swift <repo root>
// Writes: the AppIcon set, the menu bar template marks, and docs/brand/*.png previews.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}
let night = hex(0x0E0F11), slate = hex(0x1A1C20), paper = hex(0xF2EFE9), porch = hex(0xF5B544)
let porchDeep = hex(0xE08A1E), porchLight = hex(0xFFD98A)

/// The doorway: a rectangle with a semicircular top. `rect` is the whole door.
func doorway(_ r: NSRect) -> NSBezierPath {
    let p = NSBezierPath()
    let radius = r.width / 2
    p.move(to: NSPoint(x: r.minX, y: r.minY))
    p.line(to: NSPoint(x: r.minX, y: r.maxY - radius))
    p.appendArc(withCenter: NSPoint(x: r.midX, y: r.maxY - radius), radius: radius, startAngle: 180, endAngle: 0, clockwise: true)
    p.line(to: NSPoint(x: r.maxX, y: r.minY))
    p.close()
    return p
}

func bitmap(_ px: Int, _ draw: (CGFloat) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    draw(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ path: String) {
    let url = root.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: App icon (1024 canvas, Apple's 824 squircle grid)

func appIcon(_ s: CGFloat) {
    let k = s / 1024
    let tile = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 185 * k, yRadius: 185 * k)

    // Drop shadow under the tile, as macOS icons have.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 18 * k
    shadow.shadowOffset = NSSize(width: 0, height: -8 * k)
    shadow.set()
    night.setFill(); squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    // Dusk sky.
    NSGradient(colors: [hex(0x2A2D35), slate, night], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        .draw(in: tile, angle: -90)

    let doorW = 250 * k, doorH = doorW * 1.45
    let door = NSRect(x: 512 * k - doorW / 2, y: 330 * k, width: doorW, height: doorH)

    // Halo.
    NSGradient(colors: [porch.withAlphaComponent(0.45), porch.withAlphaComponent(0.12), porch.withAlphaComponent(0)],
               atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        .draw(fromCenter: NSPoint(x: door.midX, y: door.midY), radius: 0,
              toCenter: NSPoint(x: door.midX, y: door.midY), radius: 360 * k, options: [])

    // Light spilling down the step and onto the ground: a soft wedge.
    let spill = NSBezierPath()
    spill.move(to: NSPoint(x: door.minX, y: door.minY))
    spill.line(to: NSPoint(x: door.maxX, y: door.minY))
    spill.line(to: NSPoint(x: door.maxX + 150 * k, y: 100 * k))
    spill.line(to: NSPoint(x: door.minX - 150 * k, y: 100 * k))
    spill.close()
    NSGraphicsContext.saveGraphicsState()
    spill.addClip()
    NSGradient(colors: [porch.withAlphaComponent(0.30), porch.withAlphaComponent(0)])!
        .draw(in: NSRect(x: door.minX - 150 * k, y: 100 * k, width: doorW + 300 * k, height: door.minY - 100 * k), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The doorway, warm at the floor.
    let path = doorway(door)
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [porchLight, porch, porchDeep], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: door, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The step.
    let gap = 26 * k
    let step = NSRect(x: door.midX - doorW * 0.75, y: door.minY - gap - 34 * k, width: doorW * 1.5, height: 34 * k)
    NSGradient(starting: paper, ending: hex(0xC9C3B8))!.draw(in: NSBezierPath(roundedRect: step, xRadius: 6 * k, yRadius: 6 * k), angle: -90)

    // A hairline of light on the tile's top edge.
    hex(0xFFFFFF, 0.10).setStroke()
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5 * k, dy: 1.5 * k), xRadius: 184 * k, yRadius: 184 * k)
    rim.lineWidth = 3 * k
    rim.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

for (name, px) in [("icon_16x16", 16), ("icon_32x32", 32), ("icon_64x64", 64), ("icon_128x128", 128),
                   ("icon_256x256", 256), ("icon_512x512", 512), ("icon_1024x1024", 1024)] {
    write(bitmap(px, appIcon), "app/OpenRing/Assets.xcassets/AppIcon.appiconset/\(name).png")
}
write(bitmap(1024, appIcon), "docs/brand/app-icon.png")

// MARK: Menu bar marks (template: black on clear; macOS tints them)

func menuMark(badge: Bool) -> (CGFloat) -> Void {
    { s in
        let k = s / 18
        NSColor.black.setStroke()
        NSColor.black.setFill()
        let doorW = 7.4 * k, doorH = doorW * 1.45
        let door = NSRect(x: 8.4 * k - doorW / 2, y: 4.6 * k, width: doorW, height: doorH)
        let p = doorway(door)
        p.lineWidth = 1.5 * k
        p.lineJoinStyle = .round
        p.stroke()
        NSBezierPath(roundedRect: NSRect(x: 8.4 * k - 6 * k, y: 1.6 * k, width: 12 * k, height: 1.6 * k),
                     xRadius: 0.8 * k, yRadius: 0.8 * k).fill()
        if badge {
            // Clear a ring round the dot so it reads against the door line.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: 12.2 * k, y: 12.2 * k, width: 6.2 * k, height: 6.2 * k)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSBezierPath(ovalIn: NSRect(x: 13.4 * k, y: 13.4 * k, width: 3.8 * k, height: 3.8 * k)).fill()
        }
    }
}
for badge in [false, true] {
    let set = badge ? "MenuBarMarkBadge" : "MenuBarMark"
    let dir = "app/OpenRing/Assets.xcassets/\(set).imageset"
    write(bitmap(18, menuMark(badge: badge)), "\(dir)/mark.png")
    write(bitmap(36, menuMark(badge: badge)), "\(dir)/mark@2x.png")
    let json = """
    {
      "images" : [
        { "filename" : "mark.png", "idiom" : "universal", "scale" : "1x" },
        { "filename" : "mark@2x.png", "idiom" : "universal", "scale" : "2x" }
      ],
      "info" : { "author" : "xcode", "version" : 1 },
      "properties" : { "template-rendering-intent" : "template" }
    }
    """
    try! json.write(to: root.appendingPathComponent("\(dir)/Contents.json"), atomically: true, encoding: .utf8)
}
write(bitmap(144, menuMark(badge: true)), "docs/brand/menu-bar-mark.png")
print("Brand assets written.")
