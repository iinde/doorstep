import Foundation
import AppKit
import UserNotifications
import RingClient

// MARK: - Notification Manager

public final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = NotificationManager()

    private let seenEventsKey = "seenEventIds"
    public static let watchCategory = "doorstep.watch"
    /// Set by the app: show this camera live (from a notification's Watch door button or a tap).
    @MainActor public var onWatchDevice: ((Int) -> Void)?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Permission

    public func requestPermission() async -> Bool {
        do {
            let center = UNUserNotificationCenter.current()
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            let watch = UNNotificationAction(identifier: "watch", title: "Watch door", options: [.foreground])
            center.setNotificationCategories([
                UNNotificationCategory(identifier: Self.watchCategory, actions: [watch], intentIdentifiers: [])
            ])
            NSLog("🔔 Notification permission: \(granted ? "granted" : "denied")")
            return granted
        } catch {
            NSLog("🔔 Notification permission error: \(error)")
            return false
        }
    }

    // MARK: - Send Notification

    /// Says who, with a snapshot. Waits (briefly) for this Mac to look at the clip first;
    /// if the clip isn't ready yet, sends the plain version instead of holding it back.
    /// `notify: false` still looks at the clip and runs automations, but shows nothing.
    public func sendNotification(for event: RingEvent, notify: Bool = true) async {
        guard event.kind == .ding || event.kind == .motion else { return }
        EventDirectory.shared.register([event])
        let snapshot: NSImage? = await withTaskGroup(of: NSImage?.self) { group in
            group.addTask { await ThumbnailCache.shared.thumbnail(for: event.id) }
            group.addTask { try? await Task.sleep(for: .seconds(15)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        let content = UNMutableNotificationContent()
        let camera = event.deviceName ?? "your door"
        let identity = IdentityIndex.shared.identity(event.id)
        let tier = MomentTier.of(event)
        let tags = await ThumbnailCache.shared.tags(for: event.id) ?? []
        let familiar = FaceIndex.shared.names(for: event.id).first
        let unusual = AlertPolicy.isUnusual(event)
        let kinds = AlertPolicy.kinds(for: event, identity: identity, tags: tags, familiar: familiar, unusual: unusual)
        // The headline: the most important thing about it.
        if identity?.parcelTaken == true {
            content.title = "Parcel taken from \(camera)"
        } else if let familiar {
            content.title = event.kind == .ding ? "\(familiar) rang" : "\(familiar) is at \(camera)"
        } else if let who = identity?.who {
            content.title = event.kind == .ding ? "\(who) rang" : "\(who) at \(camera)"
        } else if identity?.parcelLeft == true {
            content.title = "Parcel left at \(camera)"
        } else if event.kind == .ding {
            content.title = "Someone rang \(camera)"
        } else if unusual {
            content.title = "Unusual: someone at \(camera)"
        } else if tier == .people {
            content.title = "Person at \(camera)"
        } else if tags.contains("Vehicle") {
            content.title = "Vehicle at \(camera)"
        } else if kinds.contains(.animals) {
            content.title = "Animal at \(camera)"
        } else {
            content.title = "Movement at \(camera)"
        }
        // The body: a plain sentence describing the clip.
        content.body = VideoDescription.text(for: event, tags: tags)
        if Busy.alertSound { content.sound = .default }

        // Automations and announcements (doorbell presses fire from the faster doorbell watch).
        await MainActor.run {
            let a = Automations.shared
            if identity?.parcelTaken == true { a.fire(.parcelTaken, camera: camera, detail: "") }
            else if identity?.parcelLeft == true { a.fire(.parcelLeft, camera: camera, detail: identity?.who ?? "") }
            if let who = identity?.who, identity?.isDelivery == true { a.fire(.delivery, camera: camera, detail: "\(who) at the \(camera.lowercased())") }
            if tier >= .people && event.kind != .ding { a.fire(.person, camera: camera, detail: identity?.who ?? "") }
        }
        // Home Assistant (if connected): every event, with who, the description and the picture.
        if let cam = event.deviceId {
            let haKind: DoorstepEventKind = identity?.parcelTaken == true ? .parcelTaken
                : identity?.parcelLeft == true ? .parcelLeft
                : familiar != nil ? .familiarFace
                : event.kind == .ding ? .doorbell
                : identity?.isDelivery == true ? .delivery
                : unusual ? .unusual
                : tier >= .people ? .person : .motion
            let jpeg = snapshot.flatMap { $0.tiffRepresentation }.flatMap { NSBitmapImageRep(data: $0) }?
                .representation(using: .jpeg, properties: [.compressionFactor: 0.7])
            let who = familiar ?? identity?.who ?? (tier >= .people ? "Person" : nil)
            let body = content.body
            await HomeAssistantBridge.shared.publishEvent(cameraId: String(cam), cameraName: camera, kind: haKind,
                                                          who: who, description: body, snapshotJPEG: jpeg, at: event.createdAt)
        }
        let allowed = await MainActor.run { AlertPolicy.shouldAlert(kinds, camera: event.deviceId) }
        guard notify, allowed else { markEventAsSeen(event.id); return }
        content.userInfo = ["eventId": event.id, "watchDevice": event.deviceId ?? 0]
        content.categoryIdentifier = Self.watchCategory
        content.threadIdentifier = camera

        if let snapshot, let tiff = snapshot.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("doorstep-\(event.id).jpg")
            if (try? jpeg.write(to: url)) != nil,
               let att = try? UNNotificationAttachment(identifier: "snapshot", url: url) {
                content.attachments = [att]
            }
        }

        // Single event alerts: within 3 minutes on the same camera, update the alert that's
        // already there instead of adding another.
        var identifier = event.id
        if AlertPolicy.singleEventAlerts, let cam = event.deviceId {
            let key = "lastAlert.\(cam)"
            let d = UserDefaults.standard
            if let last = d.object(forKey: key) as? Date, event.createdAt.timeIntervalSince(last) < 180,
               let previous = d.string(forKey: key + ".id") {
                identifier = previous
                content.sound = nil
            }
            d.set(event.createdAt, forKey: key)
            d.set(identifier, forKey: key + ".id")
        }
        let jpegForPhone: Data? = snapshot.flatMap { $0.tiffRepresentation }.flatMap { NSBitmapImageRep(data: $0) }?
            .representation(using: .jpeg, properties: [.compressionFactor: 0.75])
        let phoneTitle = content.title, phoneBody = content.body
        Task.detached { await PhoneAlerts.send(title: phoneTitle, body: phoneBody, image: jpegForPhone) }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            NSLog("🔔 \(content.title): \(content.body)")
            markEventAsSeen(event.id)
        } catch {
            NSLog("🔔 Failed to send notification: \(error)")
        }
    }

    // MARK: - Detect New Events

    public func detectNewEvents(old: [RingEvent], new: [RingEvent]) -> [RingEvent] {
        let oldIds = Set(old.map { $0.id })
        let seenIds = getSeenEventIds()
        let twoMinutesAgo = Date().addingTimeInterval(-120)

        return new.filter { event in
            // Must be a new event (not in old list and not previously seen)
            let isNew = !oldIds.contains(event.id) && !seenIds.contains(event.id)
            // Must be recent (within 2 minutes) to avoid spam on launch
            let isRecent = event.createdAt > twoMinutesAgo
            // Only ding and motion events
            let isNotifiable = event.kind == .ding || event.kind == .motion

            return isNew && isRecent && isNotifiable
        }
    }

    // MARK: - Seen Events Persistence

    private func getSeenEventIds() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: seenEventsKey) ?? []
        return Set(array)
    }

    private func markEventAsSeen(_ eventId: String) {
        var seen = getSeenEventIds()
        seen.insert(eventId)

        // Keep only last 100 events to prevent unbounded growth
        let array = Array(seen.suffix(100))
        UserDefaults.standard.set(array, forKey: seenEventsKey)
    }

    // MARK: - Delegate Methods

    // Handle notification when app is in foreground
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Show banner even when app is open
        return [.banner, .sound]
    }

    // Handle notification tap
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier,
              let device = info["watchDevice"] as? Int, device != 0 else { return }
        await MainActor.run { NotificationManager.shared.onWatchDevice?(device) }
    }
}
