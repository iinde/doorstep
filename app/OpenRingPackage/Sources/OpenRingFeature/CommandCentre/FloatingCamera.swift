import SwiftUI
import AppKit
import RingClient
@preconcurrency import WebRTC

/// One camera in a small floating window that stays on top while you work.
@MainActor
public final class FloatingCamera {
    public static let shared = FloatingCamera()
    private var panels: [Int: NSPanel] = [:]

    public func show(_ device: RingDevice) {
        if let p = panels[device.id] { p.orderFrontRegardless(); return }
        let size = NSSize(width: 384, height: 216)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.contentView = NSHostingView(rootView: FloatingCameraView(device: device).environment(\.colorScheme, .dark))
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 20, y: screen.minY + 20 + CGFloat(panels.count) * 230))
        }
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panels[device.id] = nil }
        }
        panels[device.id] = panel
    }
}

struct FloatingCameraView: View {
    let device: RingDevice
    @ObservedObject private var streams = MultiStreamManager.shared

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            DS.night
            if DemoMode.isOn {
                DemoLivePicture(deviceId: device.id)
            } else if let track = streams.getVideoTrack(for: device.id) {
                WebRTCVideoView(videoTrack: track, isPortrait: false, captureHandler: nil, fill: true, label: "\(device.name) (float)")
                    .id(ObjectIdentifier(track))
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(device.name).font(DS.meta).foregroundStyle(DS.paper)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(8)
        }
        .task { await streams.addViewer(devices: [device]) }
        .onDisappear { Task { await MultiStreamManager.shared.removeViewer() } }
    }
}
