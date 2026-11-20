import Foundation
import UserNotifications
import RingClient

/// A camera that was online and suddenly isn't: tell you straight away (it can mean someone
/// unplugged or covered it), not just once a day. In Away mode it's worded more strongly.
@MainActor
public final class TamperWatch {
    public static let shared = TamperWatch()
    private var online: [Int: Bool] = [:]

    public static var isEnabled: Bool { UserDefaults.standard.object(forKey: "tamperAlerts") as? Bool ?? true }

    public func check(_ devices: [RingDevice]) {
        guard !DemoMode.isOn else { return }
        for d in devices where d.deviceType == .doorbell || d.deviceType == .camera {
            let was = online[d.id]
            online[d.id] = d.isOnline
            guard Self.isEnabled, was == true, !d.isOnline else { continue }
            let away = Modes.shared.enabled && Modes.shared.current == .away
            let title = away ? "\(d.name) went offline while you're away" : "\(d.name) just went offline"
            let body = d.isBatteryPowered && (d.batteryLevel ?? 100) <= 10
                ? "Its battery was nearly flat."
                : "If nobody unplugged it, it may have lost power or Wi-Fi, or been tampered with."
            Task {
                let c = UNMutableNotificationContent()
                c.title = title
                c.body = body
                if Busy.alertSound { c.sound = .default }
                c.interruptionLevel = away ? .timeSensitive : .active
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "tamper-\(d.id)-\(Date().timeIntervalSince1970)", content: c, trigger: nil))
                await PhoneAlerts.send(title: title, body: body, image: nil)
            }
            NSLog("📴 \(d.name) went offline")
        }
    }
}
