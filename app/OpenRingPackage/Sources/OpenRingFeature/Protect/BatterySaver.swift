import SwiftUI
import RingClient

/// Battery cameras don't stream just because Doorstep is open: they show their latest
/// picture until you click them. Streaming is what drains a Ring battery.
public enum BatterySaver {
    public static var isOn: Bool { UserDefaults.standard.object(forKey: "batterySaver") as? Bool ?? true }

    /// The cameras that should stream when a view opens.
    public static func streamable(_ devices: [RingDevice], awake: Set<Int>) -> [RingDevice] {
        guard isOn else { return devices }
        return devices.filter { !$0.isBatteryPowered || awake.contains($0.id) }
    }

    public static func sleeping(_ device: RingDevice, track: Bool) -> Bool {
        isOn && device.isBatteryPowered && !track
    }
}

/// A battery camera's tile while it's not streaming: its latest picture and a hint.
struct BatteryStill: View {
    let device: RingDevice
    let lastEvent: RingEvent?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            DS.slate
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).opacity(0.55)
            }
            VStack(spacing: 4) {
                Image(systemName: "battery.75").font(.system(size: 15)).foregroundStyle(DS.paper)
                Text("Click to go live").font(DS.meta).foregroundStyle(DS.paper)
                if let e = lastEvent {
                    Text("Last seen \(e.createdAt.formatted(.relative(presentation: .named)))")
                        .font(DS.meta).foregroundStyle(DS.ash)
                }
            }
            .padding(8)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
        .task(id: lastEvent?.id) {
            guard let id = lastEvent?.id else { return }
            image = DemoMode.isOn ? DemoData.live(device.id) : await ThumbnailCache.shared.thumbnail(for: id)
        }
    }
}
