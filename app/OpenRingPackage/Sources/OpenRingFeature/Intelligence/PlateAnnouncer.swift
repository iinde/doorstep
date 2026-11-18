import Foundation
import UserNotifications

/// "Your car got home": only for plates you've named, once per arrival.
enum PlateAnnouncer {
    static func announce(_ plate: String, camera: String) async {
        guard let name = PlateIndex.shared.name(plate) else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(name) is here"
        content.body = "\(PlateIndex.pretty(plate)) at \(camera), \(Date().formatted(date: .omitted, time: .shortened))."
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "plate-\(plate)-\(Int(Date().timeIntervalSince1970 / 600))", content: content, trigger: nil))
        NSLog("🚗 \(name) at \(camera)")
    }
}
