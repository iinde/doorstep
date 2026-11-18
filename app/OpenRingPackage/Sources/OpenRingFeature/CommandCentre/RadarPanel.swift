import SwiftUI
import RingClient

/// Radar: home in the middle, each camera's view as a sector (from the map placement),
/// people seen live as blips (closer to the centre = closer to the camera), and the last
/// hour's activity as fading echoes. The sweep is just for show; the blips are real.
struct RadarPanel: View {
    let devices: [RingDevice]
    let events: [RingEvent]
    @ObservedObject private var intel = LiveIntel.shared
    @ObservedObject private var placement = CameraPlacement.shared

    private var cameras: [RingDevice] { devices.filter { $0.deviceType == .camera || $0.deviceType == .doorbell } }
    static let fov = 140.0

    var body: some View {
        HStack(spacing: 0) {
            TimelineView(.animation) { context in
                Canvas { ctx, size in
                    draw(ctx: &ctx, size: size, time: context.date)
                }
            }
            .padding(30)
            legend.frame(width: 280)
        }
    }

    private func heading(_ d: RingDevice) -> Double {
        placement.spot(for: d, among: devices)?.heading ?? 0
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize, time: Date) {
        let r = min(size.width, size.height) / 2 - 10
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        func point(angle deg: Double, dist: Double) -> CGPoint {
            let a = (deg - 90) * .pi / 180
            return CGPoint(x: c.x + cos(a) * r * dist, y: c.y + sin(a) * r * dist)
        }
        let amber = DS.porchlight, paper = DS.paper

        // Background and rings.
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(DS.slate))
        for f in [0.25, 0.5, 0.75, 1.0] {
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r * f, y: c.y - r * f, width: r * 2 * f, height: r * 2 * f)),
                       with: .color(paper.opacity(0.08)), lineWidth: 1)
        }
        for deg in stride(from: 0.0, to: 360, by: 30) {
            var p = Path(); p.move(to: c); p.addLine(to: point(angle: deg, dist: 1))
            ctx.stroke(p, with: .color(paper.opacity(0.04)), lineWidth: 1)
        }
        for (deg, label) in [(0.0, "N"), (90.0, "E"), (180.0, "S"), (270.0, "W")] {
            ctx.draw(Text(label).font(DS.monoTick).foregroundColor(DS.ash), at: point(angle: deg, dist: 1.04))
        }

        // Camera sectors.
        for d in cameras {
            let h = heading(d)
            var sector = Path()
            sector.move(to: c)
            sector.addArc(center: c, radius: r, startAngle: .degrees(h - 90 - Self.fov / 2),
                          endAngle: .degrees(h - 90 + Self.fov / 2), clockwise: false)
            sector.closeSubpath()
            let hot = !(intel.cameras[d.id]?.people.isEmpty ?? true)
            ctx.fill(sector, with: .color((hot ? amber : paper).opacity(hot ? 0.10 : 0.025)))
            ctx.draw(Text(d.name).font(DS.meta).foregroundColor(hot ? amber : DS.ash), at: point(angle: h, dist: 0.88))
        }

        // Sweep.
        let sweep = time.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4 * 360
        // A soft beam: thin filled wedges fading behind the leading edge.
        for i in 0..<30 {
            let a = sweep - Double(i) * 1.5
            var w = Path()
            w.move(to: c)
            w.addArc(center: c, radius: r, startAngle: .degrees(a - 90 - 1.6), endAngle: .degrees(a - 90), clockwise: false)
            w.closeSubpath()
            ctx.fill(w, with: .color(amber.opacity(0.28 * pow(1 - Double(i) / 30, 2))))
        }
        var edge = Path(); edge.move(to: c); edge.addLine(to: point(angle: sweep, dist: 1))
        ctx.stroke(edge, with: .color(amber.opacity(0.8)), lineWidth: 1.5)

        // Echoes: the last hour's activity per camera, older = fainter, placed along its sector.
        let hourAgo = time.addingTimeInterval(-3600)
        for e in events where e.createdAt > hourAgo && MomentBuilder.isOutsideEvent(e) {
            guard let d = cameras.first(where: { $0.id == e.deviceId }) else { continue }
            let age = time.timeIntervalSince(e.createdAt) / 3600
            let jitter = Double(abs(e.id.hashValue % 100)) / 100 - 0.5
            let p = point(angle: heading(d) + jitter * Self.fov * 0.6, dist: 0.35 + 0.45 * age)
            let tier = MomentTier.of(e)
            let colour: Color = tier == .doorbell ? amber : tier == .people ? paper : DS.ash
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(colour.opacity(0.7 * (1 - age))))
        }

        // Live people: angle from where they are across the picture, distance from their size.
        for d in cameras {
            guard let now = intel.cameras[d.id], time.timeIntervalSince(now.updated) < 3 else { continue }
            for box in now.people {
                let angle = heading(d) + (Double(box.midX) - 0.5) * Self.fov
                let dist = max(0.12, min(0.95, 1 - Double(box.height) * 1.1))
                let p = point(angle: angle, dist: dist)
                let pulse = 6 + 5 * sin(time.timeIntervalSinceReferenceDate * 6)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .color(amber))
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 7 - pulse, y: p.y - 7 - pulse, width: 14 + pulse * 2, height: 14 + pulse * 2)),
                           with: .color(amber.opacity(0.5)), lineWidth: 1.5)
                if now.approaching {
                    ctx.draw(Text("Approaching").font(DS.meta).foregroundColor(amber), at: CGPoint(x: p.x, y: p.y - 20))
                }
            }
        }

        // Home.
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(paper))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Radar").font(DS.title).foregroundStyle(DS.paper)
            Text("Your home is the centre. Each camera covers a slice, from where you placed it on the Map.")
                .font(DS.meta).foregroundStyle(DS.ash).fixedSize(horizontal: false, vertical: true)
            row(DS.porchlight, "Someone seen live, right now")
            row(DS.paper, "A person in the last hour")
            row(DS.ash, "Other movement in the last hour")
            Text("Live blips come from the cameras Doorstep is recording (Settings › Recording) and any camera open in the command centre.")
                .font(DS.meta).foregroundStyle(DS.ash).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(18)
    }

    private func row(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(c).frame(width: 9, height: 9)
            Text(t).font(DS.body).foregroundStyle(DS.paper)
        }
    }
}
