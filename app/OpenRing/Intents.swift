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

struct DoorstepShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShowCameraIntent(), phrases: ["Show \(\.$camera) in \(.applicationName)",
                                                          "Show my door in \(.applicationName)"],
                    shortTitle: "Show Camera", systemImageName: "video")
        AppShortcut(intent: TodayAtHomeIntent(), phrases: ["What happened at home in \(.applicationName)",
                                                           "Who came today in \(.applicationName)"],
                    shortTitle: "Today at Home", systemImageName: "house")
        AppShortcut(intent: ParcelsTodayIntent(), phrases: ["Any parcels today in \(.applicationName)"],
                    shortTitle: "Parcels Today", systemImageName: "shippingbox")
    }
}
