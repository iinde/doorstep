import AppKit

/// Illustrated camera pictures for demo mode, drawn in code: screenshots and videos of
/// Doorstep never need to show anyone's real home.
public enum DemoArt {
    public enum Scene: String, CaseIterable, Sendable { case porch, driveway, garden, side }
    public enum Visitor: Sendable, Equatable { case none, courier(String, NSColor), person(NSColor), parcel, dog }

    private nonisolated(unsafe) static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    public static func image(_ scene: Scene, visitor: Visitor = .none, time: Date = Date(), seed: Int = 0) -> NSImage {
        let key = "\(scene)-\(visitor)-\(seed)-\(Int(time.timeIntervalSince1970 / 60))"
        lock.lock(); if let hit = cache[key] { lock.unlock(); return hit }; lock.unlock()
        let w: CGFloat = 1280, h: CGFloat = 720
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            draw(scene, visitor: visitor, time: time, seed: seed, in: rect)
            return true
        }
        lock.lock(); cache[key] = img; lock.unlock()
        return img
    }

    // MARK: Palette (daylight, slightly muted like a real camera)

    static func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    static func fill(_ colour: NSColor, _ path: NSBezierPath) { colour.setFill(); path.fill() }
    static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ colour: NSColor, r: CGFloat = 0) {
        fill(colour, NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r))
    }
    static func poly(_ pts: [(CGFloat, CGFloat)], _ colour: NSColor) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
        for q in pts.dropFirst() { p.line(to: NSPoint(x: q.0, y: q.1)) }
        p.close()
        fill(colour, p)
    }
    static func gradient(_ r: NSRect, _ top: NSColor, _ bottom: NSColor) {
        NSGradient(starting: bottom, ending: top)!.draw(in: r, angle: 90)
    }

    static func draw(_ scene: Scene, visitor: Visitor, time: Date, seed: Int, in r: NSRect) {
        let w = r.width, h = r.height
        // Sky.
        gradient(NSRect(x: 0, y: h * 0.45, width: w, height: h * 0.55), c(0x9DB8CF), c(0xD9E2E6))

        switch scene {
        case .porch: porch(w, h)
        case .driveway: driveway(w, h)
        case .garden: garden(w, h)
        case .side: side(w, h)
        }

        // Visitor.
        let spot: (CGFloat, CGFloat, CGFloat) // x, feet y, height
        switch scene {
        case .porch: spot = (w * 0.47, h * 0.24, h * 0.52)
        case .driveway: spot = (w * 0.62, h * 0.2, h * 0.42)
        case .garden: spot = (w * 0.35, h * 0.22, h * 0.36)
        case .side: spot = (w * 0.5, h * 0.18, h * 0.5)
        }
        switch visitor {
        case .none: break
        case .courier(let name, let colour):
            person(at: spot, jacket: colour, trousers: c(0x2B2F36), label: name, carrying: true)
        case .person(let colour):
            person(at: spot, jacket: colour, trousers: c(0x3A3F4A), label: nil, carrying: false)
        case .parcel:
            parcel(x: spot.0 + 40, y: spot.1 - 6, size: h * 0.11)
        case .dog:
            dog(x: spot.0, y: spot.1, size: h * 0.12)
        }

        // Camera look: soft fisheye vignette and a little grain.
        let vignette = NSGradient(colors: [.clear, .clear, NSColor.black.withAlphaComponent(0.55)],
                                  atLocations: [0, 0.62, 1], colorSpace: .sRGB)!
        vignette.draw(fromCenter: NSPoint(x: w / 2, y: h / 2), radius: 0,
                      toCenter: NSPoint(x: w / 2, y: h / 2), radius: w * 0.62, options: [.drawsAfterEndingLocation])
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<1400 {
            let x = CGFloat.random(in: 0..<w, using: &rng), y = CGFloat.random(in: 0..<h, using: &rng)
            NSColor(white: CGFloat.random(in: 0...1, using: &rng), alpha: 0.05).setFill()
            NSRect(x: x, y: y, width: 2, height: 2).fill()
        }
        // Timestamp, as cameras print it.
        let stamp = time.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .medium),
                                                    .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
        NSAttributedString(string: stamp, attributes: attrs).draw(at: NSPoint(x: w - 260, y: 18))
    }

    // MARK: Scenes

    static func porch(_ w: CGFloat, _ h: CGFloat) {
        // Houses across the road.
        houseRow(w, h, baseline: h * 0.48)
        // Road and pavement.
        rect(0, h * 0.36, w, h * 0.12, c(0x6F7377))
        rect(0, h * 0.33, w, h * 0.035, c(0xB9B4AA))
        // Front garden path and lawn.
        rect(0, 0, w, h * 0.33, c(0x7FA06A))
        poly([(w * 0.28, 0), (w * 0.66, 0), (w * 0.56, h * 0.33), (w * 0.42, h * 0.33)], c(0xCFC6B4))
        for i in 0..<6 { // paving lines
            let y = h * 0.055 * CGFloat(i)
            rect(w * 0.29 + CGFloat(i) * 8, y, w * 0.36 - CGFloat(i) * 16, 2, c(0xB3A994))
        }
        // Parked car on the road.
        car(x: w * 0.6, y: h * 0.37, scale: 1.0, colour: c(0x3F6FB5))
        // Porch frame (left) and brick wall (right), close to the lens.
        rect(0, 0, w * 0.12, h, c(0xEDEAE4))
        rect(w * 0.1, 0, w * 0.025, h, c(0xD4CFC6))
        poly([(0, h), (w, h), (w, h * 0.86), (w * 0.18, h * 0.8), (0, h * 0.82)], c(0x6A4A35))
        bricks(x: w * 0.8, w: w * 0.2, h: h)
        // Wall lantern.
        rect(w * 0.15, h * 0.62, 26, 40, c(0x22252A), r: 4)
        rect(w * 0.15 + 5, h * 0.62 + 6, 16, 26, c(0xF5D58A), r: 3)
        // Bins.
        rect(w * 0.16, h * 0.08, w * 0.075, h * 0.2, c(0x3E7A43), r: 8)
        rect(w * 0.155, h * 0.27, w * 0.085, h * 0.025, c(0x2F5F34), r: 4)
    }

    static func driveway(_ w: CGFloat, _ h: CGFloat) {
        houseRow(w, h, baseline: h * 0.55)
        rect(0, h * 0.45, w, h * 0.1, c(0x6F7377))
        rect(0, 0, w, h * 0.45, c(0x8A8780))
        for i in 0..<9 { rect(0, h * 0.05 * CGFloat(i), w, 1.5, c(0x7A776F)) }   // block paving
        car(x: w * 0.22, y: h * 0.08, scale: 1.9, colour: c(0x2C2F35))
        // Garage door edge and wall (right).
        bricks(x: w * 0.82, w: w * 0.18, h: h)
        rect(w * 0.78, 0, w * 0.04, h * 0.7, c(0xE7E3DC))
    }

    static func garden(_ w: CGFloat, _ h: CGFloat) {
        // Fence and trees.
        rect(0, h * 0.4, w, h * 0.22, c(0x8B6B4E))
        for i in 0..<16 { rect(CGFloat(i) * w / 16, h * 0.4, 3, h * 0.22, c(0x6E5038)) }
        for (x, s) in [(0.12, 1.0), (0.82, 1.2), (0.55, 0.8)] { tree(x: w * x, y: h * 0.55, s: s * h / 720) }
        // Lawn and patio.
        rect(0, 0, w, h * 0.4, c(0x7DA36B))
        poly([(w * 0.45, 0), (w, 0), (w, h * 0.3), (w * 0.62, h * 0.3)], c(0xC9BFAE))
        // Table and parasol.
        rect(w * 0.75, h * 0.12, w * 0.12, h * 0.02, c(0x6C5A48))
        rect(w * 0.805, h * 0.04, 6, h * 0.08, c(0x6C5A48))
        rect(w * 0.807, h * 0.14, 4, h * 0.22, c(0xDAD5CD))
        poly([(w * 0.73, h * 0.34), (w * 0.81, h * 0.44), (w * 0.89, h * 0.34)], c(0xF0ECE4))
        // Flower bed.
        for i in 0..<14 {
            let col = [c(0xE07A5F), c(0xF2CC8F), c(0xB5838D)][i % 3]
            fill(col, NSBezierPath(ovalIn: NSRect(x: w * 0.03 + CGFloat(i) * 22, y: h * 0.33 + CGFloat(i % 2) * 8, width: 12, height: 12)))
        }
    }

    static func side(_ w: CGFloat, _ h: CGFloat) {
        rect(0, 0, w, h, c(0xBFB8AC))
        // Path running away.
        poly([(w * 0.2, 0), (w * 0.8, 0), (w * 0.58, h * 0.6), (w * 0.42, h * 0.6)], c(0xA59D90))
        bricks(x: 0, w: w * 0.3, h: h)
        rect(w * 0.7, 0, w * 0.3, h, c(0x8B6B4E))
        for i in 0..<6 { rect(w * 0.7 + CGFloat(i) * w * 0.05, 0, 3, h, c(0x6E5038)) }
        // Gate at the end.
        rect(w * 0.42, h * 0.6, w * 0.16, h * 0.3, c(0x5B4634))
        gradient(NSRect(x: 0, y: h * 0.9, width: w, height: h * 0.1), c(0x9DB8CF), c(0xCAD6DC))
    }

    // MARK: Pieces

    static func houseRow(_ w: CGFloat, _ h: CGFloat, baseline: CGFloat) {
        let walls = [c(0xE3D3B8), c(0xD8C7A8), c(0xE9DEC9), c(0xD2BFA0)]
        var x: CGFloat = -40
        var i = 0
        while x < w {
            let hw = w * 0.22, hh = h * 0.2
            rect(x, baseline, hw, hh, walls[i % walls.count])
            poly([(x - 8, baseline + hh), (x + hw / 2, baseline + hh + h * 0.1), (x + hw + 8, baseline + hh)], c(0x5E5A57))
            for wx in [0.18, 0.62] {
                rect(x + hw * wx, baseline + hh * 0.45, hw * 0.2, hh * 0.32, c(0x8FA6B8))
                rect(x + hw * wx, baseline + hh * 0.05, hw * 0.2, hh * 0.3, c(0x8FA6B8))
            }
            rect(x + hw * 0.43, baseline, hw * 0.13, hh * 0.38, c(0x4E5D73))
            x += hw + 18
            i += 1
        }
    }

    static func bricks(x: CGFloat, w: CGFloat, h: CGFloat) {
        rect(x, 0, w, h, c(0xD9CBB0))
        var y: CGFloat = 0, row = 0
        while y < h {
            rect(x, y, w, 2, c(0xBFAF92))
            var bx = x + (row % 2 == 0 ? 0 : 30)
            while bx < x + w { rect(bx, y, 2, 26, c(0xBFAF92)); bx += 60 }
            y += 26; row += 1
        }
    }

    static func car(x: CGFloat, y: CGFloat, scale s: CGFloat, colour: NSColor) {
        rect(x, y + 18 * s, 230 * s, 46 * s, colour, r: 16 * s)
        poly([(x + 40 * s, y + 62 * s), (x + 70 * s, y + 96 * s), (x + 160 * s, y + 96 * s), (x + 195 * s, y + 62 * s)], colour)
        poly([(x + 52 * s, y + 64 * s), (x + 76 * s, y + 90 * s), (x + 112 * s, y + 90 * s), (x + 112 * s, y + 64 * s)], c(0xC5D3DE))
        poly([(x + 120 * s, y + 64 * s), (x + 120 * s, y + 90 * s), (x + 155 * s, y + 90 * s), (x + 184 * s, y + 64 * s)], c(0xC5D3DE))
        for wx in [40.0, 180.0] {
            fill(c(0x1C1D20), NSBezierPath(ovalIn: NSRect(x: x + CGFloat(wx) * s - 22 * s, y: y, width: 44 * s, height: 44 * s)))
            fill(c(0x8D9196), NSBezierPath(ovalIn: NSRect(x: x + CGFloat(wx) * s - 10 * s, y: y + 12 * s, width: 20 * s, height: 20 * s)))
        }
    }

    static func tree(x: CGFloat, y: CGFloat, s: CGFloat) {
        rect(x - 8 * s, y, 16 * s, 90 * s, c(0x6B4F3A))
        for (dx, dy, r) in [(-50.0, 110.0, 70.0), (40.0, 120.0, 75.0), (0.0, 170.0, 80.0)] {
            fill(c(0x5E8A55), NSBezierPath(ovalIn: NSRect(x: x + CGFloat(dx) * s - CGFloat(r) * s, y: y + CGFloat(dy) * s - CGFloat(r) * s,
                                                          width: CGFloat(r) * 2 * s, height: CGFloat(r) * 2 * s)))
        }
    }

    static func person(at p: (CGFloat, CGFloat, CGFloat), jacket: NSColor, trousers: NSColor, label: String?, carrying: Bool) {
        let (x, y, hgt) = p
        let u = hgt / 10
        // Legs.
        rect(x - 1.3 * u, y, 1.1 * u, 4.4 * u, trousers, r: 0.4 * u)
        rect(x + 0.2 * u, y, 1.1 * u, 4.4 * u, trousers, r: 0.4 * u)
        rect(x - 1.5 * u, y - 0.2 * u, 1.5 * u, 0.6 * u, c(0x1D1E21), r: 0.3 * u)
        rect(x + 0.1 * u, y - 0.2 * u, 1.5 * u, 0.6 * u, c(0x1D1E21), r: 0.3 * u)
        // Body and arms.
        rect(x - 1.7 * u, y + 4.1 * u, 3.4 * u, 3.9 * u, jacket, r: 1.0 * u)
        rect(x - 2.3 * u, y + 4.6 * u, 0.8 * u, 3.0 * u, jacket, r: 0.4 * u)
        rect(x + 1.5 * u, y + 4.6 * u, 0.8 * u, 3.0 * u, jacket, r: 0.4 * u)
        // Head.
        fill(c(0xE0B892), NSBezierPath(ovalIn: NSRect(x: x - 0.95 * u, y: y + 8.0 * u, width: 1.9 * u, height: 2.0 * u)))
        fill(c(0x3B2A20), NSBezierPath(roundedRect: NSRect(x: x - 1.0 * u, y: y + 9.2 * u, width: 2.0 * u, height: 0.9 * u), xRadius: 0.4 * u, yRadius: 0.4 * u))
        if let label {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 0.75 * u, weight: .heavy), .foregroundColor: NSColor.white]
            let s = NSAttributedString(string: label, attributes: attrs)
            s.draw(at: NSPoint(x: x - s.size().width / 2, y: y + 6.3 * u))
        }
        if carrying { parcel(x: x - 1.2 * u, y: y + 4.6 * u, size: 2.4 * u) }
    }

    static func parcel(x: CGFloat, y: CGFloat, size s: CGFloat) {
        rect(x, y, s, s * 0.75, c(0xC59A62), r: 3)
        rect(x, y + s * 0.34, s, s * 0.07, c(0xA97F4D))
        rect(x + s * 0.45, y, s * 0.1, s * 0.75, c(0xE4D3B4))
    }

    static func dog(x: CGFloat, y: CGFloat, size s: CGFloat) {
        rect(x, y + s * 0.3, s * 1.4, s * 0.55, c(0x9C6B3F), r: s * 0.25)
        fill(c(0x9C6B3F), NSBezierPath(ovalIn: NSRect(x: x + s * 1.15, y: y + s * 0.6, width: s * 0.6, height: s * 0.5)))
        for lx in [0.1, 0.45, 0.9, 1.2] { rect(x + s * CGFloat(lx), y, s * 0.15, s * 0.4, c(0x7D5431)) }
    }
}

import SwiftUI

/// Stands in for live video in demo mode: the camera's illustration, with the person
/// from the demo's live analysis walking through it.
public struct DemoLivePicture: View {
    let deviceId: Int
    @ObservedObject private var intel = LiveIntel.shared
    public init(deviceId: Int) { self.deviceId = deviceId }
    public var body: some View {
        GeometryReader { g in
            Image(nsImage: DemoData.live(deviceId))
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: g.size.width, height: g.size.height)
                .clipped()
        }
    }
}
