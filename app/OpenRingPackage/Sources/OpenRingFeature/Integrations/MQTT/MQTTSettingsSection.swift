import SwiftUI
import RingClient

/// Settings section for the optional Home Assistant / Homebridge connection over MQTT.
/// Drop it into a `Form`.
public struct MQTTSettingsSection: View {
    @ObservedObject private var bridge: HomeAssistantBridge
    @State private var password = ""
    @State private var passwordLoaded = false
    @State private var busy = false

    public init(bridge: HomeAssistantBridge = .shared) { self.bridge = bridge }

    public var body: some View {
        Section {
            TextField("Broker address", text: $bridge.settings.host, prompt: Text("homeassistant.local or 192.168.1.10"))
                .textContentType(.URL)
                .autocorrectionDisabled()
            TextField("Port", value: $bridge.settings.port, format: .number.grouping(.never))
            TextField("Username", text: $bridge.settings.username)
                .textContentType(.username)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
                .textContentType(.password)
            Toggle("Use TLS", isOn: Binding(
                get: { bridge.settings.useTLS },
                set: { on in
                    bridge.settings.useTLS = on
                    if on && bridge.settings.port == 1883 { bridge.settings.port = 8883 }
                    if !on && bridge.settings.port == 8883 { bridge.settings.port = 1883 }
                }))
            if bridge.settings.useTLS {
                Toggle("Trust the broker's own certificate", isOn: $bridge.settings.trustSelfSigned)
                if bridge.settings.trustSelfSigned, bridge.settings.pinnedCertificate != nil {
                    HStack {
                        Text("Certificate remembered").foregroundStyle(.secondary)
                        Spacer()
                        Button("Forget") { bridge.forgetCertificate() }
                    }
                }
            }
            HStack {
                Circle()
                    .fill(bridge.isConnected ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(bridge.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if bridge.settings.enabled {
                    Button("Disconnect") { run { await bridge.disconnect() } }
                } else {
                    Button("Connect") {
                        run {
                            try? await KeychainManager.shared.saveSecret(password, for: MQTTBrokerSettings.keychainKey)
                            await bridge.connect()
                        }
                    }
                    .disabled(bridge.settings.host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .disabled(busy)
        } header: {
            Text("Home Assistant (MQTT)")
        } footer: {
            Text("""
            Optional. Doorstep sends what it sees to your own MQTT broker, such as the Mosquitto add-on in Home Assistant, and talks to nothing else. \
            Each camera then appears in Home Assistant on its own, with a person and doorbell sensor, the last visitor, the last event time, \
            parcels left or taken, battery level and the latest snapshot. You also get a Mode control (Home, Away, Night or Quiet) and a count of parcels due today. \
            Homebridge can use the same topics through an MQTT plugin. Your password is kept in the Mac's Keychain.
            """)
        }
        .task {
            guard !passwordLoaded else { return }
            passwordLoaded = true
            password = ((try? await KeychainManager.shared.secret(for: MQTTBrokerSettings.keychainKey)) ?? nil) ?? ""
        }
    }

    private func run(_ work: @escaping @MainActor () async -> Void) {
        busy = true
        Task { @MainActor in
            await work()
            busy = false
        }
    }
}
