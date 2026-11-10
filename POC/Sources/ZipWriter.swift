import Foundation

/// 极简 ZIP 写入器（仅 store，不压缩）。
/// 用途：生成安卓 `xiuxun-learning` 包里的 `.npz`（npz 就是 zip 里的 .npy）。
struct ZipWriter {
    private struct Entry {
        let name: String
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private var data = Data()
    private var entries: [Entry] = []

    mutating func add(name: String, payload: Data) {
        let nameData = Data(name.utf8)
        let crc = CRC32.checksum(payload)
        let offset = UInt32(data.count)

        // local file header
        data.appendUInt32(0x04034b50)
        data.appendUInt16(20)            // version needed
        data.appendUInt16(0)             // flags
        data.appendUInt16(0)             // method = store
        data.appendUInt16(0)             // time
        data.appendUInt16(0)             // date
        data.appendUInt32(crc)
        data.appendUInt32(UInt32(payload.count))
        data.appendUInt32(UInt32(payload.count))
        data.appendUInt16(UInt16(nameData.count))
        data.appendUInt16(0)             // extra length
        data.append(nameData)
        data.append(payload)

        entries.append(Entry(
            name: name,
            crc: crc,
            size: UInt32(payload.count),
            offset: offset
        ))
    }

    func finish() -> Data {
        var output = data
        let centralStart = UInt32(data.count)

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            output.appendUInt32(0x02014b50)
            output.appendUInt16(20)      // version made by
            output.appendUInt16(20)      // version needed
            output.appendUInt16(0)       // flags
            output.appendUInt16(0)       // method
            output.appendUInt16(0)       // time
            output.appendUInt16(0)       // date
            output.appendUInt32(entry.crc)
            output.appendUInt32(entry.size)
            output.appendUInt32(entry.size)
            output.appendUInt16(UInt16(nameData.count))
            output.appendUInt16(0)       // extra
            output.appendUInt16(0)       // comment
            output.appendUInt16(0)       // disk
            output.appendUInt16(0)       // internal attrs
            output.appendUInt32(0)       // external attrs
            output.appendUInt32(entry.offset)
            output.append(nameData)
        }

        let centralSize = UInt32(output.count) - centralStart
        output.appendUInt32(0x06054b50)
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(UInt16(entries.count))
        output.appendUInt16(UInt16(entries.count))
        output.appendUInt32(centralSize)
        output.appendUInt32(centralStart)
        output.appendUInt16(0)
        return output
    }
}

/// .npy 写入（float32，C 顺序）
enum NpyWriter {
    static func float32(_ values: [Float], shape: [Int]) -> Data {
        var header = "{'descr': '<f4', 'fortran_order': False, 'shape': ("
        header += shape.map(String.init).joined(separator: ", ")
        if shape.count == 1 { header += "," }
        header += "), }"
        // 头部必须 64 字节对齐（magic 6 + version 2 + len 2 + header + padding + '\n'）
        var headerBytes = Data(header.utf8)
        let total = 10 + headerBytes.count + 1
        let padding = (64 - (total % 64)) % 64
        headerBytes.append(contentsOf: [UInt8](repeating: 0x20, count: padding))
        headerBytes.append(0x0A)

        var output = Data()
        output.append(contentsOf: [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]) // \x93NUMPY
        output.append(contentsOf: [0x01, 0x00])                          // version 1.0
        output.appendUInt16(UInt16(headerBytes.count))
        output.append(headerBytes)

        var littleEndian = values.map { $0.bitPattern.littleEndian }
        littleEndian.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                output.append(UnsafeBufferPointer(
                    start: UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self),
                    count: buffer.count * 4
                ).baseAddress.map { Data(bytes: $0, count: buffer.count * 4) } ?? Data())
            }
        }
        return output
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: 2))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: 4))
    }
}
