import SwiftUI
import Charts
import RingClient

/// The numbers: when things happen, who delivers when, which camera is busiest, and
/// anything out of the ordinary. Two weeks of history, worked out on this Mac.
struct InsightsPanel: View {
    let devices: [RingDevice]
    let seed: [RingEvent]
    @StateObject private var model = HistoryModel()
    @ObservedObject private var identities = IdentityIndex.shared

    private var moments: [Moment] { MomentBuilder.build(from: model.events) }
    private var days: Int {
        guard let first = moments.map(\.start).min() else { return 1 }
        return max(1, Calendar.current.dateComponents([.day], from: first, to: Date()).day ?? 1)
    }

    struct HourBar: Identifiable { let id = UUID(); let hour: Int; let tier: String; let count: Int }
    struct DayBar: Identifiable { let id = UUID(); let day: Date; let tier: String; let count: Int }
    struct Drop: Identifiable { let id = UUID(); let day: Date; let minutes: Double; let carrier: String }
    struct CamBar: Identifiable { let id = UUID(); let name: String; let count: Int }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Insights").font(.system(size: 22, weight: .semibold)).foregroundStyle(DS.paper)
                    Text("Last \(days) days, worked out on this Mac").font(DS.body).foregroundStyle(DS.ash)
                    Spacer()
                    if model.isLoading { ProgressView().controlSize(.small) }
                }
                tiles
                HStack(alignment: .top, spacing: 18) {
                    card("When things happen", hourChart)
                    card("Every day", dayChart)
                }
                HStack(alignment: .top, spacing: 18) {
                    card("Deliveries by time of day", deliveryChart)
                    card("Busiest cameras", cameraChart)
                }
                card("Out of the ordinary", unusual)
            }
            .padding(24)
        }
        .task { await model.load(devices: devices, seed: seed, days: 14) }
    }

    // MARK: Tiles

    private var tiles: some View {
        let today = moments.filter { Calendar.current.isDateInToday($0.end) }
        let visits = moments.filter { $0.tier >= .people }
        let deliveries = moments.filter { $0.identity?.isDelivery == true || $0.parcelLeft }
        let byHour = Dictionary(grouping: moments, by: { Calendar.current.component(.hour, from: $0.end) })
        let quiet = (0..<24).min { (byHour[$0]?.count ?? 0) < (byHour[$1]?.count ?? 0) } ?? 3
        return HStack(spacing: 14) {
            tile("Today", "\(today.count)", "moments, \(today.filter { $0.tier >= .people }.count) with people")
            tile("Visits a day", String(format: "%.1f", Double(visits.count) / Double(days)), "people or the doorbell")
            tile("Deliveries", "\(deliveries.count)", deliveries.isEmpty ? "none recognised yet" : "recognised in \(days) days")
            tile("Quietest hour", String(format: "%02d:00", quiet), "fewest moments")
            if let postie = postieWindow {
                tile("Postie", postie, "usual arrival")
            }
        }
    }

    /// The middle half of Royal Mail arrival times, e.g. "11:05 to 11:40".
    private var postieWindow: String? {
        let mins = moments.filter { $0.identity?.carrier == .royalMail }
            .map { Double(Calendar.current.component(.hour, from: $0.start) * 60 + Calendar.current.component(.minute, from: $0.start)) }
            .sorted()
        guard mins.count >= 3 else { return nil }
        let lo = mins[mins.count / 4], hi = mins[(mins.count * 3) / 4]
        func f(_ m: Double) -> String { String(format: "%02d:%02d", Int(m) / 60, Int(m) % 60) }
        return "\(f(lo)) to \(f(hi))"
    }

    private func tile(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(DS.meta).foregroundStyle(DS.ash)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(DS.paper)
            Text(note).font(DS.meta).foregroundStyle(DS.ash).lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.slate, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func card<V: View>(_ title: String, _ content: V) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(DS.title).foregroundStyle(DS.paper)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.slate, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func tierName(_ t: MomentTier) -> String {
        switch t { case .doorbell: return "Doorbell"; case .people: return "People"; case .activity: return "Other movement" }
    }

    private var tierScale: KeyValuePairs<String, Color> {
        ["Doorbell": DS.porchlight, "People": DS.paper, "Other movement": DS.ash.opacity(0.6)]
    }

    // MARK: Charts

    private var hourChart: some View {
        var bars: [HourBar] = []
        for t in [MomentTier.activity, .people, .doorbell] {
            let counts = Dictionary(grouping: moments.filter { $0.tier == t }, by: { Calendar.current.component(.hour, from: $0.end) })
            for h in 0..<24 { bars.append(HourBar(hour: h, tier: tierName(t), count: counts[h]?.count ?? 0)) }
        }
        return Chart(bars) { b in
            BarMark(x: .value("Hour", b.hour), y: .value("Moments", b.count))
                .foregroundStyle(by: .value("Kind", b.tier))
        }
        .chartForegroundStyleScale(tierScale)
        .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) { v in
            AxisValueLabel { Text(String(format: "%02d", v.as(Int.self) ?? 0)).font(DS.monoTick) }
        } }
        .frame(height: 200)
    }

    private var dayChart: some View {
        var bars: [DayBar] = []
        for t in [MomentTier.activity, .people, .doorbell] {
            let counts = Dictionary(grouping: moments.filter { $0.tier == t }, by: { Calendar.current.startOfDay(for: $0.end) })
            for (d, list) in counts { bars.append(DayBar(day: d, tier: tierName(t), count: list.count)) }
        }
        return Chart(bars) { b in
            BarMark(x: .value("Day", b.day, unit: .day), y: .value("Moments", b.count))
                .foregroundStyle(by: .value("Kind", b.tier))
        }
        .chartForegroundStyleScale(tierScale)
        .frame(height: 200)
    }

    private var deliveryChart: some View {
        let drops: [Drop] = moments.compactMap { m in
            guard let id = m.identity, id.isDelivery || m.parcelLeft else { return nil }
            let c = Calendar.current
            return Drop(day: c.startOfDay(for: m.start),
                        minutes: Double(c.component(.hour, from: m.start) * 60 + c.component(.minute, from: m.start)),
                        carrier: id.carrier?.rawValue ?? "Delivery")
        }
        return Group {
            if drops.isEmpty {
                Text("No deliveries recognised yet. Daylight clips of couriers, or \"Who was it?\" on a clip, fill this in.")
                    .font(DS.body).foregroundStyle(DS.ash).frame(height: 200)
            } else {
                Chart(drops) { d in
                    PointMark(x: .value("Day", d.day, unit: .day), y: .value("Time", d.minutes))
                        .foregroundStyle(by: .value("Carrier", d.carrier))
                        .symbolSize(80)
                }
                .chartYScale(domain: 360...1260)
                .chartYAxis { AxisMarks(values: [420, 600, 780, 960, 1140]) { v in
                    AxisValueLabel { Text(String(format: "%02d:00", (v.as(Int.self) ?? 0) / 60)).font(DS.monoTick) }
                    AxisGridLine()
                } }
                .frame(height: 200)
            }
        }
    }

    private var cameraChart: some View {
        let bars = Dictionary(grouping: moments, by: \.deviceName).map { CamBar(name: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
        return Chart(bars) { b in
            BarMark(x: .value("Moments", b.count), y: .value("Camera", b.name))
                .foregroundStyle(DS.porchlight.gradient)
                .annotation(position: .trailing) { Text("\(b.count)").font(DS.monoMeta).foregroundStyle(DS.ash) }
        }
        .frame(height: 200)
    }

    // MARK: Anomalies

    /// People at a camera at an hour that's rare for that camera (under 3% of its moments).
    private var unusual: some View {
        let byCam = Dictionary(grouping: moments, by: \.deviceKey)
        var odd: [Moment] = []
        for (_, list) in byCam where list.count >= 20 {
            let byHour = Dictionary(grouping: list, by: { Calendar.current.component(.hour, from: $0.end) })
            for m in list where m.tier >= .people {
                let share = Double(byHour[Calendar.current.component(.hour, from: m.end)]?.count ?? 0) / Double(list.count)
                if share < 0.03 { odd.append(m) }
            }
        }
        odd.sort { $0.end > $1.end }
        return VStack(alignment: .leading, spacing: 8) {
            if odd.isEmpty {
                Text("Nothing unusual. Every visit was at a time that's normal for that camera.")
                    .font(DS.body).foregroundStyle(DS.ash)
            }
            ForEach(odd.prefix(8)) { m in
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(DS.porchlight)
                    Text(m.title).font(DS.bodyStrong).foregroundStyle(DS.paper)
                    Text(m.end, format: .dateTime.weekday(.abbreviated).day().hour().minute()).font(DS.monoMeta).foregroundStyle(DS.ash)
                    Text("rare for this camera at this hour").font(DS.meta).foregroundStyle(DS.ash)
                }
            }
        }
    }
}
