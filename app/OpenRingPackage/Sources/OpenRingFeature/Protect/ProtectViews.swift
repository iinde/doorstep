import SwiftUI
import AVFoundation
import RingClient

/// In a visit's detail: find the faces in the clip and name the ones you know.
struct FacesInClip: View {
    let eventId: String
    @State private var faces: [DetectedFace] = []
    @State private var loading = false
    @State private var names: [UUID: String] = [:]
    @State private var saved: Set<UUID> = []
    @ObservedObject private var index = FaceIndex.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Faces").font(DS.bodyStrong).foregroundStyle(DS.paper)
                if !index.names(for: eventId).isEmpty {
                    Text(index.names(for: eventId).joined(separator: ", ")).font(DS.meta).foregroundStyle(DS.porchlight)
                }
                Spacer()
                if faces.isEmpty {
                    Button(loading ? "Looking…" : "Find faces in this clip") { Task { await find() } }
                        .disabled(loading)
                }
            }
            if !faces.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(faces) { f in
                            VStack(spacing: 6) {
                                Image(decorative: f.image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
                                if saved.contains(f.id) {
                                    Label("Saved", systemImage: "checkmark").font(DS.meta).foregroundStyle(DS.porchlight)
                                } else {
                                    TextField("Who is this?", text: Binding(get: { names[f.id] ?? "" }, set: { names[f.id] = $0 }))
                                        .textFieldStyle(.roundedBorder).frame(width: 110).font(DS.meta)
                                        .onSubmit { save(f) }
                                    Menu("Pick") {
                                        ForEach(index.all) { p in Button(p.name) { names[f.id] = p.name; save(f) } }
                                    }
                                    .menuStyle(.borderlessButton).fixedSize().font(DS.meta)
                                    .disabled(index.all.isEmpty)
                                }
                            }
                        }
                    }
                }
                Text("Only faces you name are kept. Doorstep then tells you when they come back.")
                    .font(DS.meta).foregroundStyle(DS.ash)
            }
        }
        .padding(12)
        .background(DS.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func save(_ f: DetectedFace) {
        let n = (names[f.id] ?? "").trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        FaceIndex.shared.name(f, as: n)
        saved.insert(f.id)
    }

    private func find() async {
        loading = true
        defer { loading = false }
        guard let link = try? await RingClient.shared.getEventVideoLink(eventId: eventId) else { return }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: link))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 1600, height: 1600)
        var found: [DetectedFace] = []
        for t in [1.0, 2.5, 4.0, 6.0, 8.0] {
            if let (img, _) = try? await g.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                found += FaceIndex.faces(in: img)
            }
        }
        // One of each: drop faces that look the same as one already found.
        var unique: [DetectedFace] = []
        for f in found where !unique.contains(where: { FaceIndex.distance($0.print, f.print) < 0.3 }) { unique.append(f) }
        faces = Array(unique.prefix(6))
    }
}

/// Settings › Alerts: what notifies you, one alert per visit, modes, familiar faces.
public struct AlertsSettings: View {
    let devices: [RingDevice]
    @ObservedObject private var modes = Modes.shared
    @ObservedObject private var faces = FaceIndex.shared
    @AppStorage("singleEventAlerts") private var single = true
    @AppStorage("familiarFaces") private var familiar = false
    @State private var editing: Modes.Mode = .home
    @State private var refresh = 0

    public init(devices: [RingDevice]) { self.devices = devices }

    private var cameras: [RingDevice] { devices.filter { $0.deviceType == .doorbell || $0.deviceType == .camera } }

    public var body: some View {
        Form {
            Section {
                ForEach(AlertKind.allCases) { k in
                    Toggle(k.rawValue, isOn: Binding(get: { _ = refresh; return k.isOn }, set: { k.isOn = $0; refresh += 1 }))
                }
                Toggle("One alert per visit", isOn: $single)
            } header: {
                Text("Alert me about")
            } footer: {
                Text("\"One alert per visit\" updates the same notification as a visit goes on, instead of sending a new one for every clip. \"Unusual activity\" is someone at an hour that's rare for that camera.")
            }

            RepliesSection(doorbells: devices.filter { $0.deviceType == .doorbell })
            LoiteringSection()
            PhoneAlertsSection()

            Section {
                Toggle("Use modes", isOn: $modes.enabled)
                if modes.enabled {
                    Picker("Now", selection: $modes.current) {
                        ForEach(Modes.Mode.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                    }
                    Picker("Edit", selection: $editing) {
                        ForEach(Modes.Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(editing.explanation).font(.caption).foregroundStyle(.secondary)
                    ForEach(cameras, id: \.id) { d in
                        HStack {
                            Text(d.name)
                            Spacer()
                            Toggle("Alerts", isOn: Binding(
                                get: { modes.rules[editing]?.alerts.contains(d.id) ?? false },
                                set: { modes.toggle(d.id, alerts: $0, in: editing) }))
                            .toggleStyle(.checkbox)
                            Toggle("Records", isOn: Binding(
                                get: { modes.rules[editing]?.records.contains(d.id) ?? false },
                                set: { modes.toggle(d.id, records: $0, in: editing) }))
                            .toggleStyle(.checkbox)
                            .disabled(d.isBatteryPowered)
                        }
                    }
                    Toggle("Switch to Night automatically", isOn: $modes.nightSchedule)
                    if modes.nightSchedule {
                        HStack {
                            Picker("From", selection: $modes.nightFrom) { ForEach(18..<24, id: \.self) { Text("\($0):00").tag($0) } }
                            Picker("until", selection: $modes.nightTo) { ForEach(4..<11, id: \.self) { Text("\($0):00").tag($0) } }
                        }
                    }
                }
            } header: {
                Text("Modes")
            } footer: {
                Text("Like an alarm panel: Home, Away, Night and Quiet each decide which cameras alert you and which record (recording needs Settings › Recording on). Switch from the Wall, or say \"Set Doorstep to Away\" to Siri. Doorbell rings always come through except in Quiet.")
            }

            Section {
                Toggle("Recognise people I name (beta)", isOn: $familiar)
                if familiar {
                    if faces.all.isEmpty {
                        Text("Open a visit in History and choose \"Find faces in this clip\" to name someone.").foregroundStyle(.secondary)
                    }
                    ForEach(faces.all) { p in
                        HStack {
                            if let d = p.thumbnail, let img = NSImage(data: d) {
                                Image(nsImage: img).resizable().frame(width: 28, height: 28).clipShape(Circle())
                            }
                            Text(p.name)
                            Spacer()
                            Button("Forget") { faces.forget(p) }
                        }
                    }
                }
            } header: {
                Text("Familiar faces")
            } footer: {
                Text("Off by default. Faces are only kept for people you name, and recognising them happens on this Mac. Faces of other people are their personal data; only name people who are happy to be recognised.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 640)
        .onAppear { modes.ensureDefaults(for: devices) }
    }
}

/// The mode switcher on the Wall (only when modes are on).
struct ModeMenu: View {
    @ObservedObject private var modes = Modes.shared
    var body: some View {
        if modes.enabled {
            Menu {
                ForEach(Modes.Mode.allCases) { m in
                    Button { modes.current = m } label: { Label(m.rawValue, systemImage: m.symbol) }
                }
            } label: {
                Label(modes.current.rawValue, systemImage: modes.current.symbol)
                    .font(DS.meta)
                    .foregroundStyle(modes.current == .away ? DS.porchlight : DS.ash)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Mode: \(modes.current.explanation)")
        }
    }
}

/// Settings › Alerts › On your phone.
struct PhoneAlertsSection: View {
    @AppStorage("phoneService") private var service = PhoneAlerts.Service.off.rawValue
    @AppStorage("ntfyServer") private var ntfyServer = ""
    @AppStorage("ntfyTopic") private var ntfyTopic = ""
    @AppStorage("telegramChat") private var telegramChat = ""
    @State private var secretA = ""
    @State private var secretB = ""
    @State private var status: String?

    var body: some View {
        Section {
            Picker("Send alerts to my phone with", selection: $service) {
                ForEach(PhoneAlerts.Service.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            switch PhoneAlerts.Service(rawValue: service) ?? .off {
            case .off:
                EmptyView()
            case .ntfy:
                TextField("Topic", text: $ntfyTopic, prompt: Text("doorstep-something-random"))
                Button("Make a random topic") { ntfyTopic = "doorstep-" + UUID().uuidString.prefix(12).lowercased() }
                if !ntfyTopic.isEmpty, ntfyTopic.count < 16 {
                    Label("Anyone who guesses this topic can see your alerts and pictures. Use a long random one.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                TextField("Server (optional)", text: $ntfyServer, prompt: Text("https://ntfy.sh"))
            case .pushover:
                SecureField("Your user key", text: $secretA)
                SecureField("Application token", text: $secretB)
                Button("Save keys") {
                    Task {
                        try? await KeychainManager.shared.saveSecret(secretA, for: "pushoverUser")
                        try? await KeychainManager.shared.saveSecret(secretB, for: "pushoverToken")
                        secretA = ""; secretB = ""; status = "Saved in Keychain"
                    }
                }
            case .telegram:
                SecureField("Bot token", text: $secretA)
                TextField("Chat ID", text: $telegramChat)
                Button("Save token") {
                    Task { try? await KeychainManager.shared.saveSecret(secretA, for: "telegramBot"); secretA = ""; status = "Saved in Keychain" }
                }
            }
            if service != PhoneAlerts.Service.off.rawValue {
                HStack {
                    Button("Send a test") {
                        Task { await PhoneAlerts.send(title: "Doorstep test", body: "Alerts will arrive like this.", image: nil); status = "Sent" }
                    }
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            }
        } header: {
            Text("On your phone")
        } footer: {
            Text("Doorstep's alerts, picture included, on your iPhone or Android. ntfy needs no account: install the ntfy app and subscribe to the same topic (anyone who knows the topic can read it, so keep it random). Pushover and Telegram use your own keys. Only alerts you've chosen above are sent.")
        }
    }
}

/// Settings › Alerts › Loitering.
struct LoiteringSection: View {
    @AppStorage("loiterSeconds") private var seconds = 40
    var body: some View {
        Section {
            Picker("Tell me when someone hangs around for", selection: $seconds) {
                Text("Never").tag(0)
                ForEach([20, 40, 60, 120, 300], id: \.self) { Text($0 < 60 ? "\($0) seconds" : "\($0 / 60) minute\($0 >= 120 ? "s" : "")").tag($0) }
            }
        } header: {
            Text("Loitering")
        } footer: {
            Text("Works on cameras Doorstep is recording or showing in the command centre, and only inside a camera's zone if it has one.")
        }
    }
}

/// Settings › Intelligence › Local AI and transcripts.
struct LocalAISection: View {
    @AppStorage("ollamaEnabled") private var enabled = false
    @AppStorage("ollamaServer") private var server = ""
    @AppStorage("ollamaModel") private var model = ""
    @AppStorage("transcribeClips") private var transcribe = false
    @State private var models: [String] = []
    @State private var status: String?

    var body: some View {
        Section {
            Toggle("Write down what visitors say", isOn: $transcribe)
                .onChange(of: transcribe) { _, on in
                    if on { Task { if !(await TranscriptIndex.requestPermission()) { transcribe = false } } }
                }
        } header: {
            Text("What was said")
        } footer: {
            Text("Turns speech in doorbell and visitor clips into text with Apple's on-device recognition, so you can read it and search it (\"behind the bin\"). Nothing is sent anywhere.")
        }

        Section {
            Toggle("Describe visits with Ollama on this Mac", isOn: $enabled)
            if enabled {
                TextField("Server", text: $server, prompt: Text("http://127.0.0.1:11434"))
                HStack {
                    Picker("Model", selection: $model) {
                        Text("Choose a vision model").tag("")
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Refresh") { Task { await load() } }
                }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Local AI")
        } footer: {
            Text("If you run Ollama (ollama.com), Doorstep can ask a vision model like qwen2.5vl, gemma3 or llava to describe each visit. It runs on your own computer, so nothing leaves your home, and it costs nothing. Install a model with \"ollama pull gemma3\".")
        }
        .task { if enabled { await load() } }
        .onChange(of: enabled) { _, on in if on { Task { await load() } } }
    }

    private func load() async {
        models = await LocalAI.models()
        status = models.isEmpty ? "Couldn't reach Ollama at \(LocalAI.server). Is it running?" : "\(models.count) models found"
    }
}
