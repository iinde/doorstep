import SwiftUI
import RingClient
@preconcurrency import WebRTC

/// The command centre: a full window (or full screen) with every camera, the map, the radar
/// and the numbers. Spec: docs/COMMAND-CENTRE.md.
// MARK: - Live: every camera, big

struct LiveGrid: View {
    let devices: [RingDevice]
    let events: [RingEvent]
    @ObservedObject private var streams = MultiStreamManager.shared
    @ObservedObject private var intel = LiveIntel.shared

    var body: some View {
        GeometryReader { geo in
            let cols = devices.count <= 1 ? 1 : devices.count <= 4 ? 2 : 3
            let rows = Int(ceil(Double(devices.count) / Double(cols)))
            let gap: CGFloat = 12
            let w = (geo.size.width - 48 - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let h = min(w * 9 / 16, (geo.size.height - 48 - gap * CGFloat(rows - 1)) / CGFloat(max(rows, 1)))
            VStack(spacing: gap) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(devices[(r * cols)..<min(r * cols + cols, devices.count)], id: \.id) { d in
                            tile(d).frame(width: h * 16 / 9, height: h)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
    }

    private func tile(_ d: RingDevice) -> some View {
        let now = intel.cameras[d.id]
        return ZStack(alignment: .bottomLeading) {
            DS.slate
            if DemoMode.isOn {
                DemoLivePicture(deviceId: d.id)
            } else if let track = streams.getVideoTrack(for: d.id) {
                WebRTCVideoView(videoTrack: track, isPortrait: false, captureHandler: nil, fill: true, label: "\(d.name) (centre)")
                    .id(ObjectIdentifier(track))
                    .onAppear { LiveAnalysis.shared.watch(d.id, track: track) }
            } else if BatterySaver.sleeping(d, track: false) {
                BatteryStill(device: d, lastEvent: events.filter { $0.deviceId == d.id }.max { $0.createdAt < $1.createdAt })
                    .onTapGesture { Task { await streams.startAllStreams(for: [d]) } }
            } else {
                Text(streams.gaveUp.contains(d.id) ? "No picture from \(d.name)" : "Connecting to \(d.name)")
                    .font(DS.body).foregroundStyle(DS.ash)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // People boxes from this Mac's live analysis.
            GeometryReader { g in
                ForEach(Array((now?.people ?? []).enumerated()), id: \.offset) { _, box in
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(now?.approaching == true ? DS.porchlight : DS.paper.opacity(0.8), lineWidth: 2)
                        .frame(width: box.width * g.size.width, height: box.height * g.size.height)
                        .position(x: box.midX * g.size.width, y: (1 - box.midY) * g.size.height)
                }
            }
            HStack(spacing: 8) {
                Text(d.name).font(DS.bodyStrong)
                if let now, !now.people.isEmpty {
                    Text(now.approaching ? "Approaching" : "Person").font(DS.meta)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(now.approaching ? DS.porchlight : DS.well, in: Capsule())
                        .foregroundStyle(now.approaching ? DS.night : DS.paper)
                }
                if RecorderController.shared.recording[d.id] != nil {
                    Image(systemName: "record.circle").foregroundStyle(DS.ember).font(.system(size: 11))
                }
            }
            .foregroundStyle(DS.paper)
            .padding(10)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            Button("Float this camera") { FloatingCamera.shared.show(d) }
        }
    }
}
