import CoreGraphics
import Foundation

/// Writes stroke records in the form the Windows client sends them. The layout is the one
/// `StrokeDecoder` documents; real records re-encode byte for byte (see the tests).
public enum StrokeEncoder {
    /// The exact bounds of a stroke's points, which is what the record stores.
    public static func bounds(of points: [InkPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Positions are stored as steps of 1/32 from the point before: this is the same rounding.
    public static func quantized(_ points: [InkPoint]) -> [InkPoint] {
        guard var previous = points.first else { return [] }
        var out = [previous]
        for point in points.dropFirst() {
            var next = point
            next.x = previous.x + (step(point.x - previous.x, scale: 32).value)
            next.y = previous.y + (step(point.y - previous.y, scale: 32).value)
            out.append(next)
            previous = next
        }
        return out
    }

    /// A sign-and-magnitude 16-bit step and the value it stands for. Positions carry the sign
    /// bit on every step that is not forwards, a step of nothing included; pressure only on a
    /// step backwards. Real records show both habits.
    static func step(_ delta: Double, scale: Double, zeroIsNegative: Bool = false) -> (word: UInt16, value: Double) {
        guard delta.isFinite else { return (zeroIsNegative ? 0x8000 : 0, 0) }
        let magnitude = min((abs(delta) * scale).rounded(), 32_767)
        let negative = magnitude == 0 ? zeroIsNegative : delta < 0
        return (UInt16(magnitude) | (negative ? 0x8000 : 0), (delta < 0 ? -magnitude : magnitude) / scale)
    }

    /// `tolerance` is the smoothing value of the stroke's pen; a pen that has none leaves the field out.
    public static func encode(_ stroke: InkStroke, modifiedMicros: Int64, drawnMicros: Int64, pageWidth: Int, pageHeight: Int, settingID: Int = 1, tolerance: Double? = 2.6) -> Data {
        var out = Data()
        func u8(_ value: UInt8) { out.append(value) }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
        func i64(_ value: Int64) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        func f32(_ value: Float) { u32(value.bitPattern) }
        func f64(_ value: Double) { withUnsafeBytes(of: value.bitPattern.littleEndian) { out.append(contentsOf: $0) } }

        // Envelope: marker, the length of the next field, the format version.
        u32(0xFFFF_FFFF); u32(4); u32(4000)

        // Base object frame. A tape lies in a layer of its own above the handwriting, which
        // the frame says with one field more at its end.
        let style = stroke.style
        let isTape = Pen.kind(named: stroke.penName) == .tape
        let id = Array(stroke.id.utf8)
        let flexible = 105 - 36 + id.count
        let baseSize = flexible + 16 + (isTape ? 4 : 0)
        u32(UInt32(baseSize)); u16(0); u32(UInt32(flexible))
        u8(2); out.append(contentsOf: [0xBF, 0x01])
        u8(4); out.append(contentsOf: [0x00, 0x60, isTape ? 0x20 : 0x00, 0x00])
        u32(4000)
        u16(UInt16(id.count)); out.append(contentsOf: id)
        i64(modifiedMicros)
        f64(stroke.bounds.minX); f64(stroke.bounds.minY); f64(stroke.bounds.maxX); f64(stroke.bounds.maxY)
        i32(0); u8(0)
        i64(drawnMicros); u32(UInt32(max(pageWidth, 0))); u32(UInt32(max(pageHeight, 0)))
        if isTape { i32(2) }

        // Stroke frame: its size and the offset of its style fields are filled in at the end.
        let frameStart = out.count
        u32(0); u16(1); u32(0)
        // Curved, with tilt, times in milliseconds, drawn by hand; and the manner of the stroke.
        var properties: UInt16 = 0x0425
        if style.fixedWidth { properties |= 1 << 4 }
        if style.topLayer { properties |= 1 << 6 }
        if style.fixedOpacity { properties |= 1 << 11 }
        if style.revealed { properties |= 1 << 14 }
        u8(2); u16(properties)
        // Which style fields follow: setting, colour, size, pen name, fixed width, particle density, the
        // tolerance when the pen has one; and, when they say something, the size's level (kept by
        // dashed and dotted lines), the kind of line, a tape's pattern and its scale, the kind of colour.
        var fields: UInt32 = 0x058E
        if tolerance != nil { fields |= 1 << 13 }
        if style.lineType != 0 { fields |= 1 << 14; if style.sizeLevel != 0 { fields |= 1 << 9 } }
        if style.patternIndex != -1 { fields |= 1 << 19 }
        if abs(style.patternScale - 1) > 0.0001 { fields |= 1 << 20 }
        if style.colorType != 0 { fields |= 1 << 25 }
        u8(4); u32(fields)
        let points = stroke.points
        u16(UInt16(min(points.count, 65_535)))
        if let first = points.first {
            f64(first.x); f64(first.y)
            var x = first.x, y = first.y
            for point in points.dropFirst() {
                let dx = step(point.x - x, scale: 32, zeroIsNegative: true), dy = step(point.y - y, scale: 32, zeroIsNegative: true)
                u16(dx.word); u16(dy.word)
                x += dx.value; y += dy.value
            }
            var pressure = first.pressure
            f32(Float(pressure))
            for point in points.dropFirst() {
                let delta = step(point.pressure - pressure, scale: 4096)
                u16(delta.word)
                pressure += delta.value
            }
            var time = first.time ?? 0
            i32(Int32(clamping: time))
            for point in points.dropFirst() {
                let delta = Int16(clamping: (point.time ?? time) - time)
                u16(UInt16(bitPattern: delta))
                time += Int(delta)
            }
            // Tilt and orientation: none from a mouse or trackpad.
            for _ in 0..<2 {
                f32(0)
                for _ in points.dropFirst() { u16(0) }
            }
        }
        out.append(contentsOf: [0x03, 0x00])
        let styleStart = out.count
        u32(UInt32(max(settingID, 0)))          // the advanced pen setting, by its place in the string table
        u32(stroke.argb)                        // little-endian, so the bytes are B, G, R, A
        f32(Float(stroke.penSize))
        u32(UInt32(max(stroke.penNameID ?? 0, 0)))
        f32(Float(stroke.penSize))
        if fields & (1 << 9) != 0 { i32(Int32(clamping: style.sizeLevel)) }
        u32(1)
        if let tolerance { f32(Float(tolerance)) }
        if fields & (1 << 14) != 0 { u16(UInt16(clamping: style.lineType)) }
        if fields & (1 << 19) != 0 { i32(Int32(clamping: style.patternIndex)) }
        if fields & (1 << 20) != 0 { f32(Float(style.patternScale)) }
        if fields & (1 << 25) != 0 { u16(UInt16(clamping: style.colorType)) }
        func patch(_ offset: Int, _ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.replaceSubrange(offset..<offset + 4, with: $0) } }
        patch(frameStart, UInt32(out.count - frameStart))
        patch(frameStart + 6, UInt32(styleStart - frameStart))
        return out
    }
}
