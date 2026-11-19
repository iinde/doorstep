import SwiftUI

/// Shown once, over the main window: where things are, and the few choices most people want.
struct WelcomeCard: View {
    let onDone: () -> Void
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("callPanelEnabled") private var callPanel = true
    @AppStorage("speakAnnouncements") private var speak = false
    @AppStorage("settingsTab") private var settingsTab = "General"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                DoorstepMark(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Doorstep").font(.system(size: 22, weight: .semibold)).foregroundStyle(DS.paper)
                    Text("Everything now lives in this one window.").font(DS.body).foregroundStyle(DS.ash)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                where_("square.grid.2x2", "Live", "every camera at once. Click one to make it big.")
                where_("clock.arrow.circlepath", "History", "each day's visits, deliveries and recordings, with search.")
                where_("map", "Map, Radar and Insights", "where and when things happen around your home.")
                where_("menubar.rectangle", "Menu bar icon", "still there for a quick look, any time.")
            }
            Divider()
            VStack(spacing: 12) {
                Picker("Appearance", selection: $appearance) {
                    Text("Match my Mac").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, _ in AppearanceSetting.apply() }
                row("Pop the doorbell up on screen when someone rings", $callPanel)
                row("Say who's at the door out loud", $speak)
            }
            .toggleStyle(.switch)
            .font(DS.body)
            .foregroundStyle(DS.paper)
            HStack {
                SettingsLink { Text("Record on this Mac…") }
                    .simultaneousGesture(TapGesture().onEnded { settingsTab = "Recording" })
                SettingsLink { Text("Replies and couriers…") }
                    .simultaneousGesture(TapGesture().onEnded { settingsTab = "Alerts" })
                Spacer()
                Button("Get started", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(DS.porchlight)
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(DS.night, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(DS.well))
        .shadow(color: .black.opacity(0.35), radius: 40, y: 12)
    }

    private func row(_ label: String, _ on: Binding<Bool>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Toggle(label, isOn: on).labelsHidden()
        }
    }

    private func where_(_ symbol: String, _ name: String, _ what: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.porchlight).frame(width: 20)
            (Text(name).font(DS.bodyStrong).foregroundColor(DS.paper) + Text(": " + what).font(DS.body).foregroundColor(DS.ash))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
