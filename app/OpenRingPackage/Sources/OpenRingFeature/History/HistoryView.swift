import SwiftUI
import AVKit
import RingClient
import UniformTypeIdentifiers

/// History: a proper Mac window. Days | that day's Moments | the Moment playing.
@MainActor
public final class HistoryModel: ObservableObject {
    @Published public private(set) var events: [RingEvent] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var loadedSince: Date?

    public init() {}

    /// Page back through history. Seeded with what the app already has so it's instant.
    public func load(devices: [RingDevice], seed: [RingEvent], days: Int = 14) async {
        if events.isEmpty { events = seed.filter(MomentBuilder.isOutsideEvent) }
        EventDirectory.shared.registerDevices(devices)
        EventDirectory.shared.register(events)
        guard !isLoading, !DemoMode.isOn else { return }
        isLoading = true
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let fetched = await RingClient.shared.fetchHistory(deviceIds: devices.map(\.id), since: since)
        var byId = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        for e in fetched where MomentBuilder.isOutsideEvent(e) { byId[e.id] = e }
        events = byId.values.sorted { $0.createdAt > $1.createdAt }
        EventDirectory.shared.register(events)
        loadedSince = since
        isLoading = false
    }
}

public enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All", people = "People", doorbell = "Doorbell"
    public var id: String { rawValue }
    func includes(_ m: Moment) -> Bool {
        switch self {
        case .all: return true
        case .people: return m.tier >= .people
        case .doorbell: return m.tier == .doorbell
        }
    }
}

enum SidebarItem: Hashable {
    case parcels
    case day(Date)
}

public struct HistoryView: View {
    let devices: [RingDevice]
    let seedEvents: [RingEvent]

    @StateObject private var model = HistoryModel()
    @ObservedObject private var reviews = ReviewStore.shared
    @ObservedObject private var tagIndex = TagIndex.shared  // refresh when Vision finds people
    @ObservedObject private var identities = IdentityIndex.shared  // refresh titles when "who" lands
    @ObservedObject private var parcels = ParcelStore.shared
    @State private var sidebarSel: SidebarItem? = .day(Calendar.current.startOfDay(for: Date()))
    private var selectedDay: Date? { if case .day(let d) = sidebarSel { return d } else { return nil } }
    @State private var selectedMoment: Moment.ID?
    @State private var selectedLocal: LocalClip.ID?
    @ObservedObject private var localClips = LocalClipStore.shared
    @State private var timelapseStatus: String?
    @State private var query = ""
    @State private var reelStatus: String?
    @ObservedObject private var sounds = SoundIndex.shared
    @State private var filter: HistoryFilter = .all
    @State private var camera: Int? = nil   // nil = every camera
    /// Per camera: tags that are just the view (e.g. parked cars), hidden on cards.
    @State private var scenery: [String: Set<String>] = [:]

    public init(devices: [RingDevice], seedEvents: [RingEvent]) {
        self.devices = devices.filter { $0.deviceType != .chime }
        self.seedEvents = seedEvents
    }

    private var allMoments: [Moment] {
        let evs = camera == nil ? model.events : model.events.filter { $0.deviceId == camera }
        return MomentBuilder.build(from: evs)
    }

    private var days: [Date] {
        let cal = Calendar.current
        let set = Set(allMoments.map { cal.startOfDay(for: $0.end) })
        return set.sorted(by: >)
    }

    private var dayMoments: [Moment] {
        guard let day = selectedDay else { return [] }
        return allMoments.filter { Calendar.current.isDate($0.end, inSameDayAs: day) && filter.includes($0) }
    }

    private var selected: Moment? { allMoments.first { $0.id == selectedMoment } }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } content: {
            Group {
                if !MomentSearch(query).isEmpty {
                    searchResults
                } else if sidebarSel == .parcels {
                    ParcelsView(onWatch: watch)
                } else {
                    dayContent
                }
            }
                .navigationSplitViewColumnWidth(min: 460, ideal: 600)
        } detail: {
            if let id = selectedLocal, let clip = localClips.clips.first(where: { $0.id == id }) {
                LocalClipDetail(clip: clip).id(clip.id)
            } else if let m = selected {
                MomentDetail(moment: m)
                    .id(m.id)
            } else {
                Text("Choose a moment to watch it.")
                    .font(DS.body)
                    .foregroundStyle(DS.ash)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.night)
            }
        }
        .toolbar { toolbar }
        .searchable(text: $query, placement: .toolbar, prompt: "Search: DPD last week, knock, parcel left…")
        .preferredColorScheme(.dark)
        .task { await model.load(devices: devices, seed: seedEvents) }
        .task(id: model.events.count) {
            // Re-learn each camera's scenery every 20s while the window is open,
            // as more clips get tagged.
            while !Task.isCancelled {
                var learned: [String: Set<String>] = [:]
                for (key, list) in Dictionary(grouping: allMoments, by: \.deviceKey) {
                    learned[key] = await ThumbnailCache.shared.scenery(among: list.map(\.headline.id))
                }
                if learned != scenery { withAnimation(DS.crossfade) { scenery = learned } }
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .task(id: model.events.count) {
            parcels.link(moments: MomentBuilder.build(from: model.events),
                         doorbellKeys: Set(devices.filter { $0.deviceType == .doorbell }.map { String($0.id) }))
        }
        .onChange(of: selectedLocal) { _, id in if id != nil { selectedMoment = nil } }
        .onChange(of: selectedMoment) { _, id in
            if id != nil { selectedLocal = nil }
            if let m = allMoments.first(where: { $0.id == id }) { reviews.markReviewed(m) }
        }
    }

    // MARK: Sidebar: days, with what happened marked in colour

    private var sidebar: some View {
        List(selection: $sidebarSel) {
            Section {
                HStack(spacing: 8) {
                    Label("Parcels", systemImage: "shippingbox")
                    Spacer()
                    let today = parcels.expectedToday.count
                    if today > 0 {
                        Text("\(today) today").font(DS.meta).foregroundStyle(DS.porchlight)
                    } else if !parcels.active.isEmpty {
                        Text("\(parcels.active.count)").font(DS.meta).foregroundStyle(.secondary)
                    }
                }
                .tag(SidebarItem.parcels)
            }
            Section {
                ForEach(days, id: \.self) { day in
                    DayRow(day: day,
                           moments: allMoments.filter { Calendar.current.isDate($0.end, inSameDayAs: day) },
                           reviewed: reviews.reviewed)
                        .tag(SidebarItem.day(day))
                }
            } header: {
                if model.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Fetching older history")
                    }
                } else {
                    Text("Days")
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: The day: timeline across cameras, then Moments as thumbnails

    private var dayContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let day = selectedDay {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(day, format: .dateTime.weekday(.wide).day().month(.wide))
                            .font(DS.display)
                            .foregroundStyle(DS.paper)
                        Text(summary)
                            .font(DS.body)
                            .foregroundStyle(DS.ash)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    DayStrip(
                        devices: camera == nil ? devices : devices.filter { $0.id == camera },
                        events: model.events,
                        now: Date(),
                        liveDeviceIds: [],
                        onPlay: { e in selectedMoment = allMoments.first { $0.events.contains { $0.id == e.id } }?.id },
                        range: Calendar.current.startOfDay(for: day)...Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: day))!,
                        tickStepHours: 3,
                        showsNowEdge: false
                    )

                    if let day = selectedDay, !localClips.clips(on: day).isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Recorded on this Mac").font(DS.bodyStrong).foregroundStyle(DS.paper)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(localClips.clips(on: day)) { c in
                                        Button { selectedLocal = c.id } label: {
                                            LocalClipCard(clip: c, isSelected: selectedLocal == c.id)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Recording, \(c.deviceName), \(c.start.formatted(date: .omitted, time: .shortened))")
                                    }
                                }
                            }
                        }
                    }

                    if dayMoments.isEmpty {
                        Text(filter == .all ? "Nothing recorded." : "No \(filter.rawValue.lowercased()) moments.")
                            .font(DS.body)
                            .foregroundStyle(DS.ash)
                            .padding(.top, 20)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: 14)],
                                  alignment: .leading, spacing: 18) {
                            ForEach(dayMoments) { m in
                                Button { selectedMoment = m.id } label: {
                                    MomentCard(moment: m,
                                               isSelected: m.id == selectedMoment,
                                               isUnreviewed: m.tier >= .people && !reviews.isReviewed(m),
                                               scenery: scenery[m.deviceKey] ?? [])
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(m.title), \(m.end.formatted(date: .omitted, time: .shortened))")
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.night)
    }

    /// Everything matching the search, newest first, across all loaded days.
    private var searchResults: some View {
        let search = MomentSearch(query)
        let hits = allMoments.filter { filter.includes($0) && search.matches($0) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\u{201C}\(query)\u{201D}").font(DS.display).foregroundStyle(DS.paper)
                    Text(hits.isEmpty ? "Nothing matches in the last \(days.count) days." : hits.count == 1 ? "1 moment" : "\(hits.count) moments")
                        .font(DS.body).foregroundStyle(DS.ash)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: 14)], alignment: .leading, spacing: 18) {
                    ForEach(hits.prefix(120)) { m in
                        Button { selectedMoment = m.id } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                MomentCard(moment: m, isSelected: m.id == selectedMoment,
                                           isUnreviewed: m.tier >= .people && !reviews.isReviewed(m),
                                           scenery: scenery[m.deviceKey] ?? [])
                                Text(m.end, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                                    .font(DS.meta).foregroundStyle(DS.ash)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.night)
    }

    private var summary: String {
        DailyBrief.text(for: dayMoments, parcels: parcels.parcels, day: selectedDay ?? Date())
    }

    private func makeReel() {
        guard let day = selectedDay else { return }
        reelStatus = "Starting…"
        let moments = allMoments
        Task {
            do {
                let url = try await HighlightReel.make(day: day, moments: moments) { text in
                    Task { @MainActor in reelStatus = text }
                }
                reelStatus = nil
                NSWorkspace.shared.open(url)
            } catch {
                reelStatus = nil
                let alert = NSAlert()
                alert.messageText = "Couldn't make the video"
                alert.informativeText = "This day needs at least one visit with a clip from Ring or a recording on this Mac."
                alert.runModal()
            }
        }
    }

    private func makeTimeLapse() {
        guard let day = selectedDay else { return }
        timelapseStatus = "Making…"
        Task {
            var made: [URL] = []
            for d in devices {
                let stills = await Snapshotter.stills(day: day, camera: d.name)
                guard stills.count >= 4 else { continue }
                let out = LocalClipStore.folder.appendingPathComponent(
                    "\(day.formatted(.iso8601.year().month().day()))/\(d.name) time-lapse.mp4")
                try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? await TimeLapse.make(from: stills, to: out)) != nil { made.append(out) }
            }
            timelapseStatus = nil
            if made.isEmpty {
                let alert = NSAlert()
                alert.messageText = "No stills for this day"
                alert.informativeText = "Turn on Settings › Recording › Time-lapse and Doorstep will take a still from battery cameras every few minutes."
                alert.runModal()
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(made)
            }
        }
    }

    /// Jump to the Moment that contains this clip.
    private func watch(_ eventId: String) {
        guard let m = allMoments.first(where: { $0.events.contains { $0.id == eventId } }) else { return }
        filter = .all
        sidebarSel = .day(Calendar.current.startOfDay(for: m.end))
        selectedMoment = m.id
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Show", selection: $filter) {
                ForEach(HistoryFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
        }
        ToolbarItem {
            Picker("Camera", selection: $camera) {
                Text("All cameras").tag(Int?.none)
                Divider()
                ForEach(devices, id: \.id) { Text($0.name).tag(Int?.some($0.id)) }
            }
            .frame(width: 150)
        }
        ToolbarItem {
            Button {
                makeReel()
            } label: {
                Label(reelStatus ?? "Day in 60 seconds", systemImage: "film.stack")
            }
            .help("A short video of this day's visits, with times and what happened")
            .disabled(selectedDay == nil || reelStatus != nil)
        }
        ToolbarItem {
            Button {
                makeTimeLapse()
            } label: {
                Label(timelapseStatus ?? "Time-lapse", systemImage: "timelapse")
            }
            .help("Make a time-lapse of this day from battery-camera stills")
            .disabled(selectedDay == nil || timelapseStatus != nil)
        }
        ToolbarItem {
            Button {
                reviews.markAllReviewed(dayMoments)
            } label: {
                Label("Mark day as seen", systemImage: "checkmark.circle")
            }
            .help("Mark this day's moments as seen")
        }
    }
}

// MARK: - Day row

private struct DayRow: View {
    let day: Date
    let moments: [Moment]
    let reviewed: Set<String>

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.body)
                Text(moments.count == 1 ? "1 moment" : "\(moments.count) moments")
                    .font(DS.meta)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // What needs a look: amber = someone rang, white = a person you haven't seen
            if moments.contains(where: { $0.tier == .doorbell && !reviewed.contains($0.id) }) {
                Circle().fill(DS.porchlight).frame(width: 7, height: 7)
                    .accessibilityLabel("Unseen doorbell")
            } else if moments.contains(where: { $0.tier == .people && !reviewed.contains($0.id) }) {
                Circle().fill(DS.paper).frame(width: 7, height: 7)
                    .accessibilityLabel("Unseen visit")
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

// MARK: - Moment card

private struct MomentCard: View {
    let moment: Moment
    let isSelected: Bool
    let isUnreviewed: Bool
    var scenery: Set<String> = []
    @State private var image: NSImage?
    @State private var tags: [String] = []
    @State private var hovering = false

    /// What this Mac saw, minus this camera's scenery; a parcel event leads.
    private var cardTags: [String] {
        var out: [String] = []
        if moment.parcelTaken { out.append("Parcel taken") } else if moment.parcelLeft { out.append("Parcel left") }
        out += moment.sounds.map(\.rawValue).sorted()
        return out + tags.filter { !scenery.contains($0) && !(out.isEmpty == false && $0 == "Parcel") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A fixed 16:9 frame; the picture fills and is cropped to it
            // (the doorbell's square clips would otherwise stretch the card).
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    ZStack {
                        DS.slate
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .transition(.opacity)
                        }
                    }
                }
                .clipped()
                .overlay(alignment: .topLeading) {
                    if isUnreviewed {
                        Circle()
                            .fill(moment.tier == .doorbell ? DS.porchlight : DS.paper)
                            .frame(width: 8, height: 8)
                            .padding(8)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? DS.paper : .clear, lineWidth: 2)
            )
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(DS.settle, value: hovering)

            VStack(alignment: .leading, spacing: 2) {
                Text(moment.title)
                    .font(moment.tier == .activity ? DS.body : DS.bodyStrong)
                    .foregroundStyle(moment.tier == .activity ? DS.ash : DS.paper)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(moment.end, format: .dateTime.hour().minute())
                        .font(DS.monoMeta)
                    if moment.events.count > 1 {
                        Text("\(moment.events.count) clips").font(DS.meta)
                    }
                    let shown = cardTags
                    if !shown.isEmpty {
                        // What this Mac saw in the clip (minus this camera's scenery).
                        Text(shown.joined(separator: " · "))
                            .font(DS.meta)
                            .foregroundStyle(shown.contains("Parcel taken") ? DS.ember
                                             : shown.contains("Person") || shown.contains("Parcel left") ? DS.paper : DS.ash)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(DS.ash)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .task(id: moment.headline.id) {
            let id = moment.headline.id
            if let img = await ThumbnailCache.shared.cached(id) {
                image = img
                if let known = await ThumbnailCache.shared.tags(for: id) { tags = known }
                let found = await ThumbnailCache.shared.ensureTags(for: id)
                if found != tags { withAnimation(DS.crossfade) { tags = found } }
                return
            }
            let img = await ThumbnailCache.shared.thumbnail(for: id)
            let found = await ThumbnailCache.shared.tags(for: id) ?? []
            withAnimation(DS.crossfade) { image = img; tags = found }
        }
    }
}

// MARK: - Detail: the moment playing

private struct MomentDetail: View {
    let moment: Moment
    @ObservedObject private var identities = IdentityIndex.shared
    @State private var current: RingEvent?
    @State private var player: AVPlayer?
    @State private var clipURL: URL?
    @State private var failed = false
    @State private var fromMac = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    Color.black
                    if DemoMode.isOn, let e = current {
                        Image(nsImage: DemoData.picture(for: e.id)).resizable().aspectRatio(contentMode: .fill)
                    } else if let player {
                        ClipPlayerView(player: player)
                    } else {
                        Text(failed ? "Clip unavailable" : "Loading clip")
                            .font(DS.meta)
                            .foregroundStyle(failed ? DS.ember : DS.ash)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous))

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(moment.title).font(DS.title).foregroundStyle(DS.paper)
                        Text(moment.end, format: .dateTime.weekday(.wide).day().month().hour().minute())
                            .font(DS.body).foregroundStyle(DS.ash)
                    }
                    Spacer()
                    whoMenu
                    if let clipURL {
                        ShareLink(item: clipURL) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    Button {
                        saveClip()
                    } label: {
                        Label("Save clip", systemImage: "square.and.arrow.down")
                    }
                    .disabled(clipURL == nil)
                }

                if fromMac {
                    Label("Recorded on this Mac", systemImage: "internaldrive").font(DS.meta).foregroundStyle(DS.porchlight)
                }
                Text(VideoDescription.text(for: current ?? moment.headline))
                    .font(DS.body).foregroundStyle(DS.paper)
                    .fixedSize(horizontal: false, vertical: true)
                if let line = identityLine {
                    Text(line).font(DS.meta).foregroundStyle(DS.ash)
                }
                if FaceIndex.isEnabled, !DemoMode.isOn {
                    FacesInClip(eventId: (current ?? moment.headline).id)
                }

                if moment.events.count > 1 {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(moment.events.reversed(), id: \.id) { e in
                            Button { load(e) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: e.id == current?.id ? "play.fill" : "play")
                                        .font(.system(size: 10))
                                        .frame(width: 14)
                                    Text(e.createdAt, format: .dateTime.hour().minute().second())
                                        .font(DS.monoBody)
                                    Text(label(e)).font(DS.body)
                                    Spacer()
                                    if let d = e.duration, d > 0 {
                                        Text("\(Int(d))s").font(DS.monoMeta)
                                    }
                                }
                                .foregroundStyle(e.id == current?.id ? DS.paper : DS.ash)
                                .frame(height: 36)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(DS.night)
        .task { load(moment.headline) }
        .onDisappear { player?.pause() }
    }

    /// Correct it, and Doorstep learns: next time it compares new clips against this one.
    private var whoMenu: some View {
        Menu {
            Section("Who was it?") {
                ForEach(Carrier.allCases.filter { !$0.isGrocery }) { c in
                    Button(c.rawValue) { teach(c.rawValue) }
                }
            }
            Section("Groceries") {
                ForEach(Carrier.allCases.filter(\.isGrocery)) { c in
                    Button(c.rawValue) { teach(c.rawValue) }
                }
            }
            Divider()
            Button(TeachStore.notDelivery) { teach(TeachStore.notDelivery) }
        } label: {
            Label(moment.identity?.who ?? "Who was it?", systemImage: "person.crop.square")
        }
        .fixedSize()
        .help("Tell Doorstep who this was. It learns from your answers.")
    }

    private func teach(_ label: String) {
        let id = (current ?? moment.headline).id
        Task { await ThumbnailCache.shared.teach(eventId: id, label: label) }
    }

    private var identityLine: String? {
        guard let id = moment.identity else { return nil }
        var parts: [String] = []
        if let who = id.who {
            switch id.source {
            case .text: parts.append("Read \"\(id.carrier?.rawValue ?? who)\" in the clip")
            case .taught: parts.append("Looks like the \(who) clips you labelled")
            case .livery: parts.append("\(who) going by the colours (a guess)")
            case .you: parts.append("You said \(who)")
            case .claude: parts.append("Claude: \(id.note ?? who)")
            }
        } else if id.source == .you {
            parts.append("You said not a delivery")
        }
        if id.parcelLeft { parts.append("a parcel appeared on the doorstep") }
        if id.parcelTaken { parts.append("a parcel was taken from the doorstep") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func label(_ e: RingEvent) -> String {
        switch MomentTier.of(e) {
        case .doorbell: return "Doorbell"
        case .people: return "Person"
        case .activity: return "Activity"
        }
    }

    private func load(_ e: RingEvent) {
        current = e
        if DemoMode.isOn { return }
        player?.pause()
        player = nil
        clipURL = nil
        failed = false
        Task {
            do {
                let url = try await RingClient.shared.getEventVideoURL(eventId: e.id)
                guard current?.id == e.id else { return }
                clipURL = url
                let p = AVPlayer(url: url)
                p.play()
                player = p
            } catch {
                guard current?.id == e.id else { return }
                // No video from Ring (no subscription, or gone): use this Mac's recording.
                if let local = LocalClipStore.shared.clip(deviceId: e.deviceId, around: e.createdAt) {
                    clipURL = local.url
                    fromMac = true
                    let p = AVPlayer(url: local.url)
                    p.play()
                    player = p
                } else {
                    failed = true
                }
            }
        }
    }

    private func saveClip() {
        guard let clipURL, let e = current else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        let stamp = e.createdAt.formatted(.iso8601.year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        panel.nameFieldStringValue = "\(e.deviceName ?? "Camera") \(stamp).mp4"
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: clipURL, to: dest)
        }
    }
}


// MARK: - Recordings made on this Mac

private struct LocalClipCard: View {
    let clip: LocalClip
    let isSelected: Bool
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                DS.slate
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            }
            .frame(width: 168, height: 95)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isSelected ? DS.paper : .clear, lineWidth: 2))
            .overlay(alignment: .topLeading) {
                Image(systemName: "record.circle").font(.system(size: 11)).foregroundStyle(DS.porchlight).padding(6)
            }
            Text("\(clip.reason) at \(clip.deviceName)").font(DS.bodyStrong).foregroundStyle(DS.paper).lineLimit(1)
            HStack(spacing: 6) {
                Text(clip.start, format: .dateTime.hour().minute()).font(DS.monoMeta)
                Text("\(Int(clip.end.timeIntervalSince(clip.start)))s").font(DS.meta)
            }
            .foregroundStyle(DS.ash)
        }
        .frame(width: 168)
        .task(id: clip.id) {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
            g.maximumSize = CGSize(width: 400, height: 400)
            if let (cg, _) = try? await g.image(at: CMTime(seconds: 2, preferredTimescale: 600)) {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }
}

private struct LocalClipDetail: View {
    let clip: LocalClip
    @State private var player: AVPlayer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    Color.black
                    if let player { ClipPlayerView(player: player) }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous))
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(clip.reason) at \(clip.deviceName)").font(DS.title).foregroundStyle(DS.paper)
                        Text(clip.start, format: .dateTime.weekday(.wide).day().month().hour().minute().second())
                            .font(DS.body).foregroundStyle(DS.ash)
                    }
                    Spacer()
                    ShareLink(item: clip.url) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                }
                Label("Recorded on this Mac", systemImage: "internaldrive").font(DS.meta).foregroundStyle(DS.porchlight)
            }
            .padding(20)
        }
        .background(DS.night)
        .task {
            let p = AVPlayer(url: clip.url)
            p.play()
            player = p
        }
        .onDisappear { player?.pause() }
    }
}
