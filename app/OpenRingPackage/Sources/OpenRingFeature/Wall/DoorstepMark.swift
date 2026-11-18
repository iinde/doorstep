import SwiftUI

/// The Doorstep mark: a lit doorway on a single step (see docs/BRAND.md).
/// Drawn as shapes so it's sharp at any size and follows the palette.
public struct DoorstepMark: View {
    var size: CGFloat = 28
    var glow = true

    public init(size: CGFloat = 28, glow: Bool = true) {
        self.size = size
        self.glow = glow
    }

    public var body: some View {
        let doorW = size * 0.5, doorH = doorW * 1.45
        VStack(spacing: size * 0.05) {
            DoorwayShape()
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.85, blue: 0.54), DS.porchlight,
                                              Color(red: 0.88, green: 0.54, blue: 0.12)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: doorW, height: doorH)
                .shadow(color: glow ? DS.porchlight.opacity(0.55) : .clear, radius: size * 0.22)
            Capsule()
                .fill(DS.paper)
                .frame(width: doorW * 1.5, height: size * 0.07)
        }
        .frame(width: size, height: size * 1.0, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// Rectangle with a semicircular top.
public struct DoorwayShape: Shape {
    public init() {}
    public func path(in r: CGRect) -> Path {
        var p = Path()
        let radius = r.width / 2
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        p.addArc(center: CGPoint(x: r.midX, y: r.minY + radius), radius: radius,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Mark plus name, for the sign-in screen and Settings.
public struct DoorstepWordmark: View {
    var size: CGFloat = 22
    public init(size: CGFloat = 22) { self.size = size }
    public var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: size * 0.4) {
            DoorstepMark(size: size * 1.3)
            Text("Doorstep")
                .font(.system(size: size, weight: .semibold))
                .tracking(-size * 0.01)
                .foregroundStyle(DS.paper)
        }
    }
}
