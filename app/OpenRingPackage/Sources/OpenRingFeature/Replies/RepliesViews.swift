import SwiftUI
import RingClient

/// Under the picture when someone rings: type a line, or pick one you saved, and the Mac
/// says it at the door. No microphone.
struct SayItRow: View {
    let device: RingDevice
    @ObservedObject private var replies = SpokenReplies.shared
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Type something to say", text: $text)
                    .textFieldStyle(.plain)
                    .font(DS.body)
                    .foregroundStyle(DS.paper)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(DS.well, in: Capsule())
                    .onSubmit(send)
                Menu {
                    ForEach(replies.saved, id: \.self) { line in
                        Button(line) { say(line) }
                    }
                } label: {
                    Image(systemName: "text.bubble")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Say a saved reply")
                .accessibilityLabel("Say a saved reply")
                Button(action: send) {
                    Image(systemName: replies.speaking == nil ? "arrow.up.circle.fill" : "waveform")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.porchlight)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || replies.speaking != nil)
                .accessibilityLabel("Say it at the door")
            }
            if let s = replies.status {
                Text(s).font(DS.meta).foregroundStyle(DS.ash).padding(.leading, 12)
            }
        }
        .disabled(replies.speaking != nil)
    }

    private func send() { say(text); text = "" }
    private func say(_ line: String) {
        let d = device
        Task { await replies.say(line, on: d) }
    }
}

/// Settings: the lines you can say with one click, and answering couriers for you.
struct RepliesSection: View {
    let doorbells: [RingDevice]
    @ObservedObject private var replies = SpokenReplies.shared
    @State private var newLine = ""
    @AppStorage("courierReplyEnabled") private var courier = false
    @AppStorage("courierReplyText") private var courierText = ""
    @AppStorage("courierReplyWhen") private var when = "away"
    @AppStorage("courierReplyExpecting") private var expecting = true
    @AppStorage("courierReplyCouriersOnly") private var couriersOnly = true

    var body: some View {
        Section {
            ForEach(replies.saved, id: \.self) { line in
                HStack {
                    Text(line)
                    Spacer()
                    Button { replies.hear(line) } label: { Image(systemName: "speaker.wave.2") }
                        .buttonStyle(.borderless).help("Hear it on this Mac").accessibilityLabel("Hear it on this Mac")
                    Button(role: .destructive) { replies.saved.removeAll { $0 == line } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).accessibilityLabel("Delete reply")
                }
            }
            HStack {
                TextField("Add a reply", text: $newLine, prompt: Text("Round the back, please."))
                    .onSubmit(add)
                Button("Add", action: add).disabled(newLine.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Say it at the door")
        } footer: {
            Text("When someone rings, type a line or pick one of these and your Mac says it through the doorbell in its own voice. Your microphone stays off, so you can answer from a meeting. Better voices are free in System Settings › Accessibility › Spoken Content.")
        }

        Section {
            Toggle("Answer couriers when I can't", isOn: $courier)
            if courier {
                TextField("Say", text: $courierText, prompt: Text(CourierReply.defaultMessage), axis: .vertical)
                Button("Hear it on this Mac") { replies.hear(CourierReply.message) }
                Picker("When", selection: $when) {
                    Text("Only in Away mode").tag("away")
                    Text("Any time").tag("always")
                }
                Toggle("Only when I'm expecting a parcel", isOn: $expecting)
                Toggle("Only if Doorstep recognises a courier", isOn: $couriersOnly)
                if doorbells.isEmpty {
                    Label("This needs a Ring doorbell.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                } else if let why = CourierReply.holdReason() {
                    Text("Right now it would stay quiet: \(why).").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Answer couriers for you")
        } footer: {
            Text("When the doorbell rings and it looks like a delivery, Doorstep says your sentence once and tells you it did. It only ever says what you wrote here, so don't write that nobody's home. Recognising a courier takes a few seconds and isn't perfect: with that switch off, it answers anyone who rings.")
        }
    }

    private func add() {
        let line = newLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !replies.saved.contains(line) else { return }
        replies.saved.append(line)
        newLine = ""
    }
}
