import CryptoKit
import Darwin
import Foundation
import Network

/// Coordinates LAN clipboard sync: runs a TCP server on `SendRecvPort`,
/// broadcasts new clips to "send all" friends, and accepts incoming clips.
///
/// Wire format (length-prefixed):
///   [UInt32 BE header length][header JSON][UInt32 BE payload length][payload]
/// Header:  { type, sender, computerName, description, md5, manualSend }
/// Payload: AES-256-GCM encrypted `ClipPayload` JSON.
final class SyncCoordinator {
    var store: ClipboardStore?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "org.ditto-cp.DittoMac.sync")
    private var incomingConnections: [NWConnection] = []

    func start() {
        guard DittoSettings.disableReceive == false else {
            startBroadcastOnly()
            return
        }
        startListener()
        startBroadcastOnly()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        incomingConnections.forEach { $0.cancel() }
        incomingConnections.removeAll()
    }

    // MARK: - Server

    private func startListener() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let port = NWEndpoint.Port(rawValue: UInt16(clamping: DittoSettings.sendRecvPort)) ?? NWEndpoint.Port(rawValue: 23443)!
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.stateUpdateHandler = { state in
                if case .failed = state {
                    // Listener died; a future start() will re-create it.
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("Sync listener failed: \(error)")
        }
    }

    private func startBroadcastOnly() {
        // No-op placeholder; broadcasting happens per-clip via send(entry:).
    }

    private func handle(connection: NWConnection) {
        incomingConnections.append(connection)
        // Remove (and cancel) the connection when it ends, so we don't leak
        // sockets over the lifetime of the server.
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.incomingConnections.removeAll { $0 === connection }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveMessage(on: connection)
    }

    private func receiveMessage(on connection: NWConnection) {
        receiveLengthPrefixed(connection: connection) { [weak self] headerData, payloadData in
            guard let self,
                  let headerData,
                  let payloadData,
                  let header = try? JSONDecoder().decode(SyncHeader.self, from: headerData) else {
                connection.cancel()
                return
            }
            self.processIncoming(header: header, payload: payloadData)
            self.receiveMessage(on: connection)
        }
    }

    private func processIncoming(header: SyncHeader, payload: Data) {
        let password = DittoSettings.networkPassword
        guard let decrypted = try? AESEncryption.decrypt(payload, password: password) else {
            NSLog("Sync: failed to decrypt incoming payload")
            return
        }
        guard let payload = try? JSONDecoder().decode(ClipPayload.self, from: decrypted) else {
            NSLog("Sync: failed to decode incoming clip")
            return
        }

        let rtfBlobKey = payload.rtfData.flatMap { Data(base64Encoded: $0) }.flatMap { self.store?.saveBlob($0, fileExtension: "rtf") }
        let htmlBlobKey = payload.htmlData.flatMap { Data(base64Encoded: $0) }.flatMap { self.store?.saveBlob($0, fileExtension: "html") }
        let imageBlobKey = payload.imageData.flatMap { Data(base64Encoded: $0) }.flatMap { self.store?.saveBlob($0, fileExtension: "png") }

        self.store?.addClipboardPayload(
            text: payload.text,
            rtfData: payload.rtfData.flatMap { Data(base64Encoded: $0) },
            htmlData: payload.htmlData.flatMap { Data(base64Encoded: $0) },
            imageData: payload.imageData.flatMap { Data(base64Encoded: $0) },
            fileURLs: [],
            sourceApp: header.sender
        )
        _ = rtfBlobKey; _ = htmlBlobKey; _ = imageBlobKey

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .dittoClipReceived,
                object: nil,
                userInfo: ["sender": header.computerName]
            )
        }
    }

    // MARK: - Client / send

    func send(entry: ClipboardEntry) {
        let payload = ClipPayload(from: entry, store: store)
        sendToFriends(payload: payload, onlyManual: true)
    }

    /// Broadcast the just-captured clip to all "send all" friends.
    func broadcast(entry: ClipboardEntry) {
        guard DittoSettings.allowFriends else { return }
        let friends = store?.loadFriends().filter(\.sendAll) ?? []
        guard friends.isEmpty == false else { return }
        let payload = ClipPayload(from: entry, store: store)
        let header = SyncHeader(
            type: "clip",
            sender: localIPAddress() ?? "macOS",
            computerName: Host.current().localizedName ?? "Mac",
            description: entry.preview,
            md5: payload.md5(),
            manualSend: false
        )
        guard let message = encode(header: header, payload: payload) else { return }
        for friend in friends {
            send(to: friend, message: message)
        }
    }

    private func sendToFriends(payload: ClipPayload, onlyManual: Bool) {
        let friends = store?.loadFriends() ?? []
        let header = SyncHeader(
            type: "clip",
            sender: localIPAddress() ?? "macOS",
            computerName: Host.current().localizedName ?? "Mac",
            description: payload.text ?? "Clip",
            md5: payload.md5(),
            manualSend: onlyManual
        )
        guard let message = encode(header: header, payload: payload) else { return }
        for friend in friends {
            send(to: friend, message: message)
        }
    }

    private func send(to friend: Friend, message: Data) {
        let port = NWEndpoint.Port(rawValue: UInt16(clamping: friend.port)) ?? NWEndpoint.Port(rawValue: 23443)!
        let connection = NWConnection(host: NWEndpoint.Host(friend.ipAddress), port: port, using: .tcp)
        connection.start(queue: queue)
        connection.send(content: message, completion: .contentProcessed { error in
            if let error {
                NSLog("Sync send to \(friend.ipAddress) failed: \(error)")
            }
            connection.cancel()
        })
    }

    // MARK: - Encoding

    private func encode(header: SyncHeader, payload: ClipPayload) -> Data? {
        guard let payloadData = try? JSONEncoder().encode(payload) else { return nil }
        let password = DittoSettings.networkPassword
        guard let encrypted = try? AESEncryption.encrypt(payloadData, password: password) else { return nil }
        guard let headerData = try? JSONEncoder().encode(header) else { return nil }

        var message = Data()
        message.append(contentsOf: UInt32(headerData.count).bigEndianBytes)
        message.append(headerData)
        message.append(contentsOf: UInt32(encrypted.count).bigEndianBytes)
        message.append(encrypted)
        return message
    }

    private func receiveLengthPrefixed(connection: NWConnection, completion: @escaping (Data?, Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { headerLengthData, _, _, _ in
            guard let headerLengthData, headerLengthData.count == 4 else {
                completion(nil, nil)
                return
            }
            let headerLength = headerLengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            connection.receive(minimumIncompleteLength: Int(headerLength), maximumLength: Int(headerLength)) { headerData, _, _, _ in
                guard let headerData, headerData.count == Int(headerLength) else {
                    completion(nil, nil)
                    return
                }
                connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { payloadLengthData, _, _, _ in
                    guard let payloadLengthData, payloadLengthData.count == 4 else {
                        completion(headerData, nil)
                        return
                    }
                    let payloadLength = payloadLengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                    connection.receive(minimumIncompleteLength: Int(payloadLength), maximumLength: Int(payloadLength)) { payloadData, _, _, _ in
                        completion(headerData, payloadData)
                    }
                }
            }
        }
    }

    private func localIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(firstAddr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while cursor != nil {
            guard let current = cursor else { break }
            let interface = current.pointee
            cursor = interface.ifa_next
            let addrFamily = interface.ifa_addr?.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    interface.ifa_addr,
                    socklen_t(interface.ifa_addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    Int32(NI_NUMERICHOST)
                )
                if result == 0 {
                    let address = String(cString: hostname)
                    if address != "127.0.0.1" { return address }
                }
            }
        }
        return nil
    }
}

// MARK: - Wire types

struct SyncHeader: Codable {
    let type: String
    let sender: String
    let computerName: String
    let description: String
    let md5: String
    let manualSend: Bool
}

struct ClipPayload: Codable {
    var text: String?
    var rtfData: String?      // base64
    var htmlData: String?     // base64
    var imageData: String?    // base64
    var fileURLs: [String]?

    init(from entry: ClipboardEntry, store: ClipboardStore?) {
        text = entry.text
        if let key = entry.rtfBlobKey, let data = store?.blobData(named: key) {
            rtfData = data.base64EncodedString()
        }
        if let key = entry.htmlBlobKey, let data = store?.blobData(named: key) {
            htmlData = data.base64EncodedString()
        }
        if let key = entry.imageBlobKey, let data = store?.blobData(named: key) {
            imageData = data.base64EncodedString()
        }
        fileURLs = entry.fileURLs
    }

    func md5() -> String {
        let raw = (text ?? "") + (rtfData ?? "") + (htmlData ?? "") + (imageData ?? "")
        let digest = Insecure.MD5.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] {
        let value = bigEndian
        return [UInt8(truncatingIfNeeded: value & 0xff),
                UInt8(truncatingIfNeeded: (value >> 8) & 0xff),
                UInt8(truncatingIfNeeded: (value >> 16) & 0xff),
                UInt8(truncatingIfNeeded: (value >> 24) & 0xff)]
    }
}
