import SwiftUI
import RingClient

/// The signature element: one band per camera over the last 24 hours.
/// Right edge is now. Marks: doorbell = porchlight, person = paper, activity = ash.
/// Hover a mark to read it; click to play the clip in that camera's tile.
struct DayStrip: View {
    let devices: [RingDevice]
    let events: [RingEvent]
    let now: Date
    let liveDeviceIds: Set<Int>
    let onPlay: (RingEvent) -> Void
    /// The span drawn. Defaults to the 24 hours up to `now` (right edge = live).
    var range: ClosedRange<Date>? = nil
    var tickStepHours = 6
    var showsNowEdge = true

    static let window: TimeInterval = 24 * 3600
    private var span: ClosedRange<Date> { range ?? now.addingTimeInterval(-Self.window)...now }
    private let labelWidth: CGFloat = 88
    private let bandHeight: CGFloat = 14
    private let rowGap: CGFloat = 6

    @State private var hovered: RingEvent?

    var body: some View {
        VStack(alignment: .leading, spacing: rowGap) {
            ForEach(devices, id: \.id) { device in
                HStack(spacing: 0) {
                    Text(device.name)
                        .font(DS.meta)
                        .foregroundStyle(DS.ash)
                        .lineLimit(1)
                        .frame(width: labelWidth, alignment: .leading)
                    Band(
                        events: events.filter { matches($0, device) && span.contains($0.createdAt) },
                        span: span,
                        showsNowEdge: showsNowEdge,
                        isLive: liveDeviceIds.contains(device.id),
                        height: bandHeight,
                        hovered: $hovered,
                        onPlay: onPlay
                    )
                    .frame(height: bandHeight)
                }
            }
            ticks
        }
        .overlay(alignment: .topTrailing) { readout }
    }

    private func matches(_ e: RingEvent, _ d: RingDevice) -> Bool {
        if let id = e.deviceId { return id == d.id }
        return e.deviceName == d.name
    }

    /// Hour marks at 6-hour steps, placed by real clock time, plus "now".
    private var ticks: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth, height: 1)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(tickHours, id: \.self) { date in
                        Text(date, format: .dateTime.hour(.twoDigits(amPM: .omitted)))
                            .font(DS.monoTick)
                            .foregroundStyle(DS.ash.opacity(0.8))
                            .fixedSize()
                            .position(x: x(for: date, width: geo.size.width), y: 6)
                    }
                    if showsNowEdge {
                        Text("now")
                            .font(DS.monoTick)
                            .foregroundStyle(DS.ash)
                            .fixedSize()
                            .position(x: geo.size.width - 9, y: 6)
                    }
                }
            }
            .frame(height: 12)
        }
    }

    private var tickHours: [Date] {
        let cal = Calendar.current
        let start = span.lowerBound
        let end = showsNowEdge ? span.upperBound.addingTimeInterval(-3600) : span.upperBound
        var hours: [Date] = []
        var d = cal.nextDate(after: start, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? start
        while d < end {
            if cal.component(.hour, from: d) % tickStepHours == 0 { hours.append(d) }
            d = d.addingTimeInterval(3600)
        }
        return hours
    }

    private func x(for date: Date, width: CGFloat) -> CGFloat {
        let total = span.upperBound.timeIntervalSince(span.lowerBound)
        let t = date.timeIntervalSince(span.lowerBound) / total
        return CGFloat(max(0, min(1, t))) * width
    }

    /// What you're pointing at, set in type above the strip.
    @ViewBuilder
    private var readout: some View {
        if let e = hovered {
            HStack(spacing: 6) {
                Text(e.createdAt, format: .dateTime.hour().minute())
                    .font(DS.monoMeta)
                    .foregroundStyle(DS.paper)
                Text(describe(e))
                    .font(DS.meta)
                    .foregroundStyle(DS.ash)
            }
            .offset(y: -18)
            .allowsHitTesting(false)
        }
    }

    private func describe(_ e: RingEvent) -> String {
        let what: String
        switch MomentTier.of(e) {
        case .doorbell: what = "Doorbell"
        case .people: what = "Person"
        case .activity: what = "Activity"
        }
        let place = e.deviceName.map { " at \($0)" } ?? ""
        if let d = e.duration, d > 0 { return "\(what)\(place) · \(Int(d))s" }
        return what + place
    }
}

private struct Band: View {
    let events: [RingEvent]
    let span: ClosedRange<Date>
    let showsNowEdge: Bool
    let isLive: Bool
    let height: CGFloat
    @Binding var hovered: RingEvent?
    let onPlay: (RingEvent) -> Void

    @State private var breathing = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(DS.well)

                // Least important first so doorbell marks draw on top.
                ForEach(events.sorted { MomentTier.of($0) < MomentTier.of($1) }, id: \.id) { e in
                    mark(for: e)
                        .position(x: x(e.createdAt, w), y: height / 2)
                }

                // The now edge. Breathes slowly while this camera is live.
                if showsNowEdge {
                Rectangle()
                    .fill(DS.paper)
                    .frame(width: 2, height: height)
                    .opacity(isLive ? (breathing ? 0.9 : 0.35) : 0.25)
                    .position(x: w - 1, y: height / 2)
                    .animation(isLive ? DS.breathe : .default, value: breathing)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovered = nearest(to: p.x, width: w)
                case .ended: hovered = nil
                }
            }
            .onTapGesture { location in
                if let e = nearest(to: location.x, width: w) { onPlay(e) }
            }
        }
        .onAppear { breathing = true }
    }

    @ViewBuilder
    private func mark(for e: RingEvent) -> some View {
        let isHovered = hovered?.id == e.id
        switch MomentTier.of(e) {
        case .doorbell:
            RoundedRectangle(cornerRadius: 1).fill(DS.porchlight)
                .frame(width: 3, height: height)
        case .people:
            RoundedRectangle(cornerRadius: 1).fill(DS.paper.opacity(isHovered ? 1 : 0.9))
                .frame(width: isHovered ? 3 : 2, height: height - 2)
        case .activity:
            RoundedRectangle(cornerRadius: 1).fill(DS.ash.opacity(isHovered ? 1 : 0.7))
                .frame(width: isHovered ? 3 : 2, height: height * 0.6)
        }
    }

    private func x(_ date: Date, _ width: CGFloat) -> CGFloat {
        let total = span.upperBound.timeIntervalSince(span.lowerBound)
        let t = date.timeIntervalSince(span.lowerBound) / total
        return CGFloat(max(0, min(1, t))) * width
    }

    /// The mark under the pointer, within 6pt, most significant first.
    private func nearest(to px: CGFloat, width: CGFloat) -> RingEvent? {
        events
            .map { ($0, abs(x($0.createdAt, width) - px)) }
            .filter { $0.1 <= 6 }
            .min { a, b in
                (a.1, -MomentTier.of(a.0).rawValue) < (b.1, -MomentTier.of(b.0).rawValue)
            }?.0
    }
}
