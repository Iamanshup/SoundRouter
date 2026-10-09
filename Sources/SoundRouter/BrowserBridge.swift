import Foundation
import Network

let bridgePort: UInt16 = 47390

struct BrowserTab: Identifiable, Hashable {
    var id: String { "\(connection)/\(tabID)" }
    let connection: Int
    let tabID: Int
    var browser: String
    var title: String
    var url: String
    var audible: Bool
    var favIconURL: String? = nil
}

/// Local WebSocket server the SoundRouter browser extension connects to.
/// Text frames carry JSON control messages; binary frames carry tab audio:
/// [UInt32 tabId][UInt32 channels][Float32 interleaved samples], little-endian.
final class BrowserBridge: @unchecked Sendable {
    /// Called on the main queue.
    var onMessage: ((Int, [String: Any]) -> Void)?
    var onDisconnect: ((Int) -> Void)?

    private let queue = DispatchQueue(label: "SoundRouter.bridge", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [Int: NWConnection] = [:]   // queue-confined
    private var nextID = 1

    private let lock = NSLock()
    private var players: [String: TabPlayer] = [:]       // tab key -> player, guarded by lock

    func start() {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 1 << 20
        // Only browser extensions may connect; ordinary web pages send an http(s) Origin.
        ws.setClientRequestHandler(queue) { _, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value ?? ""
            let allowed = origin.hasPrefix("chrome-extension://")
            return NWProtocolWebSocket.Response(status: allowed ? .accept : .reject, subprotocol: nil)
        }
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: bridgePort)!)
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { NSLog("SoundRouter: bridge listener failed: \(error)") }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("SoundRouter: could not start browser bridge: \(error)")
        }
    }

    func setPlayer(_ player: TabPlayer?, for key: String) {
        lock.lock(); players[key] = player; lock.unlock()
    }

    func send(_ connection: Int, _ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        queue.async {
            guard let conn = self.connections[connection] else { return }
            let meta = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "json", metadata: [meta])
            conn.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }

    private func accept(_ conn: NWConnection) {
        let id = nextID
        nextID += 1
        connections[id] = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.drop(id)
            default: break
            }
        }
        conn.start(queue: queue)
        receive(id, conn)
    }

    private func drop(_ id: Int) {
        guard let conn = connections.removeValue(forKey: id) else { return }
        conn.cancel()
        DispatchQueue.main.async { self.onDisconnect?(id) }
    }

    private func receive(_ id: Int, _ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if let data, let meta {
                switch meta.opcode {
                case .binary: self.handleAudio(id, data)
                case .text:
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        DispatchQueue.main.async { self.onMessage?(id, json) }
                    }
                default: break
                }
            }
            if error != nil || meta?.opcode == .close { self.drop(id); return }
            self.receive(id, conn)
        }
    }

    private func handleAudio(_ id: Int, _ data: Data) {
        guard data.count > 8 else { return }
        let tabID = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self))) }
        let channels = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))) }
        guard channels == 1 || channels == 2 else { return }
        lock.lock(); let player = players["\(id)/\(tabID)"]; lock.unlock()
        guard let player else { return }
        let count = (data.count - 8) / MemoryLayout<Float>.size
        var samples = [Float](repeating: 0, count: count)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0, from: 8..<(8 + count * 4)) }
        samples.withUnsafeBufferPointer { player.ring.write($0, channels: channels) }
    }
}
