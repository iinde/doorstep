import SwiftUI
import OpenRingFeature
import DesignSystem
import RingClient
import AppKit

@main
struct OpenRingApp: App {
    @StateObject private var appState = AppState()

    init() {
        // Start global hotkey monitoring
        setupGlobalHotkey()
    }

    var body: some Scene {
        // Menubar app - no dock icon, no main window
        MenuBarExtra {
            MainPopoverView()
                .environmentObject(appState)
        } label: {
            MenuBarIcon(state: appState.menuBarState, events: appState.events)
        }
        .menuBarExtraStyle(.window)

        // History: days, moments, playback
        Window("History", id: "history") {
            HistoryView(devices: appState.devices, seedEvents: appState.events)
        }
        .defaultSize(width: 1180, height: 760)

        // Command centre: live, map, radar, insights
        Window("Command Centre", id: "command") {
            CommandCentreView(devices: appState.devices, events: appState.events)
        }
        .defaultSize(width: 1440, height: 900)

        // "I'm expecting a parcel"
        Window("Expecting a parcel", id: "expect") {
            ExpectWindow()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        // Settings window (opened from popover)
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }

    private func setupGlobalHotkey() {
        Task { @MainActor in
            KeyboardShortcutManager.shared.startMonitoring {
                // When global hotkey is pressed, activate the app
                // This brings focus to the menu bar app
                NSApp.activate(ignoringOtherApps: true)

                // Try to click the menu bar status item
                // Find and click the OpenRing menu bar item
                if let button = findMenuBarButton() {
                    button.performClick(nil)
                }
            }
        }
    }

    private func findMenuBarButton() -> NSStatusBarButton? {
        // Find our app's menu bar button by checking all status items
        // This is a workaround since MenuBarExtra doesn't expose the status item
        guard let statusItems = NSStatusBar.system.value(forKey: "statusItems") as? [NSStatusItem] else {
            return nil
        }

        // Find the status item with our icon (bell icon)
        for item in statusItems {
            if let button = item.button,
               let image = button.image,
               ["MenuBarMark", "MenuBarMarkBadge"].contains(image.name() ?? "")
                || image.accessibilityDescription?.contains("Doorstep") == true {
                return button
            }
        }

        // If not found by image, just return the last status item (most recently added)
        return statusItems.last?.button
    }
}

// MARK: - Main Popover View (handles auth state)

struct MainPopoverView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.authState {
            case .authenticated:
                AuthenticatedPopoverView()
                    .environmentObject(appState)
            case .unauthenticated, .expired:
                LoginView {
                    Task {
                        await appState.onLoginSuccess()
                    }
                }
            case .loading:
                loadingView
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: Spacing.lg) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading...")
                .font(.Ring.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: Layout.Popover.width, height: 200)
    }
}

// MARK: - Authenticated Popover View

struct AuthenticatedPopoverView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        PopoverView(
            devices: appState.devices,
            events: appState.events,
            selectedDevice: $appState.selectedDevice,
            onRefresh: {
                Task {
                    await appState.loadData()
                }
            }
        )
    }
}

// MARK: - App State

enum AuthViewState {
    case loading
    case unauthenticated
    case authenticated
    case expired
}

@MainActor
final class AppState: ObservableObject {
    @Published var authState: AuthViewState = .loading
    @Published var menuBarState: MenuBarState = .normal
    @Published var isLiveViewActive = false
    @Published var isSnoozed = false
    @Published var motionAlertsEnabled = true

    @Published var selectedDevice: RingDevice?
    @Published var devices: [RingDevice] = []
    @Published var events: [RingEvent] = []

    // Background polling for notifications
    private var pollingTask: Task<Void, Never>?

    enum MenuBarState {
        case normal
        case hasNewEvent
        case liveActive
        case authExpired
        case offline
    }

    init() {
        NSLog("🚀 AppState init - starting session restore")
        installShutdownHandlers()
        AppUpdater.shared.start()
        // Someone walking up to the door, seen in the live video before they ring.
        LiveIntel.shared.onApproach = { [weak self] id in
            guard let self, UserDefaults.standard.object(forKey: "approachAlerts") as? Bool ?? true,
                  !DoorbellCallController.shared.isShowing,
                  let device = self.devices.first(where: { $0.id == id }), device.deviceType == .doorbell else { return }
            NSLog("🚶 Someone approaching \(device.name)")
            Automations.shared.fire(.approaching, camera: device.name, detail: "")
            DoorbellCallController.shared.show(device: device, event: nil, title: "Someone's coming to \(device.name)")
        }
        // "Watch door" from a notification: show that camera live in the call panel.
        NotificationManager.shared.onWatchDevice = { [weak self] id in
            guard let self, let device = self.devices.first(where: { $0.id == id }) else { return }
            DoorbellCallController.shared.show(device: device, event: nil, title: "\(device.name), live")
        }
        // Try to restore session on launch
        Task {
            NSLog("🚀 Task started for session restore")
            await restoreSession()
            NSLog("🚀 Session restore completed")
            // Launch with `-DoorstepDebugWindow YES` to show the popover content in a
            // normal window, so the UI can be screenshotted without a menu bar click.
            if UserDefaults.standard.bool(forKey: "DoorstepDebugWindow") {
                self.openDebugWindow()
            }
            if UserDefaults.standard.bool(forKey: "DoorstepPreviewLogin") {
                // Shows the sign-in screen in its own window; doesn't touch the session.
                let host = NSHostingController(rootView: LoginView(onLoginSuccess: {}))
                let w = NSWindow(contentViewController: host)
                w.title = "Sign in (preview)"
                w.styleMask = [.titled, .closable]
                w.makeKeyAndOrderFront(nil)
                self.previewWindow = w
            }
            // `-DoorstepCommandCentre YES`: open the command centre in a window for screenshots.
            if UserDefaults.standard.bool(forKey: "DoorstepCommandCentre") {
                let host = NSHostingController(rootView: CommandCentreView(devices: self.devices, events: self.events))
                let w = NSWindow(contentViewController: host)
                w.title = (DemoMode.isOn ? "Doorstep" : "Command Centre (debug)")
                w.setContentSize(NSSize(width: 1440, height: 900))
                w.makeKeyAndOrderFront(nil)
                self.centreWindow = w
            }
            if UserDefaults.standard.bool(forKey: "DoorstepTestCall") {
                self.showTestCall()
            }
        }
    }

    // MARK: Clean shutdown
    // Killing the app without ending its live sessions leaves them open at Ring,
    // which then refuses new sessions for those cameras until they time out.

    private var sigtermSource: DispatchSourceSignal?
    private var centreWindow: NSWindow?

    private func installShutdownHandlers() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppState.endLiveSessions() }
        }
        // `kill`/pkill sends SIGTERM, which skips willTerminate. Route it through terminate.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigtermSource = source
    }

    /// End every live session with Ring, waiting up to 3s. Runs off the main thread
    /// so it can't deadlock with the main-actor callbacks sessions fire.
    static func endLiveSessions() {
        let sessions = MultiStreamManager.shared.sessionsForShutdown()
        guard !sessions.isEmpty else { return }
        NSLog("👋 Ending \(sessions.count) live sessions before quitting")
        let group = DispatchGroup()
        for session in sessions {
            group.enter()
            Task.detached {
                await session.stop()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 3)
    }

    private var debugWindow: NSWindow?
    private var previewWindow: NSWindow?
    private func openDebugWindow() {
        let host = NSHostingController(rootView: MainPopoverView().environmentObject(self))
        let window = NSWindow(contentViewController: host)
        window.title = (DemoMode.isOn ? "Doorstep" : "Doorstep (debug)")
        window.styleMask = [.titled, .closable, .resizable]
        // Fixed size: letting the window track content size loops AppKit's layout.
        window.setContentSize(NSSize(width: 640, height: 860))
        window.center()
        window.makeKeyAndOrderFront(nil)
        // Fit to the content once it has laid out (no dead space).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak window, weak host] in
            guard let window, let host else { return }
            let size = host.view.fittingSize
            if size.width > 0, size.height > 0 { window.setContentSize(size) }
        }
        NSApp.activate(ignoringOtherApps: true)
        debugWindow = window
        NSLog("🪟 Debug window opened")
    }

    func restoreSession() async {
        // Demo mode: made-up home, no Ring account, nothing saved.
        if DemoMode.isOn {
            devices = DemoData.devices
            events = DemoData.load()
            selectedDevice = devices.first
            authState = .authenticated
            return
        }
        authState = .loading
        NSLog("🔐 Restoring session...")

        do {
            let restored = try await RingClient.shared.restoreSession()
            NSLog("🔐 Session restored: \(restored)")
            if restored {
                authState = .authenticated
                await loadData()

                // Request notification permission and start polling
                _ = await NotificationManager.shared.requestPermission()
                startPolling()
            } else {
                authState = .unauthenticated
            }
        } catch {
            NSLog("🔐 Failed to restore session: \(error)")
            authState = .unauthenticated
        }
    }

    func onLoginSuccess() async {
        authState = .authenticated
        await loadData()

        // Request notification permission and start polling
        _ = await NotificationManager.shared.requestPermission()
        startPolling()
    }

    func loadData() async {
        NSLog("📡 Loading data...")
        do {
            devices = try await RingClient.shared.fetchDevices()
            EventDirectory.shared.registerDevices(devices)
            NSLog("✅ Loaded \(devices.count) devices: \(devices.map { $0.name })")

            let newEvents = try await RingClient.shared.fetchAllRecentEvents(limit: 50)
            EventDirectory.shared.register(newEvents)
            NSLog("✅ Loaded \(newEvents.count) events")
            let recent = newEvents.filter { $0.createdAt > Date().addingTimeInterval(-3600) }
            let kinds = Dictionary(grouping: recent, by: { "\($0.deviceName ?? "?")/\($0.rawKind)" }).mapValues(\.count)
            NSLog("🗂 Last hour by camera/kind: \(kinds.sorted { $0.key < $1.key })")

            // Detect new events and send notifications
            // New events: looked at, automations run, and a notification if alerts are on.
            let detectedEvents = NotificationManager.shared.detectNewEvents(old: events, new: newEvents)
            let notify = motionAlertsEnabled && !isSnoozed
            for event in detectedEvents {
                // Each waits briefly for the clip to be looked at; don't hold up the refresh.
                Task { await NotificationManager.shared.sendNotification(for: event, notify: notify) }
                if notify { menuBarState = .hasNewEvent }
            }

            events = newEvents
            afterRefresh()

            // Tag today's newest clips on this Mac in the background (each clip once).
            let todays = newEvents
                .filter { Calendar.current.isDateInToday($0.createdAt) && MomentBuilder.isOutsideEvent($0) }
                .prefix(20)
                .map(\.id)
            if UserDefaults.standard.object(forKey: "onDeviceTagging") as? Bool ?? true {
                Task.detached(priority: .utility) { await ThumbnailCache.shared.tagRecent(Array(todays)) }
            }

            if selectedDevice == nil {
                // Prefer doorbell devices first (Front Door priority)
                selectedDevice = devices.first(where: { $0.deviceType == .doorbell }) ?? devices.first
                NSLog("📱 Selected device: \(selectedDevice?.name ?? "none")")
            }

            // Only reset to normal if we didn't just get new events
            if menuBarState != .hasNewEvent {
                menuBarState = .normal
            }
        } catch let error as RingAPIError {
            NSLog("❌ API error loading data: \(error)")
            if case .unauthorized = error {
                authState = .expired
                menuBarState = .authExpired
                stopPolling()
            }
        } catch {
            NSLog("❌ Failed to load data: \(error)")
        }
    }

    // MARK: Intelligence housekeeping after each refresh

    private var lastMailCheck = Date.distantPast

    private func afterRefresh() {
        let devices = self.devices, events = self.events
        let doorbells = Set(devices.filter { $0.deviceType == .doorbell }.map { String($0.id) })
        ParcelStore.shared.link(moments: MomentBuilder.build(from: events), doorbellKeys: doorbells)
        Task { await DailyBrief.sendIfDue(events: events) }
        let moments = MomentBuilder.build(from: events)
        Task { await RainWatch.shared.check(moments: moments) }
        // Recording on this Mac (no Ring subscription needed) and battery-camera stills.
        Task {
            await RecorderController.shared.sync(devices: devices)
            await Snapshotter.shared.tick(devices: devices)
        }
        for e in events where e.createdAt > Date().addingTimeInterval(-120) {
            RecorderController.shared.ringEvent(e)
        }
        Task {
            await Tracker.shared.checkAll()
            await DeliveryWatch.remindIfDue(doorbellId: devices.first(where: { $0.deviceType == .doorbell })?.id)
        }
        if ClipArchive.isOn {
            Task.detached(priority: .background) { await ClipArchive.shared.archive(events) }
        }
        // Mail every 15 minutes, only if a mailbox is signed in.
        if Date().timeIntervalSince(lastMailCheck) > 15 * 60 {
            lastMailCheck = Date()
            Task {
                await Mailbox.shared.refreshState()
                await Mailbox.shared.check()
                ParcelStore.shared.link(moments: MomentBuilder.build(from: events), doorbellKeys: doorbells)
            }
        }
    }

    func logout() async {
        stopPolling()
        do {
            try await RingClient.shared.logout()
        } catch {
            print("Logout error: \(error)")
        }
        devices = []
        events = []
        selectedDevice = nil
        authState = .unauthenticated
        menuBarState = .normal
    }

    // MARK: - Background Polling

    @AppStorage("pollingInterval") private var pollingInterval: Int = 30

    // MARK: Doorbell watch
    // Ring pushes rings to its own app; we can't receive those, so we check just the
    // doorbells' newest events every 10s (one small request each) and ring the panel.

    private var doorbellTask: Task<Void, Never>?
    private var announcedDings: Set<String> = []

    func startDoorbellWatch() {
        guard doorbellTask == nil else { return }
        doorbellTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { break }
                await self.checkDoorbells()
            }
        }
    }

    private func checkDoorbells() async {
        let doorbells = devices.filter { $0.deviceType == .doorbell }
        for bell in doorbells {
            // Expecting a parcel: someone at the door (no ring needed) opens the live panel.
            if DeliveryWatch.isActive,
               let recent = try? await RingClient.shared.fetchEvents(deviceId: bell.id, limit: 3, olderThan: nil),
               let visit = recent.filter({ $0.kind == .motion && $0.personDetected != false })
                   .max(by: { $0.createdAt < $1.createdAt }),
               Date().timeIntervalSince(visit.createdAt) < 90, !announcedDings.contains(visit.id) {
                announcedDings.insert(visit.id)
                NSLog("📦 Delivery watch: someone at \(bell.name)")
                DoorbellCallController.shared.show(device: bell, event: visit, title: "Possible delivery at \(bell.name)")
            }
            guard let recent = try? await RingClient.shared.fetchEvents(deviceId: bell.id, limit: 3, olderThan: nil),
                  let ding = recent.filter({ $0.kind == .ding }).max(by: { $0.createdAt < $1.createdAt }),
                  Date().timeIntervalSince(ding.createdAt) < 90,
                  !announcedDings.contains(ding.id) else { continue }
            announcedDings.insert(ding.id)
            NSLog("🔔 Doorbell: \(bell.name) rang at \(ding.createdAt)")
            Automations.shared.fire(.doorbell, camera: bell.name, detail: "")
            if UserDefaults.standard.object(forKey: "callPanelEnabled") as? Bool ?? true {
                DoorbellCallController.shared.show(device: bell, event: ding)
            }
            await loadData()
        }
    }

    /// `-DoorstepTestCall YES`: show the call panel with the doorbell's latest event.
    private func showTestCall() {
        guard let bell = devices.first(where: { $0.deviceType == .doorbell }),
              let event = events.first(where: { $0.deviceId == bell.id }) else { return }
        DoorbellCallController.shared.show(device: bell, event: event)
    }

    func startPolling() {
        guard pollingTask == nil else { return }
        let interval = pollingInterval
        NSLog("🔄 Starting background polling (every \(interval)s)")
        startDoorbellWatch()

        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await loadData()
            }
        }
    }

    func stopPolling() {
        NSLog("🔄 Stopping background polling")
        pollingTask?.cancel()
        pollingTask = nil
        doorbellTask?.cancel()
        doorbellTask = nil
    }

    func updatePollingInterval(_ newInterval: Int) {
        NSLog("🔄 Updating polling interval to \(newInterval)s")
        stopPolling()
        startPolling()
    }

    func toggleSnooze() {
        isSnoozed.toggle()
        // TODO: Implement snooze logic
    }

    func toggleMotionAlerts() {
        motionAlertsEnabled.toggle()
        // TODO: Persist setting
    }

    func startLiveView(for device: RingDevice) async {
        isLiveViewActive = true
        menuBarState = .liveActive
        // TODO: Start actual live view
    }

    func stopLiveView() {
        isLiveViewActive = false
        menuBarState = .normal
    }
}

// MARK: - Menubar Icon

struct MenuBarIcon: View {
    let state: AppState.MenuBarState
    let events: [RingEvent]
    @ObservedObject private var reviews = ReviewStore.shared

    /// Someone rang, or a person was seen today, and you haven't looked yet.
    private var hasUnseen: Bool {
        MomentBuilder.build(from: events).contains {
            $0.tier >= .people && Calendar.current.isDateInToday($0.end) && !reviews.isReviewed($0)
        }
    }

    var body: some View {
        // The Doorstep mark as a template: the menu bar tints it like every other Mac app.
        // A dot means someone came and you haven't looked yet.
        Group {
            switch state {
            case .authExpired, .offline:
                Image(systemName: "exclamationmark.circle")
            default:
                Image(hasUnseen ? "MenuBarMarkBadge" : "MenuBarMark").renderingMode(.template)
            }
        }
        .accessibilityLabel(state == .authExpired ? "Doorstep, sign in again"
                            : hasUnseen ? "Doorstep, new visitors" : "Doorstep")
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            IntelligenceSettings()
                .tabItem { Label("Intelligence", systemImage: "sparkle.magnifyingglass") }
            ParcelsSettings()
                .tabItem { Label("Parcels", systemImage: "shippingbox") }
            RecordingSettings(devices: appState.devices)
                .tabItem { Label("Recording", systemImage: "record.circle") }
            AutomationsSettings(devices: appState.devices)
                .tabItem { Label("Automations", systemImage: "bolt.horizontal.circle") }
            AccountSettings()
                .environmentObject(appState)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 600)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("pollingInterval") private var pollingInterval: Int = 30
    @AppStorage("notificationSound") private var notificationSound: Bool = true
    @AppStorage("callPanelEnabled") private var callPanelEnabled: Bool = true
    @AppStorage("globalHotkey") private var globalHotkey: String = "⌘`"

    var body: some View {
        Form {
            Section {
                Toggle("Show a call window when someone rings", isOn: $callPanelEnabled)
            } footer: {
                Text("Doorstep checks your doorbell every 10 seconds, so the window can arrive a few seconds after a ring.")
            }
            Section("Alerts") {
                Toggle("Notify me about rings and motion", isOn: $appState.motionAlertsEnabled)
                Toggle("Play a sound", isOn: $notificationSound)
                Picker("Check for new events", selection: $pollingInterval) {
                    Text("Every 15 seconds").tag(15)
                    Text("Every 30 seconds").tag(30)
                    Text("Every minute").tag(60)
                    Text("Every 2 minutes").tag(120)
                }
                .onChange(of: pollingInterval) { _, v in appState.updatePollingInterval(v) }
            }
            Section {
                Toggle("Open Doorstep from anywhere", isOn: Binding(
                    get: { KeyboardShortcutManager.shared.isGlobalHotkeyEnabled },
                    set: { KeyboardShortcutManager.shared.setEnabled($0) }
                ))
                HotkeyPicker(selectedHotkey: $globalHotkey, options: ["⌘`", "⌘⇧R", "⌘⌥O", "⌃⌥Space"])
                    .disabled(!KeyboardShortcutManager.shared.isGlobalHotkeyEnabled)
            } header: {
                Text("Keyboard")
            } footer: {
                Text("⌘1 to ⌘4 open a camera. ⌘Y opens History. Esc goes back.")
            }
            UpdateSettings()
        }
        .formStyle(.grouped)
        .frame(height: 600)
    }
}

private struct IntelligenceSettings: View {
    @AppStorage("onDeviceTagging") private var onDeviceTagging: Bool = true
    @State private var cacheSize: String = "…"

    var body: some View {
        Form {
            Section {
                Toggle("Look for people, parcels, animals and vehicles", isOn: $onDeviceTagging)
            } footer: {
                Text("Uses Apple's Vision framework on this Mac. Clips are never sent anywhere else. Things that are always in a camera's view, like parked cars, are learned and ignored.")
            }
            WhoWasItSettings()
            Section("Storage") {
                LabeledContent("Thumbnails and tags", value: cacheSize)
                Button("Clear cache") {
                    if let dir = cacheDir { try? FileManager.default.removeItem(at: dir) }
                    measure()
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .onAppear(perform: measure)
    }

    private var cacheDir: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Doorstep", isDirectory: true)
    }

    private func measure() {
        guard let dir = cacheDir,
              let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            cacheSize = "Empty"; return
        }
        var total = 0
        for case let url as URL in files {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        cacheSize = total == 0 ? "Empty" : ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }
}

private struct AccountSettings: View {
    @EnvironmentObject var appState: AppState
    @State private var email: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Ring account", value: email ?? "Signed in")
                LabeledContent("Cameras", value: "\(appState.devices.filter { $0.deviceType != .chime }.count)")
            } footer: {
                Text("Doorstep talks directly to Ring. Your sign-in is kept in your Mac's Keychain.")
            }
            Section {
                Button("Sign out", role: .destructive) {
                    Task { await appState.logout() }
                }
                .disabled({ if case .authenticated = appState.authState { return false }; return true }())
            }
        }
        .formStyle(.grouped)
        .frame(height: 260)
        .task { email = await RingClient.shared.currentEmail }
    }
}



/// Hosts the expecting-a-parcel form as its own small window (menu bar popovers drop sheets).
struct ExpectWindow: View {
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        ExpectParcelView(onDone: { dismissWindow(id: "expect") })
            .preferredColorScheme(.dark)
    }
}
