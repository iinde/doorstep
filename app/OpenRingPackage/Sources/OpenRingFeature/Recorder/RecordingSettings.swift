import SwiftUI
import RingClient

/// Settings › Recording: this Mac as the recorder.
public struct RecordingSettings: View {
    let devices: [RingDevice]
    @AppStorage("recorderEnabled") private var enabled = false
    @AppStorage("recordOnMotion") private var onMotion = false
    @AppStorage("recordKeepDays") private var keepDays = 14
    @AppStorage("approachAlerts") private var approach = true
    @AppStorage("snapshotsEnabled") private var snapshots = false
    @AppStorage("snapshotMinutes") private var snapshotMinutes = 5
    @AppStorage("recordFolder") private var folderPath = ""
    @State private var chosen: Set<Int> = []
    @State private var continuous: Set<Int> = Set(UserDefaults.standard.array(forKey: "continuousCameras") as? [Int] ?? [])
    @ObservedObject private var store = LocalClipStore.shared

    public init(devices: [RingDevice]) { self.devices = devices }

    private var cameras: [RingDevice] { devices.filter { $0.deviceType == .doorbell || $0.deviceType == .camera } }

    public var body: some View {
        Form {
            Section {
                Toggle("Record on this Mac", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in Task { await RecorderController.shared.sync(devices: devices) } }
                Toggle("Record any movement, not just people", isOn: $onMotion).disabled(!enabled)
                Toggle("Warn me when someone walks up to the door", isOn: $approach).disabled(!enabled)
            } header: {
                Text("Recorder")
            } footer: {
                Text("Without a Ring subscription, Ring keeps no video at all. Doorstep keeps the chosen cameras live, watches for people itself, and saves each visit with the few seconds before it. Your Mac stays awake while recording (the screen can still sleep). Nothing leaves this Mac.")
            }

            Section("Cameras") {
                ForEach(cameras, id: \.id) { d in
                    Toggle(isOn: Binding(
                        get: { chosen.contains(d.id) },
                        set: { on in
                            if on { chosen.insert(d.id) } else { chosen.remove(d.id) }
                            UserDefaults.standard.set(Array(chosen), forKey: "recordDevices")
                            Task { await RecorderController.shared.sync(devices: devices) }
                        })) {
                        HStack {
                            Text(d.name)
                            if d.isBatteryPowered {
                                Text("Battery: streaming all day will drain it").font(.caption).foregroundStyle(DS.ember)
                            }
                        }
                    }
                    .disabled(!enabled)
                }
            }

            Section {
                ForEach(cameras.filter { !$0.isBatteryPowered }, id: \.id) { d in
                    Toggle(d.name, isOn: Binding(
                        get: { continuous.contains(d.id) },
                        set: { on in
                            if on { continuous.insert(d.id) } else { continuous.remove(d.id) }
                            UserDefaults.standard.set(Array(continuous), forKey: "continuousCameras")
                        }))
                    .disabled(!enabled || !chosen.contains(d.id))
                }
            } header: {
                Text("24/7 recording")
            } footer: {
                Text("Records everything from these cameras, not just visits, in 10-minute files. Uses roughly 1 to 2 GB per camera per day, so pick a big drive and a sensible \"Keep recordings for\". Wired cameras only.")
            }

            Section {
                Toggle("Take a still from battery cameras", isOn: $snapshots)
                Picker("Every", selection: $snapshotMinutes) {
                    ForEach([2, 5, 10, 15, 30], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                .disabled(!snapshots)
            } header: {
                Text("Time-lapse")
            } footer: {
                Text("History can turn a day of stills into a time-lapse video.")
            }

            Section {
                LabeledContent("Folder", value: LocalClipStore.folder.path)
                HStack {
                    Button("Change…") { chooseFolder() }
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: LocalClipStore.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(LocalClipStore.folder)
                    }
                }
                Picker("Keep recordings for", selection: $keepDays) {
                    ForEach([3, 7, 14, 30, 90, 180, 365], id: \.self) { Text("\($0) days").tag($0) }
                    Text("Until I delete them").tag(0)
                }
                LabeledContent("Using", value: "\(store.clips.count) clips, " +
                               ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file))
            } header: {
                Text("Storage")
            }
        }
        .formStyle(.grouped)
        .frame(height: 640)
        .onAppear {
            let saved = UserDefaults.standard.array(forKey: "recordDevices") as? [Int]
            chosen = Set(saved ?? RecorderController.chosen(from: devices).map(\.id))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Record here"
        if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
    }
}
