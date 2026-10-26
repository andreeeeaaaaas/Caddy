import Compression
import Foundation

/// Reads a ZIP archive's files, stored or deflated, in the order its directory
/// lists them: enough to open a `.docx` that Word saved.
nonisolated enum ZipReader {
    struct Entry {
        var path: String
        var data: Data
    }

    enum Failure: Error {
        case damaged
        case unsupported(String)
    }

    static func entries(of archive: Data) throws -> [Entry] {
        let bytes = [UInt8](archive)
        func le16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func le32(_ offset: Int) -> Int { le16(offset) | le16(offset + 2) << 16 }

        // The end of the central directory, searched for back past any comment.
        guard bytes.count >= 22,
              let end = stride(from: bytes.count - 22, through: max(0, bytes.count - 22 - 0xFFFF), by: -1)
                .first(where: { le32($0) == 0x0605_4b50 }) else { throw Failure.damaged }
        var offset = le32(end + 16)
        var entries: [Entry] = []
        for _ in 0..<le16(end + 10) {
            guard offset + 46 <= bytes.count, le32(offset) == 0x0201_4b50 else { throw Failure.damaged }
            let method = le16(offset + 10)
            let compressedSize = le32(offset + 20)
            let size = le32(offset + 24)
            let nameLength = le16(offset + 28)
            let local = le32(offset + 42)
            guard offset + 46 + nameLength <= bytes.count else { throw Failure.damaged }
            let path = String(decoding: bytes[offset + 46 ..< offset + 46 + nameLength], as: UTF8.self)
            offset += 46 + nameLength + le16(offset + 30) + le16(offset + 32)

            guard local + 30 <= bytes.count, le32(local) == 0x0403_4b50 else { throw Failure.damaged }
            let start = local + 30 + le16(local + 26) + le16(local + 28)
            guard start + compressedSize <= bytes.count else { throw Failure.damaged }
            guard !path.hasSuffix("/") else { continue }
            let content = Data(bytes[start ..< start + compressedSize])
            switch method {
            case 0: entries.append(Entry(path: path, data: content))
            case 8: entries.append(Entry(path: path, data: try inflate(content, size: size)))
            default: throw Failure.unsupported(path)
            }
        }
        return entries
    }

    /// Raw deflate, which the Compression framework calls zlib.
    private static func inflate(_ data: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        guard !data.isEmpty else { throw Failure.damaged }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, size,
                                          input.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Failure.damaged }
        return output
    }
}
