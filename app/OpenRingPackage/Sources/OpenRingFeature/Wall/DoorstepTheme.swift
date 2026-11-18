import SwiftUI

/// Doorstep design tokens. See docs/DESIGN-BRIEF.md sections 5-8.
/// Each colour has exactly one job; don't add new ones casually.
public enum DS {
    // MARK: Palette
    /// Background. Warm near-black.
    static let night = Color(red: 0x0E / 255, green: 0x0F / 255, blue: 0x11 / 255)
    /// Raised surfaces: tiles before video, the strip track.
    static let slate = Color(red: 0x1A / 255, green: 0x1C / 255, blue: 0x20 / 255)
    /// Controls and tracks sitting on the frosted backdrop: a light translucent well,
    /// like Apple's own controls on glass. (`slate` vanishes against the glass.)
    static let well = Color.white.opacity(0.08)
    /// Primary text and People marks.
    static let paper = Color(red: 0xF2 / 255, green: 0xEF / 255, blue: 0xE9 / 255)
    /// Secondary text and Activity marks.
    static let ash = Color(red: 0x8A / 255, green: 0x8D / 255, blue: 0x93 / 255)
    /// The only accent: doorbell presses and unreviewed people.
    static let porchlight = Color(red: 0xF5 / 255, green: 0xB5 / 255, blue: 0x44 / 255)
    /// Errors and the siren only.
    static let ember = Color(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255)

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

/// The window behind everything: system frosted glass, always dark, warmed with a
/// thin wash of `night` so the palette still reads as ours. Native, not decorative:
/// it's what Apple's own menu bar panels use.
public struct Backdrop: View {
    public init() {}
    public var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            DS.night.opacity(0.55)
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }
}
