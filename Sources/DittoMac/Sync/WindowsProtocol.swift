import Foundation

/// Binary codec for the Windows Ditto network protocol (`ServerDefines.h`),
/// so this app can speak the same wire format as a Windows peer.
///
/// `CSendInfo` is the fixed header that precedes every message. Field offsets
/// follow the Windows struct with default (8-byte) packing; the one insertion
/// point worth noting is the 2-byte pad before `m_lParameter1` (the preceding
/// `m_cDesc[250]` leaves the cursor at offset 314, and the 4-byte `long`
/// rounds up to 316). `m_nSize` is sent first and equals the header length, so
/// a receiver can confirm the layout matches.
enum WindowsProtocol {
    static let port = 23443

    enum MessageType: Int32 {
        case start = 0, data = 1, dataStart = 2, dataEnd = 3, end = 4, exit = 5, requestFiles = 6
    }

    /// The on-wire header. 375 bytes with the field layout + the two inline
    /// pads (2 before m_lParameter1, 1 before m_respondPort). m_nSize is
    /// written to match the actual emitted byte count so the codec is
    /// self-consistent.
    static let sendInfoSize = 375

    struct SendInfo {
        var type: MessageType
        var version: Int32 = 1
        var ip: String = ""
        var computerName: String = ""
        var description: String = ""
        var parameter1: Int32 = -1
        var parameter2: Int32 = -1
        var md5: String = ""       // 32 hex chars
        var manualSend: Bool = false
        var respondPort: Int16 = 0

        func encoded() -> Data {
            var data = Data()
            data.append(int32LE: Int32(WindowsProtocol.sendInfoSize))   // m_nSize
            data.append(int32LE: type.rawValue)                          // m_Type
            data.append(int32LE: version)                                // m_nVersion
            data.append(fixedString: ip, length: 20)                     // m_cIP[20]
            data.append(fixedString: computerName, length: 32)           // m_cComputerName[32]
            data.append(fixedString: description, length: 250)           // m_cDesc[250]
            data.append(zeros: 2)                                        // padding to 4-byte align
            data.append(int32LE: parameter1)                             // m_lParameter1
            data.append(int32LE: parameter2)                             // m_lParameter2
            data.append(fixedString: md5, length: 32)                    // m_md5[32]
            data.append(manualSend ? UInt8(1) : UInt8(0))                // m_manualSend
            data.append(zeros: 1)                                        // padding to 2-byte align
            data.append(int16LE: respondPort)                            // m_respondPort
            data.append(zeros: 15)                                       // m_cExtra[15]
            return data
        }
    }

    /// Build the full Windows wire stream for one encrypted clip payload:
    ///   START(desc) → DATA_START(format) → DATA(chunked) → DATA_END → END
    static func frameEncryptedClip(encryptedPayload: Data, description: String, md5: String, computerName: String, ip: String, manualSend: Bool) -> Data {
        var stream = Data()

        let start = SendInfo(type: .start, ip: ip, computerName: computerName, description: description, md5: md5, manualSend: manualSend)
        stream.append(start.encoded())

        let dataStart = SendInfo(type: .dataStart, description: "CF_DITTO_MAC", parameter1: Int32(encryptedPayload.count))
        stream.append(dataStart.encoded())

        // DATA messages each carry a chunk of the encrypted payload in their
        // m_cDesc field (Windows sends raw bytes after the header). We chunk in
        // 64KB blocks matching CHUNK_WRITE_SIZE.
        let chunkSize = 65_536
        var offset = 0
        while offset < encryptedPayload.count {
            let end = min(offset + chunkSize, encryptedPayload.count)
            let chunk = encryptedPayload.subdata(in: offset..<end)
            let dataMsg = SendInfo(type: .data, parameter1: Int32(chunk.count))
            stream.append(dataMsg.encoded())
            stream.append(chunk)
            offset = end
        }

        stream.append(SendInfo(type: .dataEnd).encoded())
        stream.append(SendInfo(type: .end).encoded())
        return stream
    }
}

private extension Data {
    mutating func append(int32LE value: Int32) {
        var v = UInt32(bitPattern: value).littleEndian
        append(Data(bytes: &v, count: 4))
    }

    mutating func append(int16LE value: Int16) {
        var v = UInt16(bitPattern: value).littleEndian
        append(Data(bytes: &v, count: 2))
    }

    mutating func append(fixedString value: String, length: Int) {
        let bytes = Array(value.utf8.prefix(length))
        append(contentsOf: bytes)
        if bytes.count < length {
            append(Data(repeating: 0, count: length - bytes.count))
        }
    }

    mutating func append(zeros count: Int) {
        append(Data(repeating: 0, count: count))
    }
}
