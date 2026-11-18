import Foundation
import Network
import os

/// One TLS connection to mtalk.google.com:5228 (push-receiver client.ts uses a
/// node TLSSocket with 30 s keepalive). Bytes in are framed by MCSFrameParser
/// and handed out as events; one connection is used once, then thrown away.
final class MCSConnection: @unchecked Sendable {
    enum Event: Sendable {
        case ready
        case frame(MCSFrame)
        case closed(reason: String)
    }

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.open-ring.push.mcs")
    private static let log = Logger(subsystem: "dev.open-ring", category: "RingPush")

    // Only touched on `queue`.
    private var parser = MCSFrameParser()
    private var finished = false

    init(host: String = MCSConstants.host, port: UInt16 = MCSConstants.port) {
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30      // setKeepAlive(true, 30_000) in push-receiver
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 20
        tcp.noDelay = true
        let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.continuation.yield(.ready)
                self.receiveNext()
            case .waiting(let error):
                // No route right now. Let the owner back off and retry rather than
                // sitting in NWConnection's own wait.
                self.finish("waiting: \(error.localizedDescription)")
            case .failed(let error):
                self.finish("failed: \(error.localizedDescription)")
            case .cancelled:
                self.finish("cancelled")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    func cancel() {
        connection.cancel()
        queue.async { self.finish("cancelled by client") }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try self.parser.feed(data) { self.continuation.yield(.frame(frame)) }
                } catch {
                    Self.log.error("MCS framing error: \(String(describing: error), privacy: .public)")
                    self.connection.cancel()
                    self.finish("framing error")
                    return
                }
            }
            if let error {
                self.connection.cancel()
                self.finish("receive error: \(error.localizedDescription)")
            } else if isComplete {
                self.connection.cancel()
                self.finish("server closed the connection")
            } else {
                self.receiveNext()
            }
        }
    }

    /// Call on `queue` only.
    private func finish(_ reason: String) {
        guard !finished else { return }
        finished = true
        continuation.yield(.closed(reason: reason))
        continuation.finish()
    }
}
