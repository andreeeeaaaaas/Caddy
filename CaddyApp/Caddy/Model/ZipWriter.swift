import Foundation

/// A ZIP archive with every entry stored, not compressed: enough for a `.docx`,
/// whose frames are JPEGs already.
nonisolated struct ZipWriter {
    private var data = Data()
    private var directory = Data()
    private var count = 0

    mutating func add(_ path: String, _ text: String) {
        add(path, Data(text.utf8))
    }

    mutating func add(_ path: String, _ content: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(content)
        let offset = UInt32(data.count)
        // DOS time and date: midnight, 1 January 1980.
        let time: UInt16 = 0, date: UInt16 = 0x21

        data.append(le32: 0x0403_4b50)
        data.append(le16: 20)
        data.append(le16: 0x0800) // Names are UTF-8.
        data.append(le16: 0)      // Stored.
        data.append(le16: time)
        data.append(le16: date)
        data.append(le32: crc)
        data.append(le32: UInt32(content.count))
        data.append(le32: UInt32(content.count))
        data.append(le16: UInt16(name.count))
        data.append(le16: 0)
        data.append(name)
        data.append(content)

        directory.append(le32: 0x0201_4b50)
        directory.append(le16: 20)
        directory.append(le16: 20)
        directory.append(le16: 0x0800)
        directory.append(le16: 0)
        directory.append(le16: time)
        directory.append(le16: date)
        directory.append(le32: crc)
        directory.append(le32: UInt32(content.count))
        directory.append(le32: UInt32(content.count))
        directory.append(le16: UInt16(name.count))
        directory.append(le16: 0) // Extra field.
        directory.append(le16: 0) // Comment.
        directory.append(le16: 0) // Disk.
        directory.append(le16: 0) // Internal attributes.
        directory.append(le32: 0) // External attributes.
        directory.append(le32: offset)
        directory.append(name)
        count += 1
    }

    func finish() -> Data {
        var archive = data
        archive.append(directory)
        archive.append(le32: 0x0605_4b50)
        archive.append(le16: 0)
        archive.append(le16: 0)
        archive.append(le16: UInt16(count))
        archive.append(le16: UInt16(count))
        archive.append(le32: UInt32(directory.count))
        archive.append(le32: UInt32(data.count))
        archive.append(le16: 0)
        return archive
    }
}

private nonisolated enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    nonisolated mutating func append(le16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    nonisolated mutating func append(le32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
