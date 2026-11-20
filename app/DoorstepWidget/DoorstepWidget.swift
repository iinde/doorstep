import WidgetKit
import SwiftUI
import AppKit

/// What the app leaves in the shared folder for the widget (see WidgetFeed in the app).
struct Feed: Codable {
    struct Camera: Codable { var name: String; var image: String?; var at: Date? }
    var updated: Date
    var summary: String
    var cameras: [Camera]
    var due: Int
    var mode: String?
}

enum Shared {
    static let group = "52YKC7J3T7.com.openring.doorstep"
    static var folder: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    static func load() -> Feed? {
        guard let f = folder, let d = try? Data(contentsOf: f.appendingPathComponent("widget.json")) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Feed.self, from: d)
    }
    static func image(_ name: String?) -> NSImage? {
        guard let name, let f = folder else { return nil }
        return NSImage(contentsOf: f.appendingPathComponent(name))
    }
}

struct Entry: TimelineEntry { let date: Date; let feed: Feed? }

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), feed: nil) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: Date(), feed: Shared.load())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: Date(), feed: Shared.load())], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

private let amber = Color(red: 0.96, green: 0.71, blue: 0.27)

struct CameraTile: View {
    let camera: Feed.Camera
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.opacity(0.3)
            if let img = Shared.image(camera.image) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                Text(camera.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if let at = camera.at {
                    Text(at, style: .relative).font(.system(size: 9)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
            }
            .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct DoorstepWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        if let feed = entry.feed, !feed.cameras.isEmpty {
            switch family {
            case .systemSmall:
                VStack(alignment: .leading, spacing: 6) {
                    CameraTile(camera: feed.cameras[0])
                    Text(feed.summary).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
            default:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Doorstep").font(.system(size: 12, weight: .semibold))
                        if let mode = feed.mode { Text(mode).font(.system(size: 10, weight: .medium)).foregroundStyle(amber) }
                        Spacer()
                        if feed.due > 0 { Label("\(feed.due) due", systemImage: "shippingbox.fill").font(.system(size: 10)).foregroundStyle(amber) }
                    }
                    let shown = Array(feed.cameras.prefix(family == .systemLarge ? 4 : 2))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                        ForEach(shown.indices, id: \.self) { CameraTile(camera: shown[$0]).frame(height: family == .systemLarge ? 110 : 70) }
                    }
                    Text(feed.summary).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(family == .systemLarge ? 4 : 2)
                }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "door.left.hand.open").font(.title2).foregroundStyle(amber)
                Text("Open Doorstep once to fill this in.").font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
        }
    }
}

@main
struct DoorstepWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DoorstepCameras", provider: Provider()) { entry in
            DoorstepWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Doorstep")
        .description("Your cameras' latest pictures and what happened today.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
