import XCTest
@testable import SamsungNotesKit

/// The Windows client's pen options as its stroke record keeps them, and the changes to
/// strokes the tools make.
final class PenOptionTests: XCTestCase {
    private func stroke(_ pen: Pen, style: InkStroke.Style = InkStroke.Style(), argb: UInt32 = 0xFF25_2525) throws -> InkStroke {
        let points = (0..<20).map { InkPoint(x: 100 + Double($0) * 6, y: 200 + Double($0 % 3), pressure: 1, time: $0 * 8) }
        var made = try XCTUnwrap(LocalEdits.prepared(NewStroke(points: points, argb: argb, penSize: 8, pen: pen, style: style)))
        made.penNameID = 3
        return made
    }

    private func again(_ stroke: InkStroke) throws -> InkStroke {
        let data = StrokeEncoder.encode(stroke, modifiedMicros: 1_791_900_000_000_000, drawnMicros: 1_791_899_999_999_000, pageWidth: 848, pageHeight: 1200, settingID: 2, tolerance: stroke.pen.tolerance)
        var read = try StrokeDecoder.decode(data)
        read.penName = stroke.penName
        return read
    }

    func testAPlainStrokeIsWrittenAsBefore() throws {
        let plain = try stroke(.fountain)
        let data = StrokeEncoder.encode(plain, modifiedMicros: 1, drawnMicros: 0, pageWidth: 848, pageHeight: 1200)
        // The masks of every stroke this client wrote so far: curved, with tilt, in milliseconds; setting, colour, size, name, fixed width, density, tolerance.
        XCTAssertNotNil(data.range(of: Data([0x02, 0x25, 0x04, 0x04, 0x8E, 0x25, 0x00, 0x00])))
        XCTAssertEqual(try again(plain).style, InkStroke.Style())
    }

    func testTheKindOfLineAndItsEvennessComeBack() throws {
        var dashed = InkStroke.Style()
        dashed.lineType = 1
        dashed.sizeLevel = 30
        let read = try again(try stroke(.ballpoint, style: dashed))
        XCTAssertEqual(read.style.lineType, 1)
        XCTAssertEqual(read.style.sizeLevel, 30, "a dashed line keeps the level its size was set at")
        XCTAssertEqual(read.penSize, 8, accuracy: 0.001)
        XCTAssertEqual(read.argb, 0xFF25_2525)
        XCTAssertEqual(read.points.count, 20, "the line is stored whole; the gaps are made when it is drawn")

        var even = InkStroke.Style()
        even.fixedWidth = true
        even.fixedOpacity = true
        let fixed = try again(try stroke(.pencil, style: even, argb: 0xA6FF_3636))
        XCTAssertTrue(fixed.style.fixedWidth && fixed.style.fixedOpacity)
        XCTAssertEqual(fixed.style.lineType, 0)
        XCTAssertEqual(fixed.argb >> 24, 0xA6, "how see-through a pencil is lies in its colour")

        // Dashes go by the pen's width and the level of its size; dots by the pen.
        XCTAssertEqual(InkRenderer.dashLengths(lineType: 1, sizeLevel: 30, penSize: 10, pencil: false)?.dash, 26)
        XCTAssertEqual(InkRenderer.dashLengths(lineType: 1, sizeLevel: 10, penSize: 10, pencil: false)?.gap, 30)
        XCTAssertEqual(InkRenderer.dashLengths(lineType: 2, sizeLevel: 30, penSize: 10, pencil: false)?.dash, 1)
        XCTAssertEqual(InkRenderer.dashLengths(lineType: 2, sizeLevel: 30, penSize: 10, pencil: true)?.gap, 16)
        XCTAssertNil(InkRenderer.dashLengths(lineType: 0, sizeLevel: 30, penSize: 10, pencil: false))
    }

    func testATapeKeepsItsPatternAndWhetherItIsOpen() throws {
        var look = InkStroke.Style()
        look.colorType = 2
        look.patternIndex = 4
        look.revealed = true
        let tape = try stroke(.tape, style: look)
        XCTAssertEqual(Pen.kind(named: tape.penName), .tape)
        let read = try again(tape)
        XCTAssertEqual(read.style.colorType, 2)
        XCTAssertEqual(read.style.patternIndex, 4)
        XCTAssertTrue(read.style.revealed)
        XCTAssertEqual(read.points.count, 20)
        XCTAssertEqual(read.bounds, tape.bounds)
        // The marker pen and the highlighter are the two that lie over the rest.
        var over = InkStroke.Style()
        over.topLayer = true
        XCTAssertTrue(try again(try stroke(.marker, style: over, argb: 0x7337_D366)).style.topLayer)
        XCTAssertEqual(Pen.kind(named: Pen.marker.name), .marker)
        XCTAssertEqual(Pen.kind(named: Pen.highlighter.name), .highlighter)
        XCTAssertEqual(Pen.kind(named: "com.samsung.android.sdk.pen.pen.preload.Pencil3"), .pencil, "this client's older pencil strokes are pencil still")
        XCTAssertEqual(Pen.pencil.name.hasSuffix("Pencil2"), true)
    }

    func testTheAreaEraserCutsALineAndStraightLinesAreAsWindowsMakesThem() throws {
        let line = (0...10).map { InkPoint(x: Double($0) * 10, y: 0, pressure: 1, time: $0 * 10) }
        // A disc over its middle leaves both ends, each cut off at the disc's edge.
        let pieces = try XCTUnwrap(InkEdit.cut(line, centre: CGPoint(x: 50, y: 0), radius: 12))
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(try XCTUnwrap(pieces[0].last).x, 38, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(pieces[1].first).x, 62, accuracy: 0.05)
        // Off the line: untouched. Over its end: one piece. Over all of it: nothing left.
        XCTAssertNil(InkEdit.cut(line, centre: CGPoint(x: 50, y: 40), radius: 12))
        XCTAssertEqual(InkEdit.cut(line, centre: CGPoint(x: 0, y: 0), radius: 12)?.count, 1)
        XCTAssertEqual(InkEdit.cut(line, centre: CGPoint(x: 50, y: 0), radius: 80)?.count, 0)
        // A line of two points far apart is cut all the same.
        XCTAssertEqual(InkEdit.cut([line[0], line[10]], centre: CGPoint(x: 50, y: 0), radius: 5)?.count, 2)

        // A hundredth of the page's lesser side a step, five steps at least, at half pressure.
        let wavering = (0...30).map { InkPoint(x: Double($0) * 10, y: 5 * sin(Double($0)), pressure: 1, time: $0 * 5) }
        let straight = InkEdit.straightened(wavering, pageWidth: 848, pageHeight: 1200)
        XCTAssertEqual(straight.count, Int(300 / 8.48) + 1)
        XCTAssertTrue(straight.allSatisfy { $0.pressure == 0.5 })
        XCTAssertEqual(straight.first?.x, 0)
        XCTAssertEqual(try XCTUnwrap(straight.last).x, 300, accuracy: 0.001)
        XCTAssertEqual(straight.first?.time, 0)
        XCTAssertEqual(InkEdit.straightened([wavering[0], wavering[1]], pageWidth: 848, pageHeight: 1200).count, 6)
    }
}
