import SwiftUI
import UniformTypeIdentifiers
import RingClient

/// Parcels: what's coming, what came, and the clip of it arriving.
struct ParcelsView: View {
    let onWatch: (String) -> Void   // event id

    @ObservedObject private var store = ParcelStore.shared
    @ObservedObject private var mailbox = Mailbox.shared
    @State private var pasting = false
    @State private var pasted = ""
    @State private var dropHighlight = false
    @State private var lastAdded: Int?
    @State private var expecting = false
    @State private var open: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Parcels").font(DS.display).foregroundStyle(DS.paper)
                    Text(subtitle).font(DS.body).foregroundStyle(DS.ash)
                }
                HStack(spacing: 8) {
                    if case .signedIn = mailbox.state {
                        Button {
                            Task { await mailbox.check() }
                        } label: { Label("Check mail", systemImage: "arrow.clockwise") }
                    }
                    Button {
                        pasted = NSPasteboard.general.string(forType: .string) ?? ""
                        pasting = true
                    } label: { Label("Paste email", systemImage: "doc.on.clipboard") }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    Button { expecting = true } label: {
                        Label("I'm expecting a parcel", systemImage: "shippingbox")
                            .font(DS.bodyStrong)
                            .foregroundStyle(DS.night)
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(DS.porchlight, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("n", modifiers: .command)
                    Spacer()
                }

                dropZone

                if store.recent.isEmpty {
                    Text("Nothing yet. Paste a tracking number or a delivery email, or drag one in.")
                        .font(DS.body).foregroundStyle(DS.ash)
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.recent) { p in
                            ParcelRow(parcel: p, isOpen: open == p.id, onWatch: onWatch)
                                .contentShape(Rectangle())
                                .onTapGesture { withAnimation(DS.settle) { open = open == p.id ? nil : p.id } }
                            Divider().overlay(DS.well)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.night)
        .sheet(isPresented: $pasting) { pasteSheet }
        .sheet(isPresented: $expecting) { ExpectParcelView(onDone: { expecting = false }) }
    }

    private var subtitle: String {
        let today = store.expectedToday.count
        let active = store.active.count
        var parts: [String] = []
        if today > 0 { parts.append(today == 1 ? "1 out for delivery" : "\(today) out for delivery") }
        if active > today { parts.append("\(active - today) on the way") }
        if let lastAdded { parts.append(lastAdded == 0 ? "nothing new in that" : "\(lastAdded) added") }
        return parts.isEmpty ? "Nothing on its way" : parts.joined(separator: " · ")
    }

    private var dropZone: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope.open").foregroundStyle(dropHighlight ? DS.porchlight : DS.ash)
            Text("Drop delivery emails here (from Mail or Outlook) and Doorstep reads the tracking.")
                .font(DS.meta).foregroundStyle(DS.ash)
            Spacer()
        }
        .padding(12)
        .background(DS.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(dropHighlight ? DS.porchlight : .clear, style: StrokeStyle(lineWidth: 1, dash: [4])))
        .onDrop(of: [.fileURL, .emailMessage, .plainText, .utf8PlainText], isTargeted: $dropHighlight) { providers in
            Task { await handleDrop(providers) }
            return true
        }
    }

    private var pasteSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a parcel").font(DS.title)
            Text("Paste a tracking number, or the whole delivery email.").font(DS.body).foregroundStyle(.secondary)
            TextEditor(text: $pasted)
                .font(DS.monoBody)
                .frame(width: 440, height: 200)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(DS.well, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Cancel") { pasting = false }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    add(text: pasted, subject: "", sender: "")
                    pasting = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private func add(text: String, subject: String, sender: String, date: Date = Date()) {
        var found = ParcelParser.parse(subject: subject, from: sender, body: text, date: date)
        // A bare tracking number with no wording: still worth tracking.
        if found.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if trimmed.count >= 8, trimmed.count <= 30, !trimmed.contains(" ") {
                let carrier = Carrier.distinctiveShapes.first { trimmed.range(of: $0.1, options: .regularExpression) != nil }?.0
                found = [Parcel(id: trimmed, tracking: trimmed, carrier: carrier, from: nil, status: .dispatched, updated: Date())]
            }
        }
        withAnimation(DS.settle) { lastAdded = ParcelStore.shared.ingest(found) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) async {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil),
               let raw = try? String(contentsOf: url, encoding: .utf8) ?? String(contentsOf: url, encoding: .isoLatin1) {
                let mail = EmailFile.parse(raw)
                add(text: mail.body, subject: mail.subject, sender: mail.from, date: mail.date ?? Date())
            } else if let text = try? await p.loadItem(forTypeIdentifier: UTType.utf8PlainText.identifier) as? Data,
                      let s = String(data: text, encoding: .utf8) {
                add(text: s, subject: "", sender: "")
            }
        }
    }
}

private struct ParcelRow: View {
    let parcel: Parcel
    var isOpen = false
    let onWatch: (String) -> Void
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
            if isOpen { timeline.transition(.opacity) }
        }
        .padding(.vertical, 10)
        .task(id: parcel.eventId) {
            guard let id = parcel.eventId else { return }
            image = await ThumbnailCache.shared.thumbnail(for: id)
        }
    }

    /// Everything that happened to it, with the clip where there is one.
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array((parcel.steps ?? []).enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        Circle().fill(i == (parcel.steps?.count ?? 0) - 1 ? DS.porchlight : DS.ash)
                            .frame(width: 7, height: 7).padding(.top, 5)
                        if i < (parcel.steps?.count ?? 0) - 1 {
                            Rectangle().fill(DS.well).frame(width: 1).frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: 7)
                    Text(step.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                        .font(DS.monoMeta).foregroundStyle(DS.ash).frame(width: 92, alignment: .leading)
                    Text(step.text).font(DS.body).foregroundStyle(DS.paper)
                    Spacer()
                    if let id = step.eventId {
                        Button { onWatch(id) } label: { Label("Watch", systemImage: "play.fill").font(DS.meta) }
                            .buttonStyle(.plain).foregroundStyle(DS.porchlight)
                    }
                }
                .frame(minHeight: 26, alignment: .top)
            }
            if let expected = parcel.expected, parcel.status < .delivered {
                Text("Due \(expected.formatted(.dateTime.weekday(.wide).day().month()))")
                    .font(DS.meta).foregroundStyle(DS.porchlight).padding(.leading, 17).padding(.top, 4)
            }
            if let checked = parcel.lastChecked {
                Text("Tracking checked \(checked.formatted(.relative(presentation: .named)))")
                    .font(DS.meta).foregroundStyle(DS.ash).padding(.leading, 17).padding(.top, 2)
            }
        }
        .padding(.leading, 86)
    }

    private var summary: some View {
        HStack(spacing: 14) {
            ZStack {
                DS.slate
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: parcel.carrier?.symbol ?? "shippingbox")
                        .font(.system(size: 18)).foregroundStyle(statusColour)
                }
            }
            .frame(width: 72, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(parcel.title).font(DS.bodyStrong).foregroundStyle(DS.paper).lineLimit(1)
                HStack(spacing: 6) {
                    Text(parcel.isExpectedToday && parcel.status < .outForDelivery ? "Due today" : parcel.status.label)
                        .foregroundStyle(statusColour)
                        .fixedSize()
                    if let c = parcel.carrier { Text("·"); Text(c.rawValue) }
                    Text("·")
                    Text(parcel.deliveredAt ?? parcel.updated, format: .dateTime.weekday(.abbreviated).hour().minute())
                        .font(DS.monoMeta)
                        .fixedSize()
                }
                .font(DS.meta).foregroundStyle(DS.ash)
                .lineLimit(1)
                if let t = parcel.tracking {
                    Text(t).font(DS.monoMeta).foregroundStyle(DS.ash).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if let url = parcel.trackingURL {
                Button { NSWorkspace.shared.open(url) } label: { Text("Track") }.fixedSize()
            }
            if let id = parcel.eventId {
                Button { onWatch(id) } label: { Image(systemName: "play.fill") }
                    .fixedSize().help("Watch it arrive").accessibilityLabel("Watch it arrive")
            }
            Menu {
                if parcel.status < .delivered {
                    Button("Mark as delivered") { ParcelStore.shared.markDelivered(parcel) }
                }
                if let due = parcel.expected, parcel.status < .delivered {
                    Button("Add to Calendar") { ParcelCalendar.add(parcel, on: due) }
                }
                if let t = parcel.tracking {
                    Button("Copy tracking number") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(t, forType: .string)
                    }
                }
                Divider()
                Button("Remove", role: .destructive) { ParcelStore.shared.dismiss(parcel) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Parcel actions")
        }
    }

    private var statusColour: Color {
        switch parcel.status {
        case _ where parcel.isExpectedToday: return DS.porchlight
        case .outForDelivery: return DS.porchlight
        case .attempted: return DS.ember
        case .delivered, .collected: return DS.paper
        default: return DS.ash
        }
    }
}

/// Just enough of an .eml file: headers and a readable body.
enum EmailFile {
    struct Mail { var subject = ""; var from = ""; var date: Date?; var body = "" }

    static func parse(_ raw: String) -> Mail {
        var mail = Mail()
        let parts = raw.components(separatedBy: "\r\n\r\n").count > 1 ? raw.components(separatedBy: "\r\n\r\n")
                                                                      : raw.components(separatedBy: "\n\n")
        let header = parts.first ?? ""
        // Unfold continuation lines.
        let unfolded = header.replacingOccurrences(of: "\r?\n[ \t]+", with: " ", options: .regularExpression)
        for line in unfolded.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            if lower.hasPrefix("subject:") { mail.subject = decodeWords(String(line.dropFirst(8))).trimmingCharacters(in: .whitespaces) }
            if lower.hasPrefix("from:") { mail.from = decodeWords(String(line.dropFirst(5))).trimmingCharacters(in: .whitespaces) }
            if lower.hasPrefix("date:") {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
                mail.date = f.date(from: String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " (").first ?? "")
            }
        }
        var body = parts.dropFirst().joined(separator: "\n\n")
        // Quoted-printable soft breaks and the common escapes; then strip any HTML.
        body = body.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "")
            .replacingOccurrences(of: "=3D", with: "=").replacingOccurrences(of: "=20", with: " ")
            .replacingOccurrences(of: "=C2=A0", with: " ")
        mail.body = Mailbox.plain(body)
        return mail
    }

    /// =?utf-8?Q?...?= and =?utf-8?B?...?= header words.
    static func decodeWords(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([QqBb])\?([^?]*)\?="#) else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: s), let enc = Range(m.range(at: 2), in: s), let txt = Range(m.range(at: 3), in: s) else { continue }
            var decoded = String(s[txt])
            if s[enc].uppercased() == "B" {
                decoded = Data(base64Encoded: decoded).flatMap { String(data: $0, encoding: .utf8) } ?? decoded
            } else {
                decoded = decoded.replacingOccurrences(of: "_", with: " ")
                decoded = decoded.replacingOccurrences(of: "=([0-9A-F]{2})", with: "%$1", options: .regularExpression)
                    .removingPercentEncoding ?? decoded
            }
            out.replaceSubrange(Range(m.range, in: out) ?? r, with: decoded)
        }
        return out
    }
}


import EventKit

/// Puts a parcel's due day in the calendar. Write-only access: Doorstep can't read it.
enum ParcelCalendar {
    static func add(_ parcel: Parcel, on day: Date) {
        let store = EKEventStore()
        store.requestWriteOnlyAccessToEvents { granted, _ in
            guard granted else { return }
            let e = EKEvent(eventStore: store)
            e.title = "\(parcel.title) due"
            e.isAllDay = true
            e.startDate = Calendar.current.startOfDay(for: day)
            e.endDate = e.startDate.addingTimeInterval(86400)
            var notes = "Added by Doorstep."
            if let c = parcel.carrier { notes += " Carrier: \(c.rawValue)." }
            if let t = parcel.tracking { notes += " Tracking: \(t)." }
            e.notes = notes
            if let url = parcel.trackingURL { e.url = url }
            e.calendar = store.defaultCalendarForNewEvents
            try? store.save(e, span: .thisEvent)
        }
    }
}
