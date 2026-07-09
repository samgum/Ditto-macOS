import CSystem
import Foundation

/// CRC32 checksum, matching the Windows Ditto `CRC` column used for dedup
/// (computed over the clip's primary text/format bytes).
enum CRC32 {
    static func checksum(_ data: Data) -> Int64 {
        data.withUnsafeBytes { buffer in
            Int64(crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, UInt32(data.count)))
        }
    }

    /// Stable CRC for a clip's content. Computed over the unicode text bytes,
    /// matching the Windows `CRC` column's purpose (dedup). Non-text clips
    /// fall back to a CRC over their blob bytes when the store has the data.
    static func checksum(for entry: ClipboardEntry, blobReader: (String) -> Data? = { _ in nil }) -> Int64 {
        if let text = entry.text, text.isEmpty == false {
            return checksum(Data(text.utf8))
        }
        for key in [entry.rtfBlobKey, entry.htmlBlobKey, entry.imageBlobKey, entry.pdfBlobKey].compactMap({ $0 }) {
            if let data = blobReader(key), data.isEmpty == false {
                return checksum(data)
            }
        }
        return 0
    }

    /// Multi-format CRC over every captured format's bytes, matching the
    /// Windows `GenerateCRC` over all formats. Two clips match iff their full
    /// content (text + RTF + HTML + image + PDF + file list) is byte-identical —
    /// so two different screenshots no longer dedup against each other.
    static func checksumCapture(
        text: String?,
        rtfData: Data?,
        htmlData: Data?,
        imageData: Data?,
        pdfData: Data? = nil,
        fileURLs: [String]
    ) -> Int64 {
        var combined = Data()
        if let text { combined.append(Data(text.utf8)) }
        combined.append(0xFF)
        if let rtfData { combined.append(rtfData) }
        combined.append(0xFF)
        if let htmlData { combined.append(htmlData) }
        combined.append(0xFF)
        if let imageData { combined.append(imageData) }
        combined.append(0xFF)
        if let pdfData { combined.append(pdfData) }
        combined.append(0xFF)
        for url in fileURLs { combined.append(Data(url.utf8)); combined.append(0) }
        return combined.isEmpty ? 0 : checksum(combined)
    }
}
