import Testing
import Foundation
@preconcurrency import WebRTC
@testable import RingClient
@testable import OpenRingFeature

/// Proves the pretend microphone really feeds WebRTC: two peer connections in this process,
/// a tone goes in one end, and the sender's own statistics must show audio energy and packets.
@Suite struct SpeechAudioTests {
    final class Hook: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
        var other: RTCPeerConnection?
        func peerConnection(_ pc: RTCPeerConnection, didGenerate c: RTCIceCandidate) { other?.add(c) { _ in } }
        func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCSignalingState) {}
        func peerConnection(_ pc: RTCPeerConnection, didAdd s: RTCMediaStream) {}
        func peerConnection(_ pc: RTCPeerConnection, didRemove s: RTCMediaStream) {}
        func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
        func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCIceConnectionState) {}
        func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCIceGatheringState) {}
        func peerConnection(_ pc: RTCPeerConnection, didRemove c: [RTCIceCandidate]) {}
        func peerConnection(_ pc: RTCPeerConnection, didOpen d: RTCDataChannel) {}
    }

    @Test func speechReachesTheWire() async throws {
        let f = SharedWebRTC.speechFactory
        let cfg = RTCConfiguration(); cfg.sdpSemantics = .unifiedPlan
        let none = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let h1 = Hook(), h2 = Hook()
        let a = try #require(f.peerConnection(with: cfg, constraints: none, delegate: h1))
        let b = try #require(f.peerConnection(with: cfg, constraints: none, delegate: h2))
        h1.other = b; h2.other = a
        let track = f.audioTrack(with: f.audioSource(with: none), trackId: "audio0")
        let ti = RTCRtpTransceiverInit(); ti.direction = .sendOnly
        _ = a.addTransceiver(with: track, init: ti)

        let offer = try await a.offer(for: none)
        try await a.setLocalDescription(offer)
        try await b.setRemoteDescription(offer)
        let answer = try await b.answer(for: none)
        try await b.setLocalDescription(answer)
        try await a.setRemoteDescription(answer)

        for _ in 0..<50 where !SpeechAudioDevice.shared.isCapturing { try await Task.sleep(for: .milliseconds(100)) }
        #expect(SpeechAudioDevice.shared.isCapturing)

        // One second of a 440 Hz tone.
        let tone = (0..<48_000).map { Int16(12_000 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        await SpeechAudioDevice.shared.play(tone)
        try await Task.sleep(for: .milliseconds(400))

        let report = await a.statistics()
        var energy = 0.0, packets = 0
        for s in report.statistics.values {
            if s.type == "media-source", let e = s.values["totalAudioEnergy"] as? NSNumber { energy = e.doubleValue }
            if s.type == "outbound-rtp", let p = s.values["packetsSent"] as? NSNumber { packets = p.intValue }
        }
        a.close(); b.close()
        #expect(energy > 0.01, "the tone should register as sound at the sender")
        #expect(packets > 20, "and be sent as audio packets")
    }
}

@Suite struct SpokenReplyTests {
    @Test func aSentenceBecomesSound() async {
        let s = await OpenRingFeature.SpeechSynth.samples("Please leave it by the door. Thank you.")
        let seconds = Double(s.count) / 48_000
        #expect(seconds > 1.2 && seconds < 8, "about a sentence long, got \(seconds)s")
        #expect((s.map { abs(Int($0)) }.max() ?? 0) > 8_000, "and loud enough to hear")
        #expect(s.prefix(4_800).allSatisfy { $0 == 0 }, "with a short pause first")
    }

    @Test func resamplingKeepsTheLength() {
        let s = OpenRingFeature.SpeechSynth.resample([Float](repeating: 0.5, count: 22_050), from: 22_050)
        #expect(abs(s.count - (48_000 + 2 * 16_800)) < 4)
    }
}
