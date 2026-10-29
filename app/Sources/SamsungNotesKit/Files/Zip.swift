import Compression
import Foundation
import zlib

/// A zip archive read and written whole, in memory: the container of Samsung's `.sdocx`
/// documents, which a sticky note keeps its own text in. Only what such small archives need:
/// stored and deflated entries, no encryption, no archives over 4 GB.
public enum Zip {
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var data: Data
        public init(name: String, data: Data) { self.name = name; self.data = data }
    }

    public enum Failure: Error { case notAnArchive, damaged, unsupported }

    private static func u16(_ data: Data, _ at: Int) -> Int { Int(data[data.startIndex + at]) | Int(data[data.startIndex + at + 1]) << 8 }
    private static func u32(_ data: Data, _ at: Int) -> Int { u16(data, at) | u16(data, at + 2) << 16 }

    /// The entries of an archive, in the order of its directory. Folders are left out.
    public static func read(_ archive: Data, limit: Int = 64 * 1024 * 1024) throws -> [Entry] {
        let data = Data(archive)
        // The directory's end record stands in the last 64 KB or so, before a comment.
        guard data.count >= 22 else { throw Failure.notAnArchive }
        var end = -1
        var at = data.count - 22
        while at >= max(data.count - 22 - 65_535, 0) {
            if u32(data, at) == 0x0605_4b50 { end = at; break }
            at -= 1
        }
        guard end >= 0 else { throw Failure.notAnArchive }
        let count = u16(data, end + 10), size = u32(data, end + 12), start = u32(data, end + 16)
        guard start >= 0, size >= 0, start + size <= data.count, count < 100_000 else { throw Failure.damaged }
        var entries: [Entry] = []
        var total = 0
        var place = start
        for _ in 0..<count {
            guard place + 46 <= data.count, u32(data, place) == 0x0201_4b50 else { throw Failure.damaged }
            let flags = u16(data, place + 8), method = u16(data, place + 10)
            let packed = u32(data, place + 20), plain = u32(data, place + 24)
            let nameLength = u16(data, place + 28), extra = u16(data, place + 30), comment = u16(data, place + 32), local = u32(data, place + 42)
            guard place + 46 + nameLength <= data.count else { throw Failure.damaged }
            let nameBytes = data.subdata(in: (place + 46)..<(place + 46 + nameLength))
            let name = String(data: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)
            place += 46 + nameLength + extra + comment
            if flags & 1 != 0 { throw Failure.unsupported }
            guard !name.hasSuffix("/") else { continue }
            guard local + 30 <= data.count, u32(data, local) == 0x0403_4b50 else { throw Failure.damaged }
            let from = local + 30 + u16(data, local + 26) + u16(data, local + 28)
            guard packed >= 0, plain >= 0, from + packed <= data.count else { throw Failure.damaged }
            total += plain
            guard plain <= limit, total <= limit else { throw Failure.unsupported }
            let body = data.subdata(in: from..<(from + packed))
            switch method {
            case 0:
                entries.append(Entry(name: name, data: body))
            case 8:
                guard let inflated = inflate(body, size: plain) else { throw Failure.damaged }
                entries.append(Entry(name: name, data: inflated))
            default:
                throw Failure.unsupported
            }
        }
        return entries
    }

    private static func inflate(_ packed: Data, size: Int) -> Data? {
        if size == 0 { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { target in
            packed.withUnsafeBytes { source in
                compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, size, source.bindMemory(to: UInt8.self).baseAddress!, packed.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == size ? out : nil
    }

    private static func deflated(_ plain: Data) -> Data? {
        guard !plain.isEmpty else { return nil }
        var out = Data(count: plain.count + 64)
        let written = out.withUnsafeMutableBytes { target in
            plain.withUnsafeBytes { source in
                compression_encode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, plain.count + 64, source.bindMemory(to: UInt8.self).baseAddress!, plain.count, nil, COMPRESSION_ZLIB)
            }
        }
        // Kept only when it is smaller: a tiny file does not shrink.
        return written > 0 && written < plain.count ? out.prefix(written) : nil
    }

    static func checksum(_ data: Data) -> UInt32 {
        UInt32(truncatingIfNeeded: data.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(data.count)) })
    }

    /// An archive of these entries, deflated where that makes them smaller. `time` is the
    /// moment each entry is dated.
    public static func write(_ entries: [Entry], time: Date = Date()) -> Data {
        func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
        func le32(_ value: Int) -> [UInt8] { le16(value & 0xFFFF) + le16((value >> 16) & 0xFFFF) }
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: time)
        let dosTime = ((parts.hour ?? 0) << 11) | ((parts.minute ?? 0) << 5) | ((parts.second ?? 0) / 2)
        let dosDate = ((max((parts.year ?? 1980) - 1980, 0)) << 9) | ((parts.month ?? 1) << 5) | (parts.day ?? 1)
        var out = Data()
        var directory = Data()
        for entry in entries {
            let name = Array(entry.name.utf8)
            let packed = deflated(entry.data)
            let body = packed ?? entry.data
            let common: [UInt8] = le16(20) + le16(0x0800) + le16(packed == nil ? 0 : 8) + le16(dosTime) + le16(dosDate)
                + le32(Int(checksum(entry.data))) + le32(body.count) + le32(entry.data.count) + le16(name.count) + le16(0)
            let offset = out.count
            out.append(contentsOf: le32(0x0403_4b50) + common + name)
            out.append(body)
            directory.append(contentsOf: le32(0x0201_4b50) + le16(20) + common + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + name)
        }
        let start = out.count
        out.append(directory)
        out.append(contentsOf: le32(0x0605_4b50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count) + le32(directory.count) + le32(start) + le16(0))
        return out
    }

    /// An archive as Samsung's engine writes its documents: every entry deflated fast, dated
    /// at nothing, with no word of what made it; and after the archive's end, `after`.
    static func writeAsSamsung(_ entries: [Entry], after: Data = Data()) -> Data {
        func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
        func le32(_ value: Int) -> [UInt8] { le16(value & 0xFFFF) + le16((value >> 16) & 0xFFFF) }
        var out = Data()
        var directory = Data()
        for entry in entries {
            let name = Array(entry.name.utf8)
            let body = deflateFast(entry.data)
            let common: [UInt8] = le16(20) + le16(0x0806) + le16(8) + le16(0) + le16(0x20)
                + le32(Int(checksum(entry.data))) + le32(body.count) + le32(entry.data.count) + le16(name.count) + le16(0)
            let offset = out.count
            out.append(contentsOf: le32(0x0403_4b50) + common + name)
            out.append(body)
            directory.append(contentsOf: le32(0x0201_4b50) + le16(0) + common + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + name)
        }
        let start = out.count
        out.append(directory)
        out.append(contentsOf: le32(0x0605_4b50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count) + le32(directory.count) + le32(start) + le16(0))
        out.append(after)
        return out
    }

    /// Deflated by zlib itself at its fastest level, as the engine does it.
    private static func deflateFast(_ plain: Data) -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, 1, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return Data() }
        defer { deflateEnd(&stream) }
        var out = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(plain.count))) + 16)
        var source = Array(plain)
        let written: Int = source.withUnsafeMutableBufferPointer { input in
            out.withUnsafeMutableBufferPointer { output in
                stream.next_in = input.baseAddress
                stream.avail_in = uInt(input.count)
                stream.next_out = output.baseAddress
                stream.avail_out = uInt(output.count)
                guard deflate(&stream, Z_FINISH) == Z_STREAM_END else { return 0 }
                return output.count - Int(stream.avail_out)
            }
        }
        return Data(out.prefix(written))
    }
}
