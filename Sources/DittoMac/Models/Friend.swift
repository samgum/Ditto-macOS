import Foundation

/// A remote Ditto peer for LAN sync. Mirrors the Windows `CSendClients` /
/// friend-list concept (name, IP, port, send-all flag).
struct Friend: Codable, Equatable {
    var id: Int64
    var name: String
    var ipAddress: String
    var port: Int
    var sendAll: Bool

    init(id: Int64 = 0, name: String, ipAddress: String, port: Int = 23443, sendAll: Bool = false) {
        self.id = id
        self.name = name
        self.ipAddress = ipAddress
        self.port = port
        self.sendAll = sendAll
    }
}
