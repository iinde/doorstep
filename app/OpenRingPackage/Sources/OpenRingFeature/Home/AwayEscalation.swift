import SwiftUI
import AppKit
import UserNotifications
import RingClient

/// "Nobody's home": in Away mode, someone hanging around gets more than one quiet alert.
/// Each step is its own switch, and only the light and the spoken warning reach the outside.
@MainActor
public enum AwayEscalation {
    public static let defaultWarning = "Hello. You're on camera and this is being recorded."
    static var d: UserDefaults { .standard }
    public static var isEnabled: Bool { d.object(forKey: "awayEscalate") as? Bool ?? true }
    static var lightOn: Bool { d.bool(forKey: "awayLight") }
    static var speak: Bool { d.bool(forKey: "awaySpeak") }
    static var warning: String {
        let w = (d.string(forKey: "awayWarning") ?? "").trimmingCharacters(in: .whitespaces)
        return w.isEmpty ? defaultWarning : w
    }
    public static var isAway: Bool { Modes.shared.enabled && Modes.shared.current == .away }

    /// Someone has hung around a camera while you're away. Returns true if it handled the alert.
    public static func loitered(_ device: RingDevice, seconds: Int) -> Bool {
        guard isEnabled, isAway, !DemoMode.isOn else { return false }
        Task {
            let picture = try? await RingClient.shared.getSnapshot(deviceId: device.id)
            let c = UNMutableNotificationContent()
            c.title = "Someone's at \(device.name) while you're away"
            c.body = "They've been there for \(seconds) seconds."
            c.userInfo = ["watchDevice": device.id]
            c.categoryIdentifier = NotificationManager.watchCategory
            c.interruptionLevel = .timeSensitive
            if Busy.alertSound { c.sound = .defaultCritical }
            if let picture {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("doorstep-away-\(device.id).jpg")
                if (try? picture.write(to: url)) != nil, let a = try? UNNotificationAttachment(identifier: "picture", url: url) { c.attachments = [a] }
            }
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "away-\(device.id)-\(Date().timeIntervalSince1970)", content: c, trigger: nil))
            await PhoneAlerts.send(title: c.title, body: c.body, image: picture)
            if lightOn, device.hasFloodlight { try? await RingClient.shared.setFloodlight(deviceId: device.id, enabled: true) }
            if speak { await SpokenReplies.shared.say(warning, on: device) }
            NSLog("🏠 Away escalation at \(device.name) after \(seconds)s")
        }
        return true
    }
}

struct AwayEscalationSection: View {
    @AppStorage("awayEscalate") private var on = true
    @AppStorage("awayLight") private var light = false
    @AppStorage("awaySpeak") private var speak = false
    @AppStorage("awayWarning") private var warning = ""

    var body: some View {
        Section {
            Toggle("Step it up when I'm away", isOn: $on)
            if on {
                Toggle("Turn the camera's light on (cameras with lights)", isOn: $light)
                Toggle("Say a warning through the camera", isOn: $speak)
                if speak {
                    TextField("Warning", text: $warning, prompt: Text(AwayEscalation.defaultWarning), axis: .vertical)
                    Button("Hear it on this Mac") { SpokenReplies.shared.hear(warning.isEmpty ? AwayEscalation.defaultWarning : warning) }
                }
            }
        } header: {
            Text("When nobody's home")
        } footer: {
            Text("In Away mode, someone hanging around (see Loitering below) gets an urgent alert with their picture, on your Mac and your phone. You can also have Doorstep switch on the camera's light or say a warning. The siren is never set off automatically.")
        }
    }
}
