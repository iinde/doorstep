import SwiftUI
import AppKit
import Sparkle

/// Updates from GitHub Releases via Sparkle. Every update is checked against Doorstep's
/// EdDSA public key (in Info.plist) and its code signature before it is installed, so a
/// tampered download is refused. No server of ours: the feed is a file on the release.
@MainActor
public final class AppUpdater: NSObject, ObservableObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    public static let shared = AppUpdater()

    private var controller: SPUStandardUpdaterController!
    @Published public private(set) var canCheck = false
    @Published public var automaticallyChecks: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    @Published public var automaticallyDownloads: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = automaticallyDownloads }
    }

    public var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    public var lastChecked: Date? { controller.updater.lastUpdateCheckDate }

    private override init() {
        automaticallyChecks = true
        automaticallyDownloads = false
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        // Development builds (scripts/build.sh) never update themselves into a release copy.
        if Bundle.main.bundlePath.contains("/Build/Products/Debug/") {
            controller.updater.automaticallyChecksForUpdates = false
        }
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloads = controller.updater.automaticallyDownloadsUpdates
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    /// Call once at launch so scheduled checks start.
    public func start() {
        _ = controller
        // Testing: `-DoorstepCheckUpdatesNow YES` runs a visible check right after launch.
        if UserDefaults.standard.bool(forKey: "DoorstepCheckUpdatesNow") {
            Task { try? await Task.sleep(for: .seconds(3)); checkForUpdates() }
        }
    }

    public func checkForUpdates() {
        // A menu bar app isn't frontmost; bring it forward so the update window is seen.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// Testing only: `-DoorstepFeedURL http://127.0.0.1:8123/appcast.xml` points at a local
    /// feed. The update must still carry Doorstep's EdDSA signature, so this can't sneak
    /// anything in.
    public nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "DoorstepFeedURL")
        #else
        nil
        #endif
    }

    // MARK: Menu bar apps: show scheduled updates gently, in front

    public nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    public nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        true
    }

    public nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }
}

/// Settings section: version, check now, automatic options.
public struct UpdateSettings: View {
    @ObservedObject private var updater = AppUpdater.shared

    public init() {}

    public var body: some View {
        Section {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Doorstep").font(.system(size: 17, weight: .semibold))
                    Text("Version \(updater.version)").font(.callout).foregroundStyle(.secondary)
                }
            }
            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
            Toggle("Download and install updates automatically", isOn: $updater.automaticallyDownloads)
                .disabled(!updater.automaticallyChecks)
            HStack {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
                Spacer()
                if let last = updater.lastChecked {
                    Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Updates come from Doorstep's GitHub releases and are checked against Doorstep's signature before they install.")
        }
    }
}
