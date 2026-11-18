import Foundation
import AppKit
import RingClient

/// Demo mode (`-DoorstepDemo YES`): made-up cameras, visits and parcels, with illustrated
/// pictures instead of video. For screenshots, videos and trying the app without a Ring
/// account. Nothing is read from or written to your real data while it's on.
public enum DemoMode {
    public static let isOn: Bool = UserDefaults.standard.bool(forKey: "DoorstepDemo")
}

public enum DemoData {
    static let porch = 9001, driveway = 9002, garden = 9003, side = 9004

    public static let devices: [RingDevice] = {
        let json = """
        [
         {"id": \(porch), "description": "Front Door", "device_id": "demo1", "kind": "lpd_v4", "location_id": "demo",
          "latitude": 51.50875, "longitude": -0.16595},
         {"id": \(driveway), "description": "Driveway", "device_id": "demo2", "kind": "cocoa_floodlight", "location_id": "demo",
          "external_connection": true, "latitude": 51.50875, "longitude": -0.16595},
         {"id": \(garden), "description": "Garden", "device_id": "demo3", "kind": "cocoa_floodlight", "location_id": "demo",
          "external_connection": true, "latitude": 51.50875, "longitude": -0.16595},
         {"id": \(side), "description": "Side Gate", "device_id": "demo4", "kind": "stickup_cam_mini_v2", "location_id": "demo",
          "battery_life": 87, "latitude": 51.50875, "longitude": -0.16595}
        ]
        """
        return (try? JSONDecoder().decode([RingDevice].self, from: Data(json.utf8))) ?? []
    }()

    public static func scene(for deviceId: Int?) -> DemoArt.Scene {
        switch deviceId {
        case porch: return .porch
        case driveway: return .driveway
        case garden: return .garden
        default: return .side
        }
    }

    struct Script { let minutesAgo: Int; let device: Int; let kind: String; let person: Bool; let identity: Identity?; let sounds: [DoorSound] }

    /// Today, told as a story; earlier days are generated so the charts have a shape.
    static var today: [Script] {
        func courier(_ c: Carrier, left: Bool = false) -> Identity {
            var id = Identity(carrier: c, isDelivery: true, confidence: 0.9, source: .text)
            id.parcelLeft = left
            return id
        }
        let now = Calendar.current.component(.hour, from: Date()) * 60 + Calendar.current.component(.minute, from: Date())
        let plan: [(Int, Int, String, Bool, Identity?, [DoorSound])] = [
            (7 * 60 + 41, driveway, "motion", true, nil, [.vehicle]),
            (8 * 60 + 2, porch, "motion", true, nil, [.dog]),
            (9 * 60 + 37, porch, "ding", true, courier(.dpd, left: true), []),
            (11 * 60 + 12, porch, "motion", true, courier(.royalMail), []),
            (12 * 60 + 30, garden, "motion", false, nil, []),
            (13 * 60 + 5, side, "motion", true, nil, []),
            (14 * 60 + 48, porch, "motion", true, courier(.amazon), []),
            (15 * 60 + 20, porch, "motion", true, nil, [.knock]),
            (16 * 60 + 2, driveway, "motion", true, nil, []),
            (17 * 60 + 25, porch, "ding", true, nil, []),
            (18 * 60 + 10, garden, "motion", false, nil, [.dog]),
        ]
        return plan.filter { $0.0 < now }.map {
            Script(minutesAgo: now - $0.0, device: $0.1, kind: $0.2, person: $0.3, identity: $0.4, sounds: $0.5)
        }
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]   // what Ring sends
        return f
    }()

    private static func event(id: String, at date: Date, device: Int, kind: String, person: Bool) -> RingEvent? {
        let name = devices.first { $0.id == device }?.name ?? "Camera"
        let json = """
        {"id": "\(id)", "created_at": "\(isoFormatter.string(from: date))", "kind": "\(kind)",
         "doorbot": {"id": \(device), "description": "\(name)"}, "duration": 24, "cv_properties": {"person_detected": \(person)}}
        """
        return try? JSONDecoder().decode(RingEvent.self, from: Data(json.utf8))
    }

    /// Seeds the in-memory stores and returns the events.
    @MainActor
    public static func load() -> [RingEvent] {
        var events: [RingEvent] = []
        for (i, s) in today.enumerated() {
            let id = "demo-today-\(i)"
            guard let e = event(id: id, at: Date().addingTimeInterval(-Double(s.minutesAgo) * 60), device: s.device,
                                kind: s.kind, person: s.person) else { continue }
            events.append(e)
            if let ident = s.identity { IdentityIndex.shared.set(id, ident) }
            if !s.sounds.isEmpty { SoundIndex.shared.set(id, s.sounds) }
        }
        // Thirteen earlier days: mornings and evenings busy, nights quiet, the postie mid-morning.
        var rng = SeededRandom(seed: 42)
        for d in 1...13 {
            let day = Calendar.current.startOfDay(for: Date().addingTimeInterval(-Double(d) * 86400))
            let count = 12 + Int(rng.next() % 14)
            for k in 0..<count {
                let hour = [7, 8, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 17, 18, 19, 20, 21, 2][Int(rng.next() % 18)]
                let at = day.addingTimeInterval(Double(hour * 3600 + Int(rng.next() % 3600)))
                let device = [porch, porch, porch, driveway, driveway, garden, side][Int(rng.next() % 7)]
                let person = rng.next() % 3 != 0
                let kind = device == porch && rng.next() % 9 == 0 ? "ding" : "motion"
                let id = "demo-\(d)-\(k)"
                if let e = event(id: id, at: at, device: device, kind: kind, person: person) { events.append(e) }
            }
            // The postie, most days, 10:50 to 11:40.
            if d % 7 != 0, let e = event(id: "demo-post-\(d)", at: day.addingTimeInterval(Double(10 * 3600 + 50 * 60 + Int(rng.next() % 3000))),
                                        device: porch, kind: "motion", person: true) {
                events.append(e)
                IdentityIndex.shared.set(e.id, Identity(carrier: .royalMail, isDelivery: true, confidence: 0.9, source: .text))
            }
            if d % 3 == 0, let e = event(id: "demo-dpd-\(d)", at: day.addingTimeInterval(Double(13 * 3600 + Int(rng.next() % 9000))),
                                        device: porch, kind: "ding", person: true) {
                events.append(e)
                IdentityIndex.shared.set(e.id, Identity(carrier: [.dpd, .evri, .amazon][d % 3], isDelivery: true, confidence: 0.9, source: .text))
            }
        }
        EventDirectory.shared.registerDevices(devices)
        EventDirectory.shared.register(events)

        // Parcels: one on its way, one out for delivery today, one that came this morning.
        let store = ParcelStore.shared
        store.expect(tracking: "H01HYA0012345678", carrier: .evri, shop: "ASOS", expected: Date())
        store.ingest(ParcelParser.parse(subject: "Your parcel is out for delivery", from: "Evri <noreply@evri.com>",
                                        body: "Parcel H01HYA0012345678 is out for delivery today."))
        store.expect(tracking: "1Z999AA10123456784", carrier: .ups, shop: "Apple",
                     expected: Calendar.current.date(byAdding: .day, value: 2, to: Date()))
        store.ingest(ParcelParser.parse(subject: "Delivered", from: "DPD <noreply@dpd.co.uk>",
                                        body: "Your order from Currys has been delivered. Parcel number 15501234567890.",
                                        date: Date().addingTimeInterval(-Double(today.first { $0.identity?.carrier == .dpd }?.minutesAgo ?? 300) * 60)))
        store.link(moments: MomentBuilder.build(from: events), doorbellKeys: [String(porch)])

        // Example automations (in memory only).
        Automations.shared.rules = [
            Automation(trigger: .approaching, shortcut: "Porch light on", onlyAfterDark: true, camera: "Front Door"),
            Automation(trigger: .doorbell, shortcut: "Pause music"),
            Automation(trigger: .parcelLeft, shortcut: "Message me a photo"),
        ]

        // The radar and live tiles: someone walking up the path, on a loop.
        Task { @MainActor in
            var t = 0.0
            while true {
                t += 0.5
                let phase = (t.truncatingRemainder(dividingBy: 12)) / 12
                var now = LiveIntel.CameraNow()
                if phase < 0.9 {
                    let grow = 0.2 + phase * 0.45
                    now.people = [CGRect(x: 0.42 - phase * 0.1, y: 0.12, width: grow * 0.45, height: grow)]
                    now.approaching = phase > 0.35
                    now.lastPersonAt = Date()
                }
                now.motion = phase < 0.9 ? 0.06 : 0
                now.updated = Date()
                LiveIntel.shared.update(porch, now)
                var gardenNow = LiveIntel.CameraNow()
                gardenNow.updated = Date()
                if phase > 0.3 && phase < 0.6 { gardenNow.people = [CGRect(x: 0.2 + phase * 0.6, y: 0.2, width: 0.08, height: 0.22)] }
                LiveIntel.shared.update(garden, gardenNow)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        return events.sorted { $0.createdAt > $1.createdAt }
    }

    /// The picture for an event's thumbnail or clip.
    @MainActor
    public static func picture(for eventId: String) -> NSImage {
        let e = EventDirectory.shared.event(eventId)
        let id = IdentityIndex.shared.identity(eventId)
        let visitor: DemoArt.Visitor
        if let c = id?.carrier {
            let colour: NSColor = [.dpd: DemoArt.c(0xD0021B), .royalMail: DemoArt.c(0xE0301E), .amazon: DemoArt.c(0x232F3E),
                                   .evri: DemoArt.c(0x0A6ED1), .ups: DemoArt.c(0x5B3A1E)][c] ?? DemoArt.c(0x3C6E71)
            visitor = .courier(c.rawValue.uppercased().replacingOccurrences(of: "ROYAL MAIL", with: "RM"), colour)
        } else if SoundIndex.shared.sounds(eventId)?.contains(.dog) == true {
            visitor = .dog
        } else if e?.personDetected == true || e?.kind == .ding {
            visitor = .person([DemoArt.c(0x4C6A92), DemoArt.c(0x7A4E6B), DemoArt.c(0x3E7A5E)][abs(eventId.hashValue) % 3])
        } else {
            visitor = .none
        }
        return DemoArt.image(DemoData.scene(for: e?.deviceId), visitor: visitor, time: e?.createdAt ?? Date(), seed: abs(eventId.hashValue) % 5)
    }

    /// What a camera shows "live" in demo mode.
    @MainActor
    public static func live(_ deviceId: Int) -> NSImage {
        let people = LiveIntel.shared.cameras[deviceId]?.people ?? []
        return DemoArt.image(scene(for: deviceId), visitor: people.isEmpty ? .none : .person(DemoArt.c(0x4C6A92)), time: Date())
    }
}

/// Repeatable numbers so the demo history is the same every launch.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
}
