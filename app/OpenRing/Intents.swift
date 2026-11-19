import AppIntents
import OpenRingFeature
import RingClient

// Siri and Shortcuts. These run inside Doorstep, so they can open live video.

struct CameraEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Camera"
    static let defaultQuery = CameraQuery()
    let id: Int
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct CameraQuery: EntityQuery {
    func entities(for identifiers: [Int]) async throws -> [CameraEntity] {
        EventDirectory.shared.devices.filter { identifiers.contains($0.id) }.map { CameraEntity(id: $0.id, name: $0.name) }
    }
    func suggestedEntities() async throws -> [CameraEntity] {
        EventDirectory.shared.devices.map { CameraEntity(id: $0.id, name: $0.name) }
    }
}

struct ShowCameraIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Camera"
    static let description = IntentDescription("Shows a camera live in a small window, top right.")
    @Parameter(title: "Camera") var camera: CameraEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let device = EventDirectory.shared.devices.first(where: { $0.id == camera.id }) else {
            return .result(dialog: "I couldn't find that camera.")
        }
        DoorbellCallController.shared.show(device: device, event: nil, title: "\(device.name), live")
        return .result(dialog: "Here's \(device.name).")
    }
}

struct TodayAtHomeIntent: AppIntent {
    static let title: LocalizedStringResource = "What Happened at Home Today"
    static let description = IntentDescription("Deliveries, rings and visits today, in one sentence.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let text = DailyBrief.text(for: MomentBuilder.build(from: EventDirectory.shared.allEvents),
                                   parcels: ParcelStore.shared.parcels, day: Date())
        return .result(value: text, dialog: "\(text)")
    }
}

struct ParcelsTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Parcels Due Today"
    static let description = IntentDescription("Which parcels Doorstep expects today.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let due = ParcelStore.shared.parcels.filter(\.isExpectedToday)
        let text = due.isEmpty ? "No parcels due today."
            : due.map { DeliveryWatch.line(for: $0) }.joined(separator: ". ") + "."
        return .result(value: text, dialog: "\(text)")
    }
}

enum ModeChoice: String, AppEnum {
    case home = "Home", away = "Away", night = "Night", quiet = "Quiet"
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mode"
    static let caseDisplayRepresentations: [ModeChoice: DisplayRepresentation] = [
        .home: "Home", .away: "Away", .night: "Night", .quiet: "Quiet"]
}

struct SetModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Doorstep Mode"
    static let description = IntentDescription("Home, Away, Night or Quiet: which cameras alert and record.")
    @Parameter(title: "Mode") var mode: ModeChoice

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let m: Modes.Mode = [.home: .home, .away: .away, .night: .night, .quiet: .off][mode]!
        Modes.shared.enabled = true
        Modes.shared.current = m
        return .result(dialog: "Doorstep is set to \(m.rawValue).")
    }
}

struct SayAtDoorIntent: AppIntent {
    static let title: LocalizedStringResource = "Say at Door"
    static let description = IntentDescription("Says a sentence through a camera's speaker in your Mac's voice. The microphone stays off.")
    @Parameter(title: "Say") var text: String
    @Parameter(title: "Camera") var camera: CameraEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let device = EventDirectory.shared.devices.first(where: { $0.id == camera.id }) else {
            return .result(dialog: "Doorstep couldn't find that camera.")
        }
        let said = await SpokenReplies.shared.say(text, on: device)
        return .result(dialog: said ? "Said at \(device.name)." : "Doorstep couldn't reach \(device.name).")
    }
}

struct DoorstepShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShowCameraIntent(), phrases: ["Show \(\.$camera) in \(.applicationName)",
                                                          "Show my door in \(.applicationName)"],
                    shortTitle: "Show Camera", systemImageName: "video")
        AppShortcut(intent: TodayAtHomeIntent(), phrases: ["What happened at home in \(.applicationName)",
                                                           "Who came today in \(.applicationName)"],
                    shortTitle: "Today at Home", systemImageName: "house")
        AppShortcut(intent: SetModeIntent(), phrases: ["Set \(.applicationName) to \(\.$mode)",
                                                       "Switch \(.applicationName) to \(\.$mode)"],
                    shortTitle: "Set Mode", systemImageName: "house")
        AppShortcut(intent: SayAtDoorIntent(), phrases: ["Say something at the door in \(.applicationName)"],
                    shortTitle: "Say at Door", systemImageName: "text.bubble")
        AppShortcut(intent: ParcelsTodayIntent(), phrases: ["Any parcels today in \(.applicationName)"],
                    shortTitle: "Parcels Today", systemImageName: "shippingbox")
    }
}
