import SwiftUI
import AppKit
import Vision
import CoreImage
import UserNotifications
import IPCam
import RingClient

/// A camera that isn't Ring: anything with an RTSP stream (Reolink, Tapo, Hikvision, Dahua,
/// Amcrest, UniFi, most "ONVIF" cameras). Passwords live in the Keychain.
public struct IPCamera: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var address: String          // rtsp://host:554/path (no password)
    public var user: String = ""
    public var onvifService: String?    // where we found it, to look the stream up again
    public var watchPeople = true
    var keychainKey: String { "ipcam-\(id.uuidString)" }
}

/// A decoded frame handed between threads (pixel buffers are safe to share read-only).
struct Frame: @unchecked Sendable { let buffer: CVPixelBuffer; init(_ b: CVPixelBuffer) { buffer = b } }

/// One camera's live state.
@MainActor
public final class IPLive: ObservableObject {
    public enum State: Equatable { case idle, connecting, live, failed(String) }
    @Published public private(set) var state: State = .idle
    @Published public private(set) var people = 0
    @Published public private(set) var size: CGSize = .zero
    /// Set by the video view; called with every decoded frame (on the main thread).
    var display: ((CVPixelBuffer) -> Void)?
    private(set) var latest: CVPixelBuffer?
    let camera: IPCamera
    private var stream: IPStream?
    private var retry = 5.0
    private var lastAnalysis = Date.distantPast
    private var lastAlert = Date.distantPast
    private var wanted = false

    init(camera: IPCamera) { self.camera = camera }

    func start() {
        wanted = true
        guard stream == nil, !DemoMode.isOn else { if DemoMode.isOn { state = .live }; return }
        guard let url = URL(string: camera.address) else { state = .failed("That isn't a valid address."); return }
        state = .connecting
        Task {
            let password = (try? await KeychainManager.shared.secret(for: camera.keychainKey)) ?? nil
            connect(url, password: password)
        }
    }

    private func connect(_ url: URL, password: String?) {
        guard wanted, stream == nil else { return }
        guard let s = IPStream(url: url, user: camera.user.isEmpty ? nil : camera.user, password: password) else {
            state = .failed("That isn't a valid rtsp:// address."); return
        }
        stream = s
        s.onFrame = { [weak self] pb in
            let box = Frame(pb)
            DispatchQueue.main.async { self?.frame(box.buffer) }
        }
        s.onClose = { [weak self] _ in
            DispatchQueue.main.async { self?.dropped("The camera stopped sending video.") }
        }
        Task {
            do { try await s.start(); retry = 5 }
            catch { dropped((error as? CustomStringConvertible)?.description ?? error.localizedDescription) }
        }
    }

    func stop() {
        wanted = false
        stream?.stop(); stream = nil
        state = .idle
    }

    private func dropped(_ why: String) {
        stream?.stop(); stream = nil
        state = .failed(why)
        guard wanted else { return }
        let wait = retry
        retry = min(retry * 2, 120)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.wanted, self.stream == nil else { return }
            self.start()
        }
    }

    private func frame(_ pb: CVPixelBuffer) {
        latest = pb
        if state != .live { state = .live; size = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)) }
        display?(pb)
        guard camera.watchPeople, Date().timeIntervalSince(lastAnalysis) > 1 else { return }
        lastAnalysis = Date()
        let box = Frame(pb)
        Task.detached(priority: .utility) { [weak self] in
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = false
            try? VNImageRequestHandler(cvPixelBuffer: box.buffer).perform([request])
            let count = (request.results ?? []).filter { $0.confidence > 0.6 }.count
            await self?.peopleSeen(count, in: box)
        }
    }

    private func peopleSeen(_ count: Int, in frame: Frame) {
        let pb = frame.buffer
        let before = people
        people = count
        guard count > 0, before == 0, Date().timeIntervalSince(lastAlert) > 120,
              AlertKind.people.isOn, !Modes.shared.enabled || Modes.shared.current != .off else { return }
        lastAlert = Date()
        let jpeg = IPCameraStore.jpeg(pb)
        let away = AwayEscalation.isAway
        Task {
            let c = UNMutableNotificationContent()
            c.title = away ? "Someone's at \(camera.name) while you're away" : "Person at \(camera.name)"
            c.body = "Seen on \(camera.name) just now."
            if Busy.alertSound { c.sound = .default }
            if away { c.interruptionLevel = .timeSensitive }
            if let jpeg {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("doorstep-ip-\(camera.id.uuidString).jpg")
                if (try? jpeg.write(to: url)) != nil, let a = try? UNNotificationAttachment(identifier: "picture", url: url) { c.attachments = [a] }
            }
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ip-\(camera.id)-\(Date().timeIntervalSince1970)", content: c, trigger: nil))
            await PhoneAlerts.send(title: c.title, body: c.body, image: jpeg)
        }
    }
}

@MainActor
public final class IPCameraStore: ObservableObject {
    public static let shared = IPCameraStore()
    @Published public private(set) var cameras: [IPCamera] = []
    private(set) var live: [UUID: IPLive] = [:]
    private var viewers = 0

    private init() {
        if DemoMode.isOn {
            cameras = [IPCamera(name: "Back Gate", address: "rtsp://192.168.1.40/stream", user: "admin")]
        } else if let d = UserDefaults.standard.data(forKey: "ipCameras"), let c = try? JSONDecoder().decode([IPCamera].self, from: d) {
            cameras = c
        }
        for c in cameras { live[c.id] = IPLive(camera: c) }
    }

    public func state(_ id: UUID) -> IPLive? { live[id] }

    /// At launch: cameras watching for people stay connected.
    public func startWatching() { for c in cameras where c.watchPeople { live[c.id]?.start() } }

    /// The Live view is open: connect them all.
    public func addViewer() { viewers += 1; for c in cameras { live[c.id]?.start() } }
    public func removeViewer() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        for c in cameras where !c.watchPeople { live[c.id]?.stop() }
    }

    public func save(_ camera: IPCamera, password: String?) {
        live[camera.id]?.stop()
        Task {
            if let password { try? await KeychainManager.shared.saveSecret(password, for: camera.keychainKey) }
            self.finishSave(camera)
        }
    }

    private func finishSave(_ camera: IPCamera) {
        if let i = cameras.firstIndex(where: { $0.id == camera.id }) { cameras[i] = camera } else { cameras.append(camera) }
        live[camera.id] = IPLive(camera: camera)
        persist()
        if camera.watchPeople || viewers > 0 { live[camera.id]?.start() }
    }

    public func remove(_ id: UUID) {
        live[id]?.stop(); live[id] = nil
        if let c = cameras.first(where: { $0.id == id }) { Task { try? await KeychainManager.shared.saveSecret("", for: c.keychainKey) } }
        cameras.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard !DemoMode.isOn, let d = try? JSONEncoder().encode(cameras) else { return }
        UserDefaults.standard.set(d, forKey: "ipCameras")
    }

    nonisolated static func jpeg(_ pb: CVPixelBuffer) -> Data? {
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }
}

// MARK: - Video

/// Puts decoded frames straight onto a layer: no SwiftUI redraw per frame.
struct IPVideoView: NSViewRepresentable {
    @ObservedObject var live: IPLive
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.contentsGravity = .resizeAspectFill
        v.layer?.masksToBounds = true
        if let pb = live.latest { v.layer?.contents = pb }
        live.display = { [weak v] pb in v?.layer?.contents = pb }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

/// A tile for the Live grid.
struct IPCameraTile: View {
    let camera: IPCamera
    @ObservedObject var live: IPLive

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            DS.slate
            if DemoMode.isOn {
                DemoLivePicture(deviceId: DemoData.side)
            } else if live.state == .live {
                IPVideoView(live: live)
            } else {
                VStack(spacing: 6) {
                    if case .failed(let why) = live.state {
                        Image(systemName: "video.slash").foregroundStyle(DS.ash)
                        Text(why).font(DS.meta).foregroundStyle(DS.ash).multilineTextAlignment(.center).padding(.horizontal, 20)
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Connecting to \(camera.name)").font(DS.body).foregroundStyle(DS.ash)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 6) {
                Text(camera.name).font(DS.bodyStrong).foregroundStyle(.white)
                if live.people > 0 {
                    Text("Person").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.night)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(DS.porchlight, in: Capsule())
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous))
    }
}
