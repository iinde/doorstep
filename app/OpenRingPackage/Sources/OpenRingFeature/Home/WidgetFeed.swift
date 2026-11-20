import Foundation
import AppKit
import WidgetKit
import RingClient

/// Leaves the latest picture from each camera and a line about today in the folder shared
/// with the desktop widget, at most every five minutes. No new Ring requests: it uses the
/// thumbnails Doorstep already has.
@MainActor
public enum WidgetFeed {
    public static let group = "52YKC7J3T7.com.openring.doorstep"
    private static var last = Date.distantPast

    static var folder: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/\(group)")
    }

    struct Feed: Codable {
        struct Camera: Codable { var name: String; var image: String?; var at: Date? }
        var updated: Date
        var summary: String
        var cameras: [Camera]
        var due: Int
        var mode: String?
    }

    public static func update(devices: [RingDevice], events: [RingEvent], force: Bool = false) {
        guard force || Date().timeIntervalSince(last) > 300 else { return }
        last = Date()
        let cams = devices.filter { $0.deviceType == .doorbell || $0.deviceType == .camera }.prefix(4)
        let summary = DailyBrief.text(for: MomentBuilder.build(from: events), parcels: ParcelStore.shared.parcels, day: Date())
        let due = ParcelStore.shared.parcels.filter(\.isExpectedToday).count
        let mode = Modes.shared.enabled ? Modes.shared.current.rawValue : nil
        Task {
            let dir = folder
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var out: [Feed.Camera] = []
            for d in cams {
                let latest = events.filter { $0.deviceId == d.id && MomentBuilder.isOutsideEvent($0) }.max { $0.createdAt < $1.createdAt }
                var file: String?
                let image: NSImage? = DemoMode.isOn ? DemoData.live(d.id) : (latest == nil ? nil : await ThumbnailCache.shared.thumbnail(for: latest!.id))
                if let image, let jpeg = jpeg(image) {
                    file = "camera-\(d.id).jpg"
                    try? jpeg.write(to: dir.appendingPathComponent(file!), options: .atomic)
                }
                out.append(Feed.Camera(name: d.name, image: file, at: latest?.createdAt))
            }
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(Feed(updated: Date(), summary: summary, cameras: out, due: due, mode: mode)) {
                try? data.write(to: dir.appendingPathComponent("widget.json"), options: .atomic)
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private static func jpeg(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let scale = min(1, 640 / Double(max(w, 1)))
        guard scale < 1 else { return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) }
        let size = NSSize(width: Double(w) * scale, height: Double(h) * scale)
        let small = NSImage(size: size)
        small.lockFocus(); image.draw(in: NSRect(origin: .zero, size: size)); small.unlockFocus()
        guard let t = small.tiffRepresentation, let r = NSBitmapImageRep(data: t) else { return nil }
        return r.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}
