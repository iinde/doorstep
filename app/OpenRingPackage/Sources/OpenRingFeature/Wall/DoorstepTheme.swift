import SwiftUI
import AppKit

/// Doorstep design tokens. See docs/DESIGN-BRIEF.md sections 5-8.
/// Each colour has exactly one job; don't add new ones casually.
public enum DS {
    // MARK: Palette (dark value, light value)
    private static func pair(_ dark: (Int, Double), _ light: (Int, Double)) -> Color {
        func ns(_ v: (Int, Double)) -> NSColor {
            NSColor(srgbRed: CGFloat((v.0 >> 16) & 0xFF) / 255, green: CGFloat((v.0 >> 8) & 0xFF) / 255,
                    blue: CGFloat(v.0 & 0xFF) / 255, alpha: v.1)
        }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? ns(dark) : ns(light) })
    }
    /// Background. Warm near-black at night, warm paper by day.
    static let night = pair((0x0E0F11, 1), (0xF4F1EA, 1))
    /// Raised surfaces: tiles before video, the strip track, the rail.
    static let slate = pair((0x1A1C20, 1), (0xE7E3DA, 1))
    /// Controls and tracks sitting on the backdrop: a translucent well.
    static let well = pair((0xFFFFFF, 0.08), (0x000000, 0.07))
    /// Primary text and People marks.
    static let paper = pair((0xF2EFE9, 1), (0x17181B, 1))
    /// Secondary text and Activity marks.
    static let ash = pair((0x8A8D93, 1), (0x65686E, 1))
    /// The only accent: doorbell presses and unreviewed people. Deeper by day so it reads on paper.
    static let porchlight = pair((0xF5B544, 1), (0xB8780A, 1))
    /// Errors and the siren only.
    static let ember = pair((0xE5484D, 1), (0xCE2C31, 1))

    // MARK: Type
    static let display = Font.system(size: 22, weight: .semibold).monospacedDigit()
    static let title = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyStrong = Font.system(size: 13, weight: .semibold)
    static let meta = Font.system(size: 11)
    static let monoBody = Font.system(size: 13, design: .monospaced).monospacedDigit()
    static let monoMeta = Font.system(size: 11, design: .monospaced).monospacedDigit()
    static let monoTick = Font.system(size: 10, design: .monospaced).monospacedDigit()

    // MARK: Layout (8pt grid)
    static let margin: CGFloat = 16
    static let gutter: CGFloat = 8
    static let tileRadius: CGFloat = 10
    static let wallWidth: CGFloat = 640

    // MARK: Motion ("settle")
    static let settle = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let crossfade = Animation.easeInOut(duration: 0.25)
    static let breathe = Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)
}

/// The window behind everything: system frosted glass, warmed with a
/// thin wash of `night` so the palette still reads as ours. Native, not decorative:
/// it's what Apple's own menu bar panels use.
public struct Backdrop: View {
    public init() {}
    public var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            DS.night.opacity(0.55)
        }
        .ignoresSafeArea()
    }
}
