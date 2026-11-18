import Foundation
import AppKit
import AVFoundation
import UserNotifications
import RingClient

/// The day in one line, written on this Mac from Moments and parcels.
public enum DailyBrief {
    public static func text(for moments: [Moment], parcels: [Parcel], day: Date) -> String {
        let cal = Calendar.current
        let today = moments.filter { cal.isDate($0.end, inSameDayAs: day) }
        guard !today.isEmpty || parcels.contains(where: { $0.deliveredAt.map { cal.isDate($0, inSameDayAs: day) } ?? false }) else {
            return "Nothing recorded."
        }
        var parts: [String] = []

        // Deliveries: who came (from the clips) plus parcels marked delivered that day.
        let deliveryMoments = today.filter { $0.identity?.isDelivery == true || $0.parcelLeft }
        let carriers = Array(Set(deliveryMoments.compactMap { $0.identity?.carrier?.rawValue })).sorted()
        let delivered = parcels.filter { $0.deliveredAt.map { cal.isDate($0, inSameDayAs: day) } ?? false }
        let deliveries = max(deliveryMoments.count, delivered.count)
        if deliveries > 0 {
            var s = deliveries == 1 ? "1 delivery" : "\(deliveries) deliveries"
            if !carriers.isEmpty { s += " (\(carriers.joined(separator: ", ")))" }
            parts.append(s)
        }
        if today.contains(where: \.parcelTaken) { parts.append("a parcel was taken") }

        let rings = today.filter { $0.tier == .doorbell }.count
        if rings > 0 { parts.append(rings == 1 ? "1 ring" : "\(rings) rings") }
        let visits = today.filter { $0.tier == .people && $0.identity?.isDelivery != true }.count
        if visits > 0 { parts.append(visits == 1 ? "1 visit" : "\(visits) visits") }

        if let first = today.map(\.start).min(), let last = today.map(\.end).max(), today.count > 1 {
            let f = Date.FormatStyle().hour().minute()
            parts.append("first \(first.formatted(f)), last \(last.formatted(f))")
        }
        // Overnight: midnight to 6am.
        let night = today.filter { cal.component(.hour, from: $0.end) < 6 }
        parts.append(night.isEmpty ? "quiet overnight" : (night.count == 1 ? "1 moment overnight" : "\(night.count) moments overnight"))
        parts.append(today.count == 1 ? "1 moment" : "\(today.count) moments")
        let s = parts.joined(separator: " · ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// Once a day at the time set in Settings (default 20:00), if switched on.
    @MainActor
    public static func sendIfDue(events: [RingEvent]) async {
        let d = UserDefaults.standard
        guard d.bool(forKey: "dailyBriefEnabled") else { return }
        let hour = d.object(forKey: "dailyBriefHour") as? Int ?? 20
        let now = Date()
        let key = now.formatted(.iso8601.year().month().day())
        guard Calendar.current.component(.hour, from: now) >= hour, d.string(forKey: "dailyBriefSent") != key else { return }
        d.set(key, forKey: "dailyBriefSent")
        let content = UNMutableNotificationContent()
        content.title = "Today at home"
        content.body = text(for: MomentBuilder.build(from: events), parcels: ParcelStore.shared.parcels, day: now)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "brief-\(key)", content: content, trigger: nil))
    }
}

/// Keeps People and Doorbell clips in a folder you choose (a NAS share works), so they
/// outlive Ring's history window. Off until a folder is picked.
public actor ClipArchive {
    public static let shared = ClipArchive()
    private var done: Set<String> = []
    private let bookmarkKey = "archiveBookmark"

    public static var isOn: Bool { UserDefaults.standard.data(forKey: "archiveBookmark") != nil }

    public static func folderName() -> String? {
        guard let data = UserDefaults.standard.data(forKey: "archiveBookmark") else { return nil }
        var stale = false
        return (try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale))?.path
    }

    @MainActor
    public static func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Archive here"
        panel.message = "Doorstep will copy People and Doorbell clips into this folder."
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        UserDefaults.standard.set(data, forKey: "archiveBookmark")
    }

    public static func stop() { UserDefaults.standard.removeObject(forKey: "archiveBookmark") }

    /// Copy any new People/Doorbell clips from the last day. Each clip once.
    public func archive(_ events: [RingEvent]) async {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        guard let root = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) else { return }
        // Only needed (and only true) when sandboxed; harmless otherwise.
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let wanted = events.filter {
            MomentBuilder.isOutsideEvent($0) && MomentTier.of($0) >= .people
                && $0.createdAt > Date().addingTimeInterval(-86400) && !done.contains($0.id)
        }
        let fm = FileManager.default
        for e in wanted {
            let day = e.createdAt.formatted(.iso8601.year().month().day())
            let dir = root.appendingPathComponent(day, isDirectory: true)
            let time = e.createdAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                .replacingOccurrences(of: ":", with: "-")
            let dest = dir.appendingPathComponent("\(e.deviceName ?? "Camera") \(time) \(e.id).mp4")
            if fm.fileExists(atPath: dest.path) { done.insert(e.id); continue }
            guard let tmp = try? await RingClient.shared.getEventVideoURL(eventId: e.id) else { continue }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? fm.copyItem(at: tmp, to: dest)) != nil {
                done.insert(e.id)
                NSLog("🗄 Archived \(dest.lastPathComponent)")
            }
        }
    }
}
