import CoreGraphics
import Foundation

public enum StrokeDecodeError: Error, Equatable, Sendable {
    /// The record ended before a required field at the given byte offset.
    case truncated(offset: Int)
    /// No object base frame (type 0) could be located at the start of the record.
    case missingBaseFrame
    /// The record is a valid object but carries no stroke frame (type 1).
    case notAStroke
    /// A structural field holds an impossible value.
    case malformed(String)
}

/// Decoder for Samsung Notes stroke object records as delivered by the sync server.
///
/// Layout (all little-endian), verified against five real records:
///
///     record envelope
///       +0   u32  0xFFFFFFFF marker
///       +4   u32  4            (byte length of the next field)
///       +8   u32  format version (4000)
///     base object frame (type 0, 121 bytes in every sample)
///       +0   u32  frame size
///       +4   i16  frame type = 0
///       +6   u32  flexible-field offset, relative to frame start (105)
///       +10  u8   property mask length (2), then mask
///       +13  u8   field mask length (4), then mask (0x6000)
///       +18  u32  format version
///       +22  u16  id length in bytes (36), then the id as UTF-8
///       +60  i64  modified time (microseconds)
///       +68  f64  left, top, right, bottom
///       +100 i32  replay timestamp, +104 u8 resize mode
///       +105 flexible fields: i64 time, u32 page width, u32 page height
///     stroke frame (type 1)
///       +0   u32  frame size
///       +4   i16  frame type = 1
///       +6   u32  flexible-field offset, relative to frame start
///       +10  u8   property mask length (2), then mask (0x0425)
///       +13  u8   field mask length (4), then mask (0x258E)
///       +18  u16  point count N
///       +20  f64  first x, f64 first y
///       +36  (N-1) x (u16 dx, u16 dy)   sign in bit 15, magnitude / 32
///            f32 first pressure, (N-1) x u16 delta   sign in bit 15, magnitude / 4096
///            i32 first timestamp, (N-1) x i16 delta
///            if property bit 2: tilt and orientation, each f32 + (N-1) x u16
///            u8, u8 tool / input type
///       flexible fields, in field-mask bit order (4 bytes each unless noted):
///            bit 0 legacy pen-name id, 1 advanced-setting id, 2 colour (B,G,R,A bytes),
///            3 pen size f32, 4 one byte, 7 pen-name id, 8 fixed width, ...
///
/// Offsets inside a frame are never assumed: mask lengths, frame sizes and flexible offsets
/// are read from the record, so the same code handles a bare object payload (no envelope).
public enum StrokeDecoder {
    /// Colour used when the record does not declare one: opaque black.
    public static let defaultARGB: UInt32 = 0xFF00_0000
    /// Pen size used when the record does not declare one.
    public static let defaultPenSize: Double = 4.0

    public static func decode(_ data: Data) throws -> InkStroke {
        let bytes = [UInt8](data)
        let start = try locateBaseFrame(in: bytes)

        // Base object frame: id and bounding rect.
        let baseHeader = try FrameHeader(bytes: bytes, at: start)
        var base = Reader(bytes: bytes, offset: baseHeader.fixedStart, limit: baseHeader.end)
        _ = try base.u32()  // format version
        let idLength = Int(try base.u16())
        let id = try decodeID(&base, length: idLength)
        _ = try base.i64()  // modified time
        let left = try base.f64()
        let top = try base.f64()
        let right = try base.f64()
        let bottom = try base.f64()
        guard left.isFinite, top.isFinite, right.isFinite, bottom.isFinite else {
            throw StrokeDecodeError.malformed("non-finite bounding rect")
        }
        let bounds = CGRect(x: min(left, right), y: min(top, bottom), width: abs(right - left), height: abs(bottom - top))

        // Walk the frame chain to the stroke frame.
        var offset = baseHeader.end
        var strokeHeader: FrameHeader?
        for _ in 0..<8 {
            guard offset < bytes.count else { break }
            let header = try FrameHeader(bytes: bytes, at: offset)
            if header.type == 1 {
                strokeHeader = header
                break
            }
            offset = header.end
        }
        guard let header = strokeHeader else { throw StrokeDecodeError.notAStroke }

        var reader = Reader(bytes: bytes, offset: header.fixedStart, limit: header.end)
        let points = try decodePoints(&reader, properties: header.propertyMask)

        var stroke = InkStroke(id: id, bounds: bounds, points: points)
        decodeStyle(header: header, fixedEnd: reader.offset, bytes: bytes, into: &stroke)
        return stroke
    }

    // MARK: - Framing

    private struct FrameHeader {
        var start: Int
        var end: Int
        var type: Int16
        /// Absolute offset of the flexible fields, or `nil` if the declared one is unusable.
        var flexibleStart: Int?
        var propertyMask: UInt64
        var fieldMask: UInt64
        /// Absolute offset of the first fixed field after the masks.
        var fixedStart: Int

        init(bytes: [UInt8], at start: Int) throws {
            var reader = Reader(bytes: bytes, offset: start, limit: bytes.count)
            let size = Int(try reader.u32())
            let type = try reader.i16()
            let flexible = Int(try reader.u32())
            guard size >= 12, size <= bytes.count - start else {
                throw StrokeDecodeError.malformed("frame size \(size) at offset \(start)")
            }
            reader.limit = start + size
            let propertyMask = try reader.mask()
            let fieldMask = try reader.mask()
            self.start = start
            self.end = start + size
            self.type = type
            self.propertyMask = propertyMask
            self.fieldMask = fieldMask
            self.fixedStart = reader.offset
            self.flexibleStart = (flexible >= reader.offset - start && flexible <= size) ? start + flexible : nil
        }
    }

    /// Finds the start of the type-0 base frame, tolerating the sync envelope or its absence.
    private static func locateBaseFrame(in bytes: [UInt8]) throws -> Int {
        var candidates: [Int] = []
        if bytes.count >= 8, bytes[0] == 0xFF, bytes[1] == 0xFF, bytes[2] == 0xFF, bytes[3] == 0xFF {
            let length = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
            if length <= 64 { candidates.append(8 + length) }
            candidates.append(12)
        }
        candidates.append(0)
        for candidate in candidates {
            if let header = try? FrameHeader(bytes: bytes, at: candidate), header.type == 0, header.end - header.start >= 60 {
                return candidate
            }
        }
        if bytes.count < 24 { throw StrokeDecodeError.truncated(offset: bytes.count) }
        throw StrokeDecodeError.missingBaseFrame
    }

    private static func decodeID(_ reader: inout Reader, length: Int) throws -> String {
        // Sync records store the id as UTF-8; tolerate UTF-16LE (length in code units) too.
        let peek = reader.peek(4)
        if length >= 2, peek.count == 4, peek[1] == 0, peek[3] == 0 {
            let raw = try reader.take(length * 2)
            var units: [UInt16] = []
            units.reserveCapacity(length)
            var index = raw.startIndex
            while index + 1 < raw.endIndex {
                units.append(UInt16(raw[index]) | UInt16(raw[index + 1]) << 8)
                index += 2
            }
            return String(decoding: units, as: UTF16.self)
        }
        return String(decoding: try reader.take(length), as: UTF8.self)
    }

    // MARK: - Geometry and channels

    private static func decodePoints(_ reader: inout Reader, properties: UInt64) throws -> [InkPoint] {
        let count = Int(try reader.u16())
        guard count > 0 else { return [] }
        let compressed = properties & 0x1 != 0

        var points: [InkPoint] = []
        points.reserveCapacity(count)

        if compressed {
            var x = try reader.f64()
            var y = try reader.f64()
            guard x.isFinite, y.isFinite else { throw StrokeDecodeError.malformed("non-finite start point") }
            points.append(InkPoint(x: x, y: y))
            for _ in 1..<count {
                x += signedMagnitude(try reader.u16(), scale: 32)
                y += signedMagnitude(try reader.u16(), scale: 32)
                points.append(InkPoint(x: x, y: y))
            }
        } else {
            for _ in 0..<count {
                let x = try reader.f64()
                let y = try reader.f64()
                guard x.isFinite, y.isFinite else { throw StrokeDecodeError.malformed("non-finite point") }
                points.append(InkPoint(x: x, y: y))
            }
        }

        // Pressure and time are optional for drawing: a record cut short after the
        // coordinates still yields a usable stroke (pressure 1, no timing).
        var channels = reader
        do {
            if compressed {
                var pressure = Double(try channels.f32())
                var pressures = [pressure]
                pressures.reserveCapacity(count)
                for _ in 1..<count {
                    pressure += signedMagnitude(try channels.u16(), scale: 4096)
                    pressures.append(pressure)
                }
                var time = Int(try channels.i32())
                var times = [time]
                times.reserveCapacity(count)
                for _ in 1..<count {
                    // Deltas are two's-complement: phone records contain pairs such as +5, -5.
                    time += Int(try channels.i16())
                    times.append(time)
                }
                for index in 0..<count {
                    points[index].pressure = pressures[index].isFinite ? pressures[index] : 1
                    points[index].time = times[index]
                }
            } else {
                var pressures: [Double] = []
                pressures.reserveCapacity(count)
                for _ in 0..<count { pressures.append(Double(try channels.f32())) }
                var times: [Int] = []
                times.reserveCapacity(count)
                for _ in 0..<count { times.append(Int(try channels.i32())) }
                for index in 0..<count {
                    points[index].pressure = pressures[index].isFinite ? pressures[index] : 1
                    points[index].time = times[index]
                }
            }
            // Tilt and orientation (property bit 2) are not surfaced; skip them so the reader
            // ends on the two tool-type bytes that precede the flexible fields.
            if properties & 0x4 != 0 {
                let channelSize = compressed ? 4 + 2 * (count - 1) : 4 * count
                try channels.skip(2 * channelSize)
            }
            try channels.skip(2)
            reader = channels
        } catch {
            // Keep the geometry; leave defaults for whatever could not be read.
        }
        return points
    }

    /// 16-bit sign-and-magnitude fixed point: bit 15 is the sign, the low 15 bits the magnitude.
    private static func signedMagnitude(_ word: UInt16, scale: Double) -> Double {
        let magnitude = Double(word & 0x7FFF) / scale
        return word & 0x8000 != 0 ? -magnitude : magnitude
    }

    // MARK: - Style

    private static func decodeStyle(header: FrameHeader, fixedEnd: Int, bytes: [UInt8], into stroke: inout InkStroke) {
        let start = header.flexibleStart ?? fixedEnd
        var reader = Reader(bytes: bytes, offset: start, limit: header.end)
        var legacyPenNameID: Int?
        var penNameID: Int?
        // What the record says of the manner of the stroke (see `InkStroke.Style`).
        stroke.style.fixedWidth = header.propertyMask & (1 << 4) != 0
        stroke.style.topLayer = header.propertyMask & (1 << 6) != 0
        stroke.style.fixedOpacity = header.propertyMask & (1 << 11) != 0
        stroke.style.revealed = header.propertyMask & (1 << 14) != 0
        // Fields are stored in ascending bit order, each of a width read from the Windows
        // client's own reader. Stop at the first bit whose width is not known (5, 6, above 25),
        // keeping what was read before it.
        loop: for bit in 0..<64 where header.fieldMask & (1 << UInt64(bit)) != 0 {
            do {
                switch bit {
                case 0: legacyPenNameID = Int(try reader.i32())
                case 1: stroke.settingID = Int(try reader.i32())  // advanced pen-setting string id
                case 2: stroke.argb = try reader.u32()  // B,G,R,A bytes == little-endian 0xAARRGGBB
                case 3:
                    let size = Double(try reader.f32())
                    if size.isFinite, size > 0 { stroke.penSize = size }
                case 4: _ = try reader.u8()
                case 7: penNameID = Int(try reader.i32())
                case 8: _ = try reader.f32()                               // fixed width
                case 9: stroke.style.sizeLevel = Int(try reader.i32())
                case 10, 11, 12: _ = try reader.i32()                      // particle density, rendering level, original width
                case 13: _ = try reader.f32()                              // tolerance
                case 14: stroke.style.lineType = Int(try reader.u16())
                case 15: _ = try reader.f32()                              // dash offset
                case 16: _ = try reader.u16()                              // stroke type
                case 17, 18: _ = try reader.f32()                          // repeat distance, particle size
                case 19: stroke.style.patternIndex = Int(try reader.i32())
                case 20:
                    let scale = Double(try reader.f32())
                    if scale.isFinite, scale > 0 { stroke.style.patternScale = scale }
                case 21, 22: _ = try reader.i32()                          // particle level, rainbow distance
                case 23: _ = try reader.f32()                              // rainbow offset
                case 24:
                    let count = Int(try reader.u16())
                    for _ in 0..<min(count, 256) { _ = try reader.u32() }
                case 25: stroke.style.colorType = Int(try reader.u16())
                default: break loop
                }
            } catch {
                break loop
            }
        }
        if let id = penNameID ?? legacyPenNameID, id >= 0 { stroke.penNameID = id }
    }

    // MARK: - Bounds-checked reader

    private struct Reader {
        let bytes: [UInt8]
        var offset: Int
        var limit: Int

        init(bytes: [UInt8], offset: Int, limit: Int) {
            self.bytes = bytes
            self.offset = max(0, offset)
            self.limit = min(max(0, limit), bytes.count)
        }

        private mutating func advance(_ count: Int) throws -> Int {
            guard count >= 0, offset <= limit, limit - offset >= count else {
                throw StrokeDecodeError.truncated(offset: offset)
            }
            let start = offset
            offset += count
            return start
        }

        mutating func skip(_ count: Int) throws { _ = try advance(count) }

        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            let start = try advance(count)
            return bytes[start..<start + count]
        }

        func peek(_ count: Int) -> [UInt8] {
            guard count >= 0, offset <= limit, limit - offset >= count else { return [] }
            return Array(bytes[offset..<offset + count])
        }

        private mutating func integer(_ count: Int) throws -> UInt64 {
            let start = try advance(count)
            var value: UInt64 = 0
            for index in 0..<count { value |= UInt64(bytes[start + index]) << UInt64(8 * index) }
            return value
        }

        mutating func u8() throws -> UInt8 { UInt8(truncatingIfNeeded: try integer(1)) }
        mutating func u16() throws -> UInt16 { UInt16(truncatingIfNeeded: try integer(2)) }
        mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
        mutating func u32() throws -> UInt32 { UInt32(truncatingIfNeeded: try integer(4)) }
        mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
        mutating func i64() throws -> Int64 { Int64(bitPattern: try integer(8)) }
        mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
        mutating func f64() throws -> Double { Double(bitPattern: try integer(8)) }

        /// A length-prefixed bit mask (`u8 n`, then `n` little-endian bytes; only 8 are kept).
        mutating func mask() throws -> UInt64 {
            let length = Int(try u8())
            let raw = try take(length)
            var value: UInt64 = 0
            for (index, byte) in raw.prefix(8).enumerated() { value |= UInt64(byte) << UInt64(8 * index) }
            return value
        }
    }
}
