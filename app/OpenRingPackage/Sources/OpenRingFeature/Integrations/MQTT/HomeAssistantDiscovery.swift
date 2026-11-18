import Foundation

/// Topics and Home Assistant MQTT Discovery configs. Pure, so the JSON can be tested.
///
/// Topic layout (base `doorstep`, prefix `homeassistant`):
///
///     doorstep/status                      online | offline     (retained, last will)
///     doorstep/mode                        Home|Away|Night|Quiet (retained)
///     doorstep/mode/set                    command from Home Assistant
///     doorstep/parcels_due                 number (retained)
///     doorstep/camera/<id>/person          ON (auto-off in HA after 60 s)
///     doorstep/camera/<id>/doorbell        ON (auto-off in HA after 30 s)
///     doorstep/camera/<id>/last_visitor    text (retained)
///     doorstep/camera/<id>/last_event      ISO 8601 time (retained)
///     doorstep/camera/<id>/event           JSON attributes of the last event (retained)
///     doorstep/camera/<id>/parcel          none | left | taken (retained)
///     doorstep/camera/<id>/battery         0-100 (retained)
///     doorstep/camera/<id>/snapshot        JPEG bytes (retained)
///     homeassistant/<component>/doorstep_<id>/<object>/config   discovery (retained)
public struct HomeAssistantTopics: Sendable, Equatable {
    public var base: String
    public var discoveryPrefix: String

    public init(base: String = "doorstep", discoveryPrefix: String = "homeassistant") {
        self.base = Self.clean(base, fallback: "doorstep")
        self.discoveryPrefix = Self.clean(discoveryPrefix, fallback: "homeassistant")
    }

    public var availability: String { "\(base)/status" }
    public var mode: String { "\(base)/mode" }
    public var modeSet: String { "\(base)/mode/set" }
    public var parcelsDue: String { "\(base)/parcels_due" }
    public func camera(_ id: String, _ leaf: String) -> String { "\(base)/camera/\(Self.slug(id))/\(leaf)" }
    public func config(_ component: String, node: String, object: String) -> String {
        "\(discoveryPrefix)/\(component)/\(Self.slug(node))/\(object)/config"
    }
    /// Home Assistant announces itself here when it restarts.
    public var homeAssistantStatus: String { "\(discoveryPrefix)/status" }

    /// Topic-safe: letters, digits, `_` and `-` only (no `/`, `+`, `#`).
    public static func slug(_ s: String) -> String {
        let out = s.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
        return out.isEmpty ? "unknown" : out
    }

    static func clean(_ s: String, fallback: String) -> String {
        let parts = s.split(separator: "/").map { String($0).replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "#", with: "") }
            .filter { !$0.isEmpty && !$0.contains(" ") }
        return parts.isEmpty ? fallback : parts.joined(separator: "/")
    }
}

public struct HomeAssistantCamera: Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var hasBattery: Bool
    public var model: String?
    public init(id: String, name: String, hasBattery: Bool = false, model: String? = nil) {
        self.id = id; self.name = name; self.hasBattery = hasBattery; self.model = model
    }
}

public enum HomeAssistantDiscovery {
    public static let manufacturer = "Ring (via Doorstep)"
    public static let modeOptions = ["Home", "Away", "Night", "Quiet"]

    public struct Message: Sendable, Equatable {
        public var topic: String
        public var payload: [UInt8]
    }

    static func hubDevice() -> [String: Any] {
        ["identifiers": ["doorstep_hub"], "name": "Doorstep", "manufacturer": manufacturer, "model": "Doorstep for Mac"]
    }

    static func device(for cam: HomeAssistantCamera) -> [String: Any] {
        var d: [String: Any] = ["identifiers": ["doorstep_\(HomeAssistantTopics.slug(cam.id))"], "name": cam.name,
                                "manufacturer": manufacturer, "via_device": "doorstep_hub"]
        d["model"] = cam.model ?? "Ring camera"
        return d
    }

    static func common(_ t: HomeAssistantTopics, uniqueId: String, name: String?, device: [String: Any]) -> [String: Any] {
        var c: [String: Any] = ["unique_id": uniqueId, "availability_topic": t.availability,
                                "payload_available": "online", "payload_not_available": "offline",
                                "device": device, "origin": ["name": "Doorstep"]]
        // name null = the entity takes the device's name (Home Assistant's convention for a main feature).
        c["name"] = name ?? NSNull()
        return c
    }

    /// The Doorstep hub: mode select and parcels-due sensor.
    public static func hubConfigs(_ t: HomeAssistantTopics) -> [Message] {
        let dev = hubDevice()
        var mode = common(t, uniqueId: "doorstep_mode", name: "Mode", device: dev)
        mode["state_topic"] = t.mode
        mode["command_topic"] = t.modeSet
        mode["options"] = modeOptions
        mode["icon"] = "mdi:shield-home"

        var due = common(t, uniqueId: "doorstep_parcels_due", name: "Parcels due today", device: dev)
        due["state_topic"] = t.parcelsDue
        due["icon"] = "mdi:package-variant-closed"
        due["state_class"] = "measurement"

        return [encode(t.config("select", node: "doorstep", object: "mode"), mode),
                encode(t.config("sensor", node: "doorstep", object: "parcels_due"), due)]
    }

    /// One Home Assistant device per camera.
    public static func cameraConfigs(_ t: HomeAssistantTopics, _ cam: HomeAssistantCamera) -> [Message] {
        let dev = device(for: cam)
        let node = "doorstep_\(HomeAssistantTopics.slug(cam.id))"
        let uid = { (o: String) in "\(node)_\(o)" }
        var out: [Message] = []

        var person = common(t, uniqueId: uid("person"), name: "Person", device: dev)
        person["state_topic"] = t.camera(cam.id, "person")
        person["device_class"] = "occupancy"
        person["off_delay"] = 60
        person["icon"] = "mdi:walk"
        out.append(encode(t.config("binary_sensor", node: node, object: "person"), person))

        var bell = common(t, uniqueId: uid("doorbell"), name: "Doorbell", device: dev)
        bell["state_topic"] = t.camera(cam.id, "doorbell")
        bell["off_delay"] = 30
        bell["icon"] = "mdi:doorbell"
        out.append(encode(t.config("binary_sensor", node: node, object: "doorbell"), bell))

        var visitor = common(t, uniqueId: uid("last_visitor"), name: "Last visitor", device: dev)
        visitor["state_topic"] = t.camera(cam.id, "last_visitor")
        visitor["icon"] = "mdi:account-question"
        out.append(encode(t.config("sensor", node: node, object: "last_visitor"), visitor))

        var last = common(t, uniqueId: uid("last_event"), name: "Last event", device: dev)
        last["state_topic"] = t.camera(cam.id, "last_event")
        last["device_class"] = "timestamp"
        last["json_attributes_topic"] = t.camera(cam.id, "event")
        out.append(encode(t.config("sensor", node: node, object: "last_event"), last))

        var parcel = common(t, uniqueId: uid("parcel"), name: "Parcel", device: dev)
        parcel["state_topic"] = t.camera(cam.id, "parcel")
        parcel["device_class"] = "enum"
        parcel["options"] = ["none", "left", "taken"]
        parcel["icon"] = "mdi:package-variant"
        out.append(encode(t.config("sensor", node: node, object: "parcel"), parcel))

        var image = common(t, uniqueId: uid("snapshot"), name: "Snapshot", device: dev)
        image["image_topic"] = t.camera(cam.id, "snapshot")
        image["content_type"] = "image/jpeg"
        out.append(encode(t.config("image", node: node, object: "snapshot"), image))

        if cam.hasBattery { out.append(batteryConfig(t, cam)) }
        return out
    }

    public static func batteryConfig(_ t: HomeAssistantTopics, _ cam: HomeAssistantCamera) -> Message {
        let node = "doorstep_\(HomeAssistantTopics.slug(cam.id))"
        var b = common(t, uniqueId: "\(node)_battery", name: "Battery", device: device(for: cam))
        b["state_topic"] = t.camera(cam.id, "battery")
        b["device_class"] = "battery"
        b["unit_of_measurement"] = "%"
        b["state_class"] = "measurement"
        b["entity_category"] = "diagnostic"
        return encode(t.config("sensor", node: node, object: "battery"), b)
    }

    static func encode(_ topic: String, _ dict: [String: Any]) -> Message {
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return Message(topic: topic, payload: [UInt8](data))
    }
}
