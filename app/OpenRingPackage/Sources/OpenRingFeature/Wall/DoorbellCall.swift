import SwiftUI
import AppKit
import RingClient
@preconcurrency import WebRTC

/// Someone rang: a FaceTime-style panel, top right, with the doorbell live.
/// Floats above other windows without stealing focus from what you're doing.
@MainActor
public final class DoorbellCallController {
    public static let shared = DoorbellCallController()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    public var isShowing: Bool { panel != nil }

    /// `title` overrides "Someone's at …" (e.g. "Possible delivery at Front Door").
    public func show(device: RingDevice, event: RingEvent?, title: String? = nil) {
        close()
        let view = DoorbellCallView(device: device, event: event, title: title,
                                    onDismiss: { [weak self] in self?.close() })
        let host = NSHostingView(rootView: view)
        let size = NSSize(width: 360, height: 358)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 12))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        // Nobody answered: go away quietly after two minutes.
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    public func close() {
        dismissTask?.cancel()
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.contentView = nil
        })
    }
}

struct DoorbellCallView: View {
    let device: RingDevice
    let event: RingEvent?
    var title: String?
    let onDismiss: () -> Void

    @ObservedObject private var streams = MultiStreamManager.shared
    @State private var hasPicture = false
    @State private var isTalking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title ?? "Someone's at \(device.name)")
                        .font(DS.title)
                        .foregroundStyle(DS.paper)
                    Text(event?.createdAt ?? Date(), format: .dateTime.hour().minute())
                        .font(DS.monoMeta)
                        .foregroundStyle(DS.porchlight)
                }
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DS.ash)
                        .frame(width: 24, height: 24)
                        .background(DS.well, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .keyboardShortcut(.cancelAction)
            }

            ZStack {
                DS.slate
                if DemoMode.isOn {
                    DemoLivePicture(deviceId: device.id).onAppear { hasPicture = true }
                } else if let track = streams.getVideoTrack(for: device.id) {
                    WebRTCVideoView(videoTrack: track, isPortrait: false, captureHandler: nil, fill: true,
                                    label: "\(device.name) (call)",
                                    onFirstFrame: { withAnimation(DS.crossfade) { hasPicture = true } })
                        .opacity(hasPicture ? 1 : 0)
                        .id(ObjectIdentifier(track))
                }
                if !hasPicture {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Connecting to \(device.name)").font(DS.meta).foregroundStyle(DS.ash)
                    }
                }
            }
            .frame(height: 184)
            .clipShape(RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous))

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: isTalking ? "mic.fill" : "mic")
                    Text(streams.connectingMic.contains(device.id) ? "Connecting mic…"
                         : isTalking ? "Talking" : "Hold to talk").font(DS.bodyStrong)
                }
                .foregroundStyle(isTalking ? DS.night : DS.paper)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(isTalking ? DS.porchlight : DS.well, in: Capsule())
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isTalking else { return }
                            isTalking = true
                            let id = device.id
                            Task { await streams.startTalking(for: id) }
                        }
                        .onEnded { _ in
                            isTalking = false
                            let id = device.id
                            Task { await streams.stopTalking(for: id) }
                        }
                )
                .animation(DS.settle, value: isTalking)
                .accessibilityLabel("Hold to talk")
                .accessibilityAddTraits(.isButton)
                Spacer()
            }
            SayItRow(device: device)
        }
        .padding(16)
        .frame(width: 360, height: 358)
        .background(Backdrop())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .task {
            let list = [device]
            await streams.addViewer(devices: list)
            streams.setActiveDevice(device.id)
        }
        .onDisappear {
            let id = device.id
            Task {
                await MultiStreamManager.shared.endTalkMode(for: id)
                await MultiStreamManager.shared.removeViewer()
            }
        }
    }
}
