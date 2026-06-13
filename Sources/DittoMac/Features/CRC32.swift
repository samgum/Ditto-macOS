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
        for key in [entry.rtfBlobKey, entry.htmlBlobKey, entry.imageBlobKey].compactMap({ $0 }) {
            if let data = blobReader(key), data.isEmpty == false {
                return checksum(data)
            }
        }
        return 0
    }
}
