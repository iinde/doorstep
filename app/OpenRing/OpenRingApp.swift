import SwiftUI
import UserNotifications
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

        // Draw a camera's zone
        WindowGroup("Zone", id: "zone", for: Int.self) { $id in
            ZoneWindow(deviceId: id ?? 0).environmentObject(appState)
        }
        .windowResizability(.contentSize)

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
    /// Every camera on the Ring account, including ones you've hidden.
    @Published var allDevices: [RingDevice] = []
    private var demoEvents: [RingEvent] = []
    /// The cameras you've chosen to see. Everything in the app works from this list.
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
        // Someone hanging around: alert (and to the phone), run automations.
        LiveIntel.shared.onLoiter = { [weak self] id, seconds in
            guard let self, AlertKind.people.isOn, Modes.shared.allowsAlerts(camera: id),
                  let device = self.devices.first(where: { $0.id == id }) else { return }
            Automations.shared.fire(.loitering, camera: device.name, detail: "\(seconds) seconds")
            let c = UNMutableNotificationContent()
            c.title = "Someone's hanging around \(device.name)"
            c.body = "They've been there for \(seconds) seconds."
            c.userInfo = ["watchDevice": id]
            c.categoryIdentifier = NotificationManager.watchCategory
            if UserDefaults.standard.object(forKey: "notificationSound") as? Bool ?? true { c.sound = .default }
            Task {
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "loiter-\(id)-\(Date().timeIntervalSince1970)", content: c, trigger: nil))
                await PhoneAlerts.send(title: c.title, body: c.body, image: nil)
            }
        }
        // Mirror Doorstep's mode to Ring's own location mode, if asked.
        // Home Assistant can switch Doorstep's mode.
        HomeAssistantBridge.shared.onModeCommand = { name in
            if let m = Modes.Mode.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame }) {
                Modes.shared.enabled = true
                Modes.shared.current = m
            }
        }
        Modes.shared.onChange = { [weak self] mode in
            Task { await HomeAssistantBridge.shared.publishMode(mode) }
            guard let self, UserDefaults.standard.bool(forKey: "syncRingMode"), !DemoMode.isOn else { return }
            let ring: RingLocationMode = [.home: .home, .away: .away, .night: .home, .off: .disarmed][mode] ?? .home
            let locations = Set(self.devices.map(\.locationId))
            Task { for l in locations { try? await RingClient.shared.setLocationMode(l, ring) } }
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
            allDevices = DemoData.devices
            devices = CameraVisibility.visible(allDevices)
            let shown = Set(devices.map(\.id))
            demoEvents = DemoData.load()
            events = demoEvents.filter { $0.deviceId.map(shown.contains) ?? true }
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
                startPush()
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
        startPush()
    }

    func loadData() async {
        NSLog("📡 Loading data...")
        do {
            allDevices = try await RingClient.shared.fetchDevices()
            devices = CameraVisibility.visible(allDevices)
            EventDirectory.shared.registerDevices(devices)
            NSLog("✅ Loaded \(devices.count) devices: \(devices.map { $0.name })")

            let visibleIds = Set(devices.map(\.id))
            let newEvents = try await RingClient.shared.fetchAllRecentEvents(limit: 50)
                .filter { $0.deviceId.map(visibleIds.contains) ?? true }
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
    private var lastBridgeCameras: [Int] = []

    private func afterRefresh() {
        let devices = self.devices, events = self.events
        let doorbells = Set(devices.filter { $0.deviceType == .doorbell }.map { String($0.id) })
        ParcelStore.shared.link(moments: MomentBuilder.build(from: events), doorbellKeys: doorbells)
        Task { await DailyBrief.sendIfDue(events: events) }
        Modes.shared.ensureDefaults(for: devices)
        Modes.shared.tick()
        Task { await HealthMonitor.shared.check(self.allDevices) }
        // Home Assistant: cameras (when the list changes), parcels due, current mode.
        let ids = devices.map(\.id)
        if ids != lastBridgeCameras {
            lastBridgeCameras = ids
            Task {
                await HomeAssistantBridge.shared.startIfEnabled()
                await HomeAssistantBridge.shared.setCameras(devices)
                if Modes.shared.enabled { await HomeAssistantBridge.shared.publishMode(Modes.shared.current) }
            }
        }
        let due = ParcelStore.shared.parcels.filter(\.isExpectedToday).count
        Task { await HomeAssistantBridge.shared.publishParcelsDue(due) }
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

    /// Show or hide a camera. Hidden cameras stop streaming straight away.
    func setHidden(_ id: Int, _ hidden: Bool) {
        CameraVisibility.setHidden(id, hidden)
        devices = CameraVisibility.visible(allDevices)
        let shown = Set(devices.map(\.id))
        events = (DemoMode.isOn ? demoEvents : events).filter { $0.deviceId.map(shown.contains) ?? true }
        EventDirectory.shared.registerDevices(devices)
        Task {
            await MultiStreamManager.shared.stopStreams(except: shown)
            await RecorderController.shared.sync(devices: devices)
            if !hidden, !DemoMode.isOn { await loadData() }
        }
    }

    func logout() async {
        stopPolling()
        await RingPush.shared.stop()
        await RingPush.shared.resetRegistration()
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
            Task { await CourierReply.doorbellRang(bell) }
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

    // MARK: Instant alerts (Ring push, as Ring's own app receives them)

    private var lastPushRefresh = Date.distantPast
    private var pushedDings: Set<String> = []

    /// Listen for Ring's push notifications. Polling carries on as the fallback.
    func startPush() {
        guard !DemoMode.isOn, UserDefaults.standard.object(forKey: "instantAlerts") as? Bool ?? true else { return }
        Task {
            NSLog("⚡️ Instant alerts: starting")
            await RingPush.shared.start { event in
                Task { @MainActor [weak self] in self?.handlePush(event) }
            }
            // Report once it has had a chance to register and connect.
            for wait in [15, 45, 120] {
                try? await Task.sleep(for: .seconds(wait))
                let ok = await RingPush.shared.isConnected
                NSLog("⚡️ Instant alerts: \(ok ? "connected" : "not connected yet (polling continues)")")
                if ok { break }
            }
        }
    }

    private func handlePush(_ event: RingPushEvent) {
        NSLog("⚡️ Push: \(event.kind) at device \(event.deviceId)")
        guard let device = devices.first(where: { $0.id == event.deviceId }) else { return }
        if event.kind == .ding {
            let key = event.eventId ?? "\(event.deviceId)-\(Int(event.createdAt.timeIntervalSince1970 / 30))"
            if !pushedDings.contains(key) {
                pushedDings.insert(key)
                announcedDings.insert(event.eventId ?? key)
                Automations.shared.fire(.doorbell, camera: device.name, detail: "")
                Task { await CourierReply.doorbellRang(device) }
                if UserDefaults.standard.object(forKey: "callPanelEnabled") as? Bool ?? true {
                    DoorbellCallController.shared.show(device: device, event: nil, title: "Someone's at \(device.name)")
                }
            }
        }
        // Fetch the event now (and again shortly, when Ring has the clip) so the alert follows.
        guard Date().timeIntervalSince(lastPushRefresh) > 3 else { return }
        lastPushRefresh = Date()
        Task {
            await loadData()
            try? await Task.sleep(for: .seconds(20))
            await loadData()
        }
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
                .environmentObject(appState)
                .tabItem { Label("General", systemImage: "gearshape") }
            IntelligenceSettings()
                .tabItem { Label("Intelligence", systemImage: "sparkle.magnifyingglass") }
            ParcelsSettings()
                .tabItem { Label("Parcels", systemImage: "shippingbox") }
            RecordingSettings(devices: appState.devices)
                .tabItem { Label("Recording", systemImage: "record.circle") }
            AlertsSettings(devices: appState.devices)
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
            AutomationsSettings(devices: appState.devices)
                .tabItem { Label("Automations", systemImage: "bolt.horizontal.circle") }
            AccountSettings()
                .environmentObject(appState)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 600)
    }
}

/// Which cameras Doorstep shows, grouped by Ring location (e.g. your home and a shared one).
private struct CamerasSection: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var health = HealthMonitor.shared
    @ObservedObject private var zones = ZoneStore.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("syncRingMode") private var syncRingMode = false
    @AppStorage("batterySaver") private var batterySaver = true
    private var chimes: [RingDevice] { appState.allDevices.filter { $0.deviceType == .chime } }

    private var cameras: [RingDevice] { appState.allDevices.filter { $0.deviceType != .chime } }
    private var locations: [[RingDevice]] {
        Dictionary(grouping: cameras, by: \.locationId).values.sorted { $0.count > $1.count }
    }

    var body: some View {
        Section {
            ForEach(Array(locations.enumerated()), id: \.offset) { i, group in
                if locations.count > 1 {
                    HStack {
                        Text(i == 0 ? "Main location" : "Another location").font(.callout.weight(.semibold))
                        Spacer()
                        Button(group.allSatisfy { CameraVisibility.isHidden($0.id) } ? "Show all" : "Hide all") {
                            let hide = !group.allSatisfy { CameraVisibility.isHidden($0.id) }
                            for d in group { appState.setHidden(d.id, hide) }
                        }
                        .controlSize(.small)
                    }
                }
                ForEach(group, id: \.id) { d in
                    HStack(spacing: 10) {
                        Text(d.name)
                        Spacer()
                        if let h = health.health[d.id] {
                            if let bars = h.signalBars {
                                Image(systemName: "wifi", variableValue: Double(bars) / 4)
                                    .help("Wi-Fi \(h.rssi.map { "\($0) dBm" } ?? "") \(h.rssiCategory ?? "")")
                            }
                            if let b = h.batteryPercent ?? d.batteryLevel, d.isBatteryPowered {
                                Text("\(b)%").font(.caption).foregroundStyle(b <= 20 ? .red : .secondary)
                            }
                        } else if let b = d.batteryLevel, d.isBatteryPowered {
                            Text("\(b)%").font(.caption).foregroundStyle(b <= 20 ? .red : .secondary)
                        }
                        if !d.isOnline { Text("Offline").font(.caption).foregroundStyle(.red) }
                        if d.deviceType != .chime {
                            Button(ZoneStore.shared.zones[d.id] == nil ? "Zone…" : "Edit zone…") {
                                openWindow(id: "zone", value: d.id)
                                NSApp.activate(ignoringOtherApps: true)
                            }
                            .controlSize(.small)
                        }
                        Toggle(d.name, isOn: Binding(
                            get: { !CameraVisibility.isHidden(d.id) },
                            set: { appState.setHidden(d.id, !$0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .help("Show \(d.name) in Doorstep")
                    }
                }
            }
        } header: {
            Text("Cameras")
        } footer: {
            Text("Hidden cameras don't appear anywhere in Doorstep, don't stream and don't send alerts. Handy for a shared location, like a family member's house. They stay in your Ring account. A zone is the part of the picture that matters (your path, your drive): people outside it won't alert you.")
        }
        .task { await health.check(appState.allDevices, force: true) }

        if !chimes.isEmpty {
            Section {
                ForEach(chimes, id: \.id) { c in
                    HStack {
                        Text(c.name)
                        Spacer()
                        Menu("Snooze") {
                            Button("1 hour") { Task { try? await RingClient.shared.snoozeChime(c.id, minutes: 60) } }
                            Button("3 hours") { Task { try? await RingClient.shared.snoozeChime(c.id, minutes: 180) } }
                            Button("Until tomorrow") { Task { try? await RingClient.shared.snoozeChime(c.id, minutes: 1440) } }
                            Divider()
                            Button("Stop snoozing") { Task { try? await RingClient.shared.snoozeChime(c.id, minutes: 0) } }
                        }
                        .fixedSize()
                        Button("Test") { Task { try? await RingClient.shared.playChime(c.id) } }
                    }
                }
            } header: {
                Text("Chimes")
            } footer: {
                Text("Snooze stops a chime ringing for a while (baby asleep, on a call). Test plays the doorbell sound.")
            }
        }

        Section {
            Toggle("Battery saver", isOn: $batterySaver)
        } footer: {
            Text("Battery cameras show their latest picture instead of streaming whenever Doorstep is open, and only go live when you click them. Streaming is what drains a Ring battery.")
        }

        Section {
            Toggle("When Doorstep's mode changes, change Ring's too", isOn: $syncRingMode)
        } footer: {
            Text("Home, Away and Quiet (Disarmed) are copied to Ring's own modes, so Ring Alarm and your Ring app follow along. Night counts as Home. Only works if you use modes in the Ring app.")
        }
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
            CamerasSection()
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


/// Hosts the zone editor in its own window.
struct ZoneWindow: View {
    let deviceId: Int
    @EnvironmentObject var appState: AppState
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        if let d = appState.allDevices.first(where: { $0.id == deviceId }) {
            ZoneEditor(device: d, onDone: { dismissWindow(id: "zone") })
        } else {
            Text("Camera not found").padding(40)
        }
    }
}
