import SwiftUI
import RingClient

// Settings sections for the intelligence features. Each says plainly what leaves the Mac.

/// "Who was it" plus the optional Claude check.
public struct WhoWasItSettings: View {
    @AppStorage("claudeCheckEnabled") private var claudeEnabled = false
    @AppStorage("claudeCheckDailyCap") private var cap = 20
    @State private var key = ""
    @State private var hasKey = false
    @State private var taught = 0
    @AppStorage("listenToClips") private var listen = true
    @AppStorage("readPlates") private var plates = false
    @ObservedObject private var plateIndex = PlateIndex.shared

    public init() {}

    public var body: some View {
        Section {
            LabeledContent("Clips you've labelled", value: "\(taught)")
            Button("Forget what I taught it") {
                Task { await TeachStore.shared.clear(); taught = 0 }
            }
            .disabled(taught == 0)
        } header: {
            Text("Who was it")
        } footer: {
            Text("Doorstep reads company names off vans, jackets and bags (DPD, Royal Mail, Amazon and others) on this Mac. Correct it from any clip with \"Who was it?\" and it learns your regular drivers.")
        }

        Section {
            Toggle("Listen to clips for knocking, dogs, breaking glass and alarms", isOn: $listen)
        } header: {
            Text("Hearing")
        } footer: {
            Text("Apple's sound recognition on this Mac, on clips with people or the doorbell. \"Someone knocked\" shows up even when nobody rang.")
        }

        Section {
            Toggle("Read number plates", isOn: $plates)
            if plates {
                let seen = Dictionary(grouping: PlateIndex.shared.all, by: \.plate)
                    .sorted { $0.value.count > $1.value.count }.prefix(8)
                ForEach(Array(seen), id: \.key) { plate, list in
                    HStack {
                        Text(PlateIndex.pretty(plate)).font(.system(.body, design: .monospaced))
                        Text("\(list.count)× · last \(list.map(\.date).max()!.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        TextField("Name, e.g. My car", text: Binding(
                            get: { PlateIndex.shared.name(plate) ?? "" },
                            set: { PlateIndex.shared.setName($0, for: plate) }))
                            .frame(width: 150)
                    }
                }
                Button("Forget all plates") { PlateIndex.shared.forgetAll() }
            }
        } header: {
            Text("Number plates")
        } footer: {
            Text("Off by default. Name a plate (\"My car\") and Doorstep tells you when it arrives. Plates are kept only on this Mac for 90 days. Other people's plates are their personal data: only use this for your own drive.")
        }

        LocalAISection()

        Section {
            Toggle("Ask Claude when this Mac can't tell", isOn: $claudeEnabled)
                .disabled(!hasKey)
            if hasKey {
                LabeledContent("Anthropic API key") {
                    HStack {
                        Text("Saved in Keychain").foregroundStyle(.secondary)
                        Button("Remove") {
                            Task {
                                try? await KeychainManager.shared.deleteAnthropicAPIKey()
                                hasKey = false
                                claudeEnabled = false
                            }
                        }
                    }
                }
                Stepper("Up to \(cap) clips a day", value: $cap, in: 5...200, step: 5)
                LabeledContent("Used today", value: "\(ClaudeCheck.usedToday)")
            } else {
                SecureField("Anthropic API key", text: $key)
                Button("Save key") {
                    let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        try? await KeychainManager.shared.saveAnthropicAPIKey(k)
                        key = ""
                        hasKey = true
                    }
                }
                .disabled(!key.hasPrefix("sk-"))
            }
        } header: {
            Text("Cloud check (optional)")
        } footer: {
            Text("Off unless you switch it on. Uses your own Anthropic key, billed to you. Only doorbell clips with a person in, and only when this Mac couldn't tell who it was: three still frames are sent, never the video or sound.")
        }
        .task {
            hasKey = ((try? await KeychainManager.shared.getAnthropicAPIKey()) ?? nil)?.isEmpty == false
            taught = await TeachStore.shared.count
        }
    }
}

/// Mailbox for parcels (optional), daily brief and archive.
public struct ParcelsSettings: View {
    @ObservedObject private var mailbox = Mailbox.shared
    @AppStorage("msClientId") private var clientId = ""
    @AppStorage("dailyBriefEnabled") private var briefEnabled = false
    @AppStorage("dailyBriefHour") private var briefHour = 20
    @State private var archiveFolder: String? = ClipArchive.folderName()
    @AppStorage("deliveryWatchEnabled") private var deliveryWatch = true
    @AppStorage("rainWarnings") private var rain = true
    @ObservedObject private var tracker = Tracker.shared
    @State private var trackKey = ""

    public init() {}

    public var body: some View {
        Form {
            Section {
                Text("Paste a tracking number or a delivery email in History › Parcels, or drag emails onto it. Nothing to set up.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Parcels")
            }

            Section {
                Toggle("Show me the door when a parcel is due and someone arrives", isOn: $deliveryWatch)
                Toggle("Warn me if it rains on a parcel left outside", isOn: $rain)
                if tracker.hasKey {
                    LabeledContent("17TRACK key") {
                        HStack {
                            Text("Saved in Keychain").foregroundStyle(.secondary)
                            Button("Remove") { Task { await tracker.removeKey() } }
                        }
                    }
                    if let err = tracker.lastError { Text(err).foregroundStyle(DS.ember) }
                } else {
                    SecureField("17TRACK API key (optional)", text: $trackKey)
                    Button("Save key") { let k = trackKey; trackKey = ""; Task { await tracker.saveKey(k) } }
                        .disabled(trackKey.trimmingCharacters(in: .whitespaces).count < 16)
                }
            } header: {
                Text("Expecting a parcel")
            } footer: {
                Text("Live status uses your own free 17TRACK key (17track.net › API), checked every 30 minutes for parcels you're expecting. Without one, Track opens the carrier's page and delivery emails still update it. Rain warnings ask Open-Meteo (free, no account) for the weather near your home, sending a position rounded to about 1 km.")
            }

            Section {
                TextField("Application (client) ID", text: $clientId)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: clientId) { _, _ in Task { await mailbox.refreshState() } }
                mailboxRow
            } header: {
                Text("Read delivery emails automatically (optional)")
            } footer: {
                Text("For Outlook.com, Hotmail or Microsoft 365. Microsoft needs an app ID from you: register a free app at entra.microsoft.com (App registrations › New, \"Personal and work accounts\", Allow public client flows on). Read-only, checked every 15 minutes; only delivery emails are read, and only the parcel details are kept.")
            }

            Section {
                Toggle("Send a summary of the day", isOn: $briefEnabled)
                Picker("At", selection: $briefHour) {
                    ForEach([18, 19, 20, 21, 22], id: \.self) { Text("\($0):00").tag($0) }
                }
                .disabled(!briefEnabled)
            } header: {
                Text("Daily brief")
            } footer: {
                Text("Deliveries, rings, visits and whether the night was quiet. Written on this Mac.")
            }

            Section {
                if let archiveFolder {
                    LabeledContent("Folder", value: archiveFolder)
                    HStack {
                        Button("Change…") { ClipArchive.chooseFolder(); self.archiveFolder = ClipArchive.folderName() }
                        Button("Stop archiving") { ClipArchive.stop(); self.archiveFolder = nil }
                    }
                } else {
                    Button("Choose a folder…") { ClipArchive.chooseFolder(); archiveFolder = ClipArchive.folderName() }
                }
            } header: {
                Text("Keep clips")
            } footer: {
                Text("Copies People and Doorbell clips into this folder, sorted by day, so they're kept after Ring deletes them. A network drive works.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 640)
        .task { await mailbox.refreshState(); await tracker.refreshKeyState() }
    }

    @ViewBuilder private var mailboxRow: some View {
        switch mailbox.state {
        case .notSetUp:
            Text("Add an app ID to connect a mailbox.").foregroundStyle(.secondary)
        case .signedOut:
            Button("Sign in to Microsoft…") { mailbox.signIn() }
        case .awaitingCode(let code, let url):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(code).font(.system(.title2, design: .monospaced)).textSelection(.enabled)
                    Button("Copy and open Microsoft") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        NSWorkspace.shared.open(url)
                    }
                }
                Text("Enter this code on the Microsoft page, then come back. Doorstep finishes by itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .signedIn(let name):
            LabeledContent("Connected", value: name)
            HStack {
                Button("Check now") { Task { await mailbox.check() } }
                Button("Disconnect") { Task { await mailbox.signOut() } }
            }
        case .failed(let message):
            Text(message).foregroundStyle(DS.ember)
            Button("Try again") { mailbox.signIn() }
        }
    }
}
