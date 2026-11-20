import SwiftUI
import IPCam

/// Settings › General › Other cameras.
public struct IPCamerasSection: View {
    public init() {}
    @ObservedObject private var store = IPCameraStore.shared
    @State private var editing: IPCamera?
    @State private var finding = false
    @State private var found: [ONVIF.Found] = []
    @State private var searched = false

    public var body: some View {
        Section {
            ForEach(store.cameras) { c in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name)
                        Text(c.address).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Edit…") { editing = c }
                    Button(role: .destructive) { store.remove(c.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).accessibilityLabel("Remove \(c.name)")
                }
            }
            ForEach(found.filter { f in !store.cameras.contains { $0.onvifService == f.service.absoluteString } }) { f in
                HStack {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name)
                        Text("Found at \(f.host)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add…") { editing = IPCamera(name: f.name, address: "", onvifService: f.service.absoluteString) }
                }
            }
            HStack {
                Button(finding ? "Looking…" : "Find cameras on my network") {
                    finding = true
                    Task { found = await ONVIF.discover(); finding = false; searched = true }
                }
                .disabled(finding)
                Button("Add by address…") { editing = IPCamera(name: "Camera", address: "rtsp://") }
                Spacer()
                if searched, found.isEmpty, !finding { Text("None answered").font(.caption).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Other cameras")
        } footer: {
            Text("Any camera with an RTSP stream: Reolink, Tapo, Hikvision, Dahua, Amcrest, UniFi and most cameras that say ONVIF. They show in Live next to your Ring cameras, and Doorstep can tell you when it sees a person. Video goes from the camera straight to this Mac.")
        }
        .sheet(item: $editing) { c in IPCameraEditor(camera: c) { editing = nil } }
    }
}

struct IPCameraEditor: View {
    @State var camera: IPCamera
    let onDone: () -> Void
    @State private var password = ""
    @State private var smaller = true
    @State private var status: String?
    @State private var busy = false
    @State private var preview: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(camera.onvifService == nil ? "Add a camera" : "Add \(camera.name)").font(DS.title)
            Form {
                TextField("Name", text: $camera.name)
                if camera.onvifService == nil || !camera.address.isEmpty {
                    TextField("Address", text: $camera.address, prompt: Text("rtsp://192.168.1.40:554/stream1"))
                }
                TextField("User name", text: $camera.user, prompt: Text("admin"))
                SecureField("Password", text: $password)
                if camera.onvifService != nil { Toggle("Use the camera's smaller stream (easier on Wi-Fi)", isOn: $smaller) }
                Toggle("Tell me when it sees a person", isOn: $camera.watchPeople)
            }
            .formStyle(.grouped)
            if let preview {
                Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Test") { Task { await test() } }.disabled(busy)
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        if await test() {
                            IPCameraStore.shared.save(camera, password: password.isEmpty ? nil : password)
                            onDone()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || camera.name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    /// Looks the stream up (ONVIF) if needed, then connects and waits for a picture.
    @discardableResult
    private func test() async -> Bool {
        busy = true; defer { busy = false }
        if let service = camera.onvifService, let url = URL(string: service) {
            status = "Asking the camera for its stream…"
            do { camera.address = try await ONVIF.stream(service: url, user: camera.user, password: password, smaller: smaller).rtsp.absoluteString }
            catch { status = "\(error)"; return false }
        }
        guard let url = URL(string: camera.address),
              let stream = IPStream(url: url, user: camera.user.isEmpty ? nil : camera.user, password: password.isEmpty ? nil : password) else {
            status = "That isn't a valid rtsp:// address."; return false
        }
        status = "Connecting…"
        final class First: @unchecked Sendable { var data: Data? }
        let first = First()
        stream.onFrame = { pb in if first.data == nil { first.data = IPCameraStore.jpeg(pb) } }
        do {
            try await stream.start()
            for _ in 0..<50 where first.data == nil { try? await Task.sleep(for: .milliseconds(100)) }
            stream.stop()
            guard let d = first.data else { status = "Connected, but no picture arrived in 5 seconds."; return false }
            preview = NSImage(data: d)
            status = "Working."
            return true
        } catch {
            stream.stop()
            status = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
            return false
        }
    }
}
