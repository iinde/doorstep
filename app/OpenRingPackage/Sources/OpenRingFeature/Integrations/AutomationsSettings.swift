import SwiftUI
import RingClient

/// Settings › Automations: "when this happens at the door, run that Shortcut".
public struct AutomationsSettings: View {
    let devices: [RingDevice]
    @ObservedObject private var automations = Automations.shared
    @AppStorage("speakAnnouncements") private var speak = false

    public init(devices: [RingDevice]) { self.devices = devices }

    public var body: some View {
        Form {
            Section {
                Toggle("Say what's happening out loud", isOn: $speak)
            } footer: {
                Text("\"Someone's at the door\", \"DPD at the front door\", \"A parcel was left\". Uses your Mac's British voice.")
            }

            Section {
                if automations.rules.isEmpty {
                    Text("None yet. Examples: turn the porch light on when someone walks up after dark; pause the music when the doorbell rings.")
                        .foregroundStyle(.secondary)
                }
                ForEach($automations.rules) { $rule in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            Picker("When", selection: $rule.trigger) {
                                ForEach(DoorTrigger.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            Text("at").foregroundStyle(.secondary)
                            Picker("Camera", selection: $rule.camera) {
                                Text("any camera").tag(String?.none)
                                ForEach(devices.filter { $0.deviceType != .chime }, id: \.id) { Text($0.name).tag(String?.some($0.name)) }
                            }
                            .labelsHidden()
                            .frame(width: 130)
                        }
                        HStack {
                            Text("run").foregroundStyle(.secondary)
                            Picker("Shortcut", selection: $rule.shortcut) {
                                if !automations.shortcutNames.contains(rule.shortcut) { Text(rule.shortcut.isEmpty ? "Choose a shortcut" : rule.shortcut).tag(rule.shortcut) }
                                ForEach(automations.shortcutNames, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            Toggle("only after dark", isOn: $rule.onlyAfterDark).controlSize(.small)
                            Spacer()
                            Button("Test") { automations.test(rule) }.disabled(rule.shortcut.isEmpty)
                            Button(role: .destructive) {
                                automations.rules.removeAll { $0.id == rule.id }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete automation")
                        }
                    }
                    .padding(.vertical, 4)
                }
                HStack {
                    Button("Add automation") {
                        automations.rules.append(Automation(trigger: .approaching,
                                                            shortcut: automations.shortcutNames.first ?? "", onlyAfterDark: true))
                    }
                    Button("Open Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
                    Spacer()
                    if let last = automations.lastRun { Text(last).font(.caption).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Automations")
            } footer: {
                Text("Runs one of your Shortcuts, so anything Shortcuts can do (Home lights, Music, Messages, scripts) can react to your door. The shortcut receives a line of text saying what happened. \"After dark\" uses sunset at your home.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .task { await automations.loadShortcuts() }
    }
}
