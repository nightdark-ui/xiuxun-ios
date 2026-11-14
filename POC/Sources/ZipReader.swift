import Foundation
import Compression

/// 极简 ZIP 读取器（只支持 store 模式；numpy 的 savez 默认就是 store）。
struct ZipReader {
    struct Item {
        let name: String
        let offset: Int
        let size: Int
        let method: Int
        let uncompressedSize: Int
    }

    private let data: Data
    private(set) var items: [Item] = []

    init?(_ data: Data) {
        self.data = data
        guard let eocd = Self.findEOCD(data) else { return nil }
        let centralOffset = Int(Self.uint32(data, eocd + 16))
        let count = Int(Self.uint16(data, eocd + 10))
        var cursor = centralOffset

        for _ in 0..<count {
            guard cursor + 46 <= data.count,
                  Self.uint32(data, cursor) == 0x02014b50 else { break }
            let nameLength = Int(Self.uint16(data, cursor + 28))
            let extraLength = Int(Self.uint16(data, cursor + 30))
            let commentLength = Int(Self.uint16(data, cursor + 32))
            let localOffset = Int(Self.uint32(data, cursor + 42))
            let compressedSize = Int(Self.uint32(data, cursor + 20))
            let uncompressedSize = Int(Self.uint32(data, cursor + 24))
            let method = Int(Self.uint16(data, cursor + 10))

            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else { break }
            let name = String(
                data: data.subdata(in: nameStart..<(nameStart + nameLength)),
                encoding: .utf8
            ) ?? ""

            // 读取 local header 得到真实数据偏移
            if localOffset + 30 <= data.count {
                let localNameLength = Int(Self.uint16(data, localOffset + 26))
                let localExtraLength = Int(Self.uint16(data, localOffset + 28))
                let dataStart = localOffset + 30 + localNameLength + localExtraLength
                if dataStart + compressedSize <= data.count {
                    items.append(Item(
                        name: name,
                        offset: dataStart,
                        size: compressedSize,
                        method: method,
                        uncompressedSize: uncompressedSize
                    ))
                }
            }
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        if items.isEmpty { return nil }
    }

    func payload(_ item: Item) -> Data {
        let raw = data.subdata(in: item.offset..<(item.offset + item.size))
        if item.method == 0 {
            return raw
        }
        guard item.method == 8 else { return raw }
        return Self.inflate(raw, size: item.uncompressedSize) ?? raw
    }

    /// 原始 deflate 解压（ZIP 的 method 8）
    private static func inflate(_ raw: Data, size: Int) -> Data? {
        guard size > 0 else { return Data() }
        var output = [UInt8](repeating: 0, count: size)
        let written = output.withUnsafeMutableBufferPointer { out -> Int in
            raw.withUnsafeBytes { input -> Int in
                guard let base = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(out.baseAddress!, size, base, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return Data(output.prefix(written))
    }

    func payload(named name: String) -> Data? {
        guard let item = items.first(where: { $0.name == name }) else { return nil }
        return payload(item)
    }

    private static func findEOCD(_ data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let limit = max(0, data.count - 65557)
        var index = data.count - 22
        while index >= limit {
            if uint32(data, index) == 0x06054b50 { return index }
            index -= 1
        }
        return nil
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

/// 解析 .npy（仅 float32 / C 顺序）
struct NpyArray {
    let shape: [Int]
    let values: [Float]

    static func parse(_ data: Data) -> NpyArray? {
        guard data.count > 10,
              data[0] == 0x93,
              String(data: data.subdata(in: 1..<6), encoding: .ascii) == "NUMPY" else {
            return nil
        }
        let major = data[6]
        var headerLength = 0
        var headerStart = 0
        if major == 1 {
            headerLength = Int(data[8]) | (Int(data[9]) << 8)
            headerStart = 10
        } else {
            guard data.count > 12 else { return nil }
            headerLength = Int(data[8]) | (Int(data[9]) << 8)
            headerLength |= (Int(data[10]) << 16) | (Int(data[11]) << 24)
            headerStart = 12
        }
        guard headerStart + headerLength <= data.count else { return nil }
        let headerData = data.subdata(in: headerStart..<(headerStart + headerLength))
        let header = String(data: headerData, encoding: .ascii) ?? ""

        guard header.contains("<f4") || header.contains("|f4") else { return nil }
        guard let shapeStart = header.range(of: "shape': (")?.upperBound,
              let shapeEnd = header.range(of: ")", range: shapeStart..<header.endIndex)?.lowerBound else {
            return nil
        }
        let shapeText = header[shapeStart..<shapeEnd]
        var shape: [Int] = []
        for part in shapeText.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if let value = Int(trimmed) { shape.append(value) }
        }
        guard !shape.isEmpty else { return nil }

        let bodyStart = headerStart + headerLength
        let count = shape.reduce(1, *)
        let byteCount = count * 4
        guard bodyStart + byteCount <= data.count else { return nil }

        var values = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let floats = base.advanced(by: bodyStart).assumingMemoryBound(to: Float.self)
            for i in 0..<count { values[i] = floats[i] }
        }
        return NpyArray(shape: shape, values: values)
    }
}
