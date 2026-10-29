import XCTest
@testable import SamsungNotesKit

/// Tables as Samsung's clients keep them: two made in the Windows client, read from a real sync.
final class SamsungTableTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil)))
    }

    func testATableOfTheWindowsClientIsReadAndWrittenByteForByte() throws {
        let data = try fixture("table-2x2-windows.bin")
        let table = try XCTUnwrap(SamsungTable(binary: data))
        XCTAssertEqual(table.id, "c74d6044-c64b-11f1-bf6e-3b0df6ece061")
        XCTAssertEqual(table.texts, [["Test 1", "Test 2"], ["Test 3", "Test 4"]])
        XCTAssertEqual(table.columnWidths, [538.5, 538.5])
        XCTAssertEqual(table.pageWidth, 1183)
        XCTAssertEqual(table.rect.minX, 52.7278, accuracy: 0.001)
        XCTAssertEqual(table.rect.height, 185.665, accuracy: 0.01)
        XCTAssertEqual(table.rows[0][0].fontSize, 15)
        XCTAssertEqual(table.rows[0][0].color, 0xFF25_2525)
        XCTAssertEqual(table.binary, data)
    }

    func testBoldAndItalicCellsAreKept() throws {
        let data = try fixture("table-2x3-windows.bin")
        let table = try XCTUnwrap(SamsungTable(binary: data))
        XCTAssertEqual(table.texts, [["Test 5", "Test 6", "Test 7"], ["Test 8", "Test 9", "Test 10"]])
        XCTAssertEqual(table.rows[1].map(\.bold), [false, false, true])
        XCTAssertEqual(table.rows[1].map(\.italic), [false, false, true])
        XCTAssertEqual(table.binary, data)
    }

    /// Laid out anew where it stands, a table of the Windows client comes out as that client laid it out.
    func testTheLayoutIsTheEnginesOwn() throws {
        for name in ["table-2x2-windows.bin", "table-2x3-windows.bin"] {
            let data = try fixture(name)
            var table = try XCTUnwrap(SamsungTable(binary: data))
            table.layOut(left: table.rect.minX, top: table.rect.minY)
            XCTAssertEqual(table.binary, data, name)
        }
    }

    func testANewTableIsOneThisClientCanReadBack() throws {
        var table = SamsungTable(rows: 3, columns: 4, pageWidth: 848, top: 120)
        XCTAssertEqual(table.columns, 4)
        XCTAssertEqual(table.rows.count, 3)
        // As wide as the text's column: sixteen units of text size in from either edge.
        XCTAssertEqual(table.columnWidths.reduce(0, +), 848 - 2 * 38, accuracy: 0.01)
        XCTAssertEqual(table.rect.minY, 120, accuracy: 0.001)
        // A row of one line of size 15 is (15 × 1.35 + 8) units of text size high.
        XCTAssertEqual(table.rect.height / 3, (15 * 1.35 + 8) * 848 / 360, accuracy: 0.05)
        table = table.with(texts: [["a", "b", "c", "d"], ["e", "", "", ""], ["", "", "", "last"]])
        let read = try XCTUnwrap(SamsungTable(binary: table.binary))
        XCTAssertEqual(read.texts, table.texts)
        XCTAssertEqual(read.rect, table.rect)
        XCTAssertEqual(read.texts[2][3], "last")
        XCTAssertEqual(read.binary, table.binary)
    }

    func testChangingATable() throws {
        let table = try XCTUnwrap(SamsungTable(binary: try fixture("table-2x3-windows.bin")))
        // A text that needs two lines makes its row taller; the others keep their height.
        let long = table.with(texts: [["Test 5", "Test 6", "Test 7"], ["Test 8", String(repeating: "many words ", count: 12), "Test 10"]])
        XCTAssertEqual(long.cellRects[0][0].height, table.cellRects[0][0].height, accuracy: 0.01)
        XCTAssertGreaterThan(long.cellRects[1][0].height, table.cellRects[1][0].height * 1.5)
        XCTAssertEqual(long.rows[1][2].id, table.rows[1][2].id)
        XCTAssertTrue(long.rows[1][2].bold, "a cell that stays keeps its style")
        XCTAssertGreaterThan(long.modified, table.modified)
        // A row and a column more: new cells, the same width in all.
        let grown = table.with(texts: [["1", "2", "3", "4"], ["5", "6", "7", "8"], ["9", "10", "11", "12"]])
        XCTAssertEqual(grown.columns, 4)
        XCTAssertEqual(grown.rows.count, 3)
        XCTAssertEqual(grown.columnWidths.reduce(0, +), table.columnWidths.reduce(0, +), accuracy: 0.01)
        XCTAssertEqual(Set(grown.rows.flatMap { $0 }.map(\.id)).count, 12)
        XCTAssertEqual(try XCTUnwrap(SamsungTable(binary: grown.binary)).texts, grown.texts)
        // Moved, every line moves with it.
        var moved = table
        moved.move(to: CGPoint(x: table.rect.minX, y: table.rect.minY + 300))
        XCTAssertEqual(moved.rect.height, table.rect.height, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(SamsungTable(binary: moved.binary)).rect.minY, table.rect.minY + 300, accuracy: 0.01)
    }

    func testWhatIsNoTableIsRefused() throws {
        XCTAssertNil(SamsungTable(binary: Data()))
        XCTAssertNil(SamsungTable(binary: Data(count: 400)))
        var cut = try fixture("table-2x2-windows.bin")
        cut.removeLast(700)
        XCTAssertNil(SamsungTable(binary: cut))
        // Every stretch of a real record cut short or filled with noise is refused or read, never a trap.
        let whole = try fixture("table-2x2-windows.bin")
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<400 {
            var damaged = [UInt8](whole)
            for _ in 0..<Int.random(in: 1...6, using: &generator) { damaged[Int.random(in: 12..<damaged.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator) }
            _ = SamsungTable(binary: Data(damaged))?.binary
        }
    }

    /// A cell that another client formatted in parts is drawn in its parts, written back as it
    /// came, and keeps its formatting when its words or other cells change.
    func testACellFormattedInPartsKeepsItsFormatting() throws {
        var table = try XCTUnwrap(SamsungTable(binary: try fixture("table-2x2-windows.bin")))
        var record = try XCTUnwrap(table.rows[0][1].record)
        XCTAssertEqual(record.string, "Test 2")
        record.spans.append(SPen.Span(type: 7, start: 0, end: 4, value: [1, 0, 0, 0, 0, 0, 0, 0]))
        var large = SPen.Writer(); large.f32(20); large.u32(0)
        record.spans.append(SPen.Span(type: 3, start: 5, end: 6, value: large.bytes))
        table.rows[0][1].adopt(record)
        let formatted = table.binary
        let read = try XCTUnwrap(SamsungTable(binary: formatted))
        XCTAssertEqual(read.binary, formatted, "a table with a cell formatted in parts can be changed here")
        XCTAssertEqual(read.rows[0][1].runs.map(\.text), ["Test", " ", "2"])
        XCTAssertEqual(read.rows[0][1].runs.map(\.underline), [true, false, false])
        XCTAssertEqual(read.rows[0][1].runs.map(\.fontSize), [15, 15, 20])
        XCTAssertEqual(read.rows[0][0].runs.map(\.text), ["Test 1"])

        // Another cell changes: this one is written as it was. Then its own words change.
        var changed = try XCTUnwrap(SamsungTable(binary: read.with(texts: [["Changed", "Test 2"], ["Test 3", "Test 4"]]).binary))
        XCTAssertEqual(changed.rows[0][1].record, read.rows[0][1].record)
        XCTAssertEqual(changed.rows[0][0].text, "Changed")
        changed = try XCTUnwrap(SamsungTable(binary: changed.with(texts: [["Changed", "Tests 2!"], ["Test 3", "Test 4"]]).binary))
        XCTAssertEqual(changed.rows[0][1].runs.map(\.text), ["Tests", " ", "2!"])
        XCTAssertEqual(changed.rows[0][1].runs.map(\.underline), [true, false, false])
        XCTAssertEqual(changed.rows[0][1].runs.map(\.fontSize), [15, 15, 20])
        // The row is as high as its largest text needs.
        XCTAssertGreaterThan(changed.cellRects[0][0].height, changed.cellRects[1][0].height + 10)
    }

    func testBoldAndItalicAreSetCellByCell() throws {
        let table = try XCTUnwrap(SamsungTable(binary: try fixture("table-2x3-windows.bin")))
        let texts = table.texts
        let styled = try XCTUnwrap(SamsungTable(binary: table.with(texts: texts, bold: [[true, false, false], [false, false, false]], italic: [[false, true, false], [false, false, true]]).binary))
        XCTAssertEqual(styled.rows.map { $0.map(\.bold) }, [[true, false, false], [false, false, false]])
        XCTAssertEqual(styled.rows.map { $0.map(\.italic) }, [[false, true, false], [false, false, true]])
        XCTAssertEqual(styled.texts, texts)
        // Without any said, the styles stay.
        let again = try XCTUnwrap(SamsungTable(binary: styled.with(texts: texts).binary))
        XCTAssertEqual(again.rows.map { $0.map(\.bold) }, styled.rows.map { $0.map(\.bold) })
        // A new table's cells take them too.
        let made = SamsungTable(rows: 1, columns: 2, pageWidth: 848, top: 100).with(texts: [["a", "b"]], bold: [[false, true]])
        XCTAssertEqual(try XCTUnwrap(SamsungTable(binary: made.binary)).rows[0].map(\.bold), [false, true])
    }

    /// A table of four rows and three columns as the Windows client makes it, nothing written
    /// in it yet and its first column dragged narrower.
    func testAnEmptyTableWithANarrowedColumn() throws {
        let data = try fixture("table-4x3-empty-windows.bin")
        let table = try XCTUnwrap(SamsungTable(binary: data))
        XCTAssertEqual(table.columnWidths, [163.00002, 359, 359])
        XCTAssertEqual(table.texts, Array(repeating: ["", "", ""], count: 4))
        if let out = ProcessInfo.processInfo.environment["SNOTES_DUMP"] { try table.binary.write(to: URL(fileURLWithPath: out)) }
        XCTAssertEqual(table.binary, data)
        // Its first column made wider again: every cell follows, and the table reads back as it was written.
        var wider = table
        wider.setWidth(300, ofColumn: 0)
        XCTAssertEqual(wider.columnWidths, [300, 359, 359])
        XCTAssertEqual(wider.rect.width, 1018, accuracy: 0.01)
        XCTAssertEqual(wider.rect.origin, table.rect.origin)
        let read = try XCTUnwrap(SamsungTable(binary: wider.binary))
        XCTAssertEqual(read.binary, wider.binary)
        for (width, wanted) in zip(read.cellRects[0].map { Double($0.width) }, [300.0, 359, 359]) { XCTAssertEqual(width, wanted, accuracy: 0.001) }
        XCTAssertEqual(read.rows[0][0].id, table.rows[0][0].id)
        // Never wider than the text's column, never narrower than a tenth of it.
        wider.setWidth(5_000, ofColumn: 0)
        XCTAssertEqual(wider.columnWidths, [359, 359, 359])
        wider.setWidth(1, ofColumn: 2)
        XCTAssertEqual(wider.columnWidths[2], 107.7, accuracy: 0.01)
        wider.fitToWidth()
        XCTAssertEqual(wider.columnWidths.reduce(0, +), 1077, accuracy: 0.01)
    }

    func testRowsAndColumnsComeAndGoAnywhere() throws {
        var table = try XCTUnwrap(SamsungTable(binary: try fixture("table-2x3-windows.bin")))
        let ids = table.rows.map { $0.map(\.id) }
        table.insertRow(at: 1)
        XCTAssertEqual(table.texts, [["Test 5", "Test 6", "Test 7"], ["", "", ""], ["Test 8", "Test 9", "Test 10"]])
        table.insertColumn(at: 0)
        XCTAssertEqual(table.texts[0], ["", "Test 5", "Test 6", "Test 7"])
        XCTAssertEqual(table.columnWidths.reduce(0, +), 1077, accuracy: 0.01, "four columns share the width three had")
        table.removeColumn(at: 2)
        table.removeRow(at: 0)
        XCTAssertEqual(table.texts, [["", "", ""], ["", "Test 8", "Test 10"]])
        let read = try XCTUnwrap(SamsungTable(binary: table.binary))
        XCTAssertEqual(read.binary, table.binary)
        XCTAssertEqual(read.texts, table.texts)
        XCTAssertEqual(read.rows[1][1].id, ids[1][0], "a cell that stays keeps its id")
        XCTAssertEqual(read.rows[1][2].bold, true, "and its style")
        // The last row and the last column cannot go.
        table.removeRow(at: 0); table.removeRow(at: 0)
        XCTAssertEqual(table.rows.count, 1)
        table.removeColumn(at: 0); table.removeColumn(at: 0); table.removeColumn(at: 0)
        XCTAssertEqual(table.columns, 1)
    }

    func testACellsStyleIsSetAsAWhole() throws {
        var table = try XCTUnwrap(SamsungTable(binary: try fixture("table-2x2-windows.bin")))
        table.change(where: { row, _ in row == 0 }) { cell in
            cell.underline = true; cell.strikethrough = true; cell.fontSize = 20; cell.color = 0xFF14_47FF; cell.alignment = 2; cell.background = 0xFFFF_F3C4
        }
        let read = try XCTUnwrap(SamsungTable(binary: table.binary))
        XCTAssertEqual(read.binary, table.binary)
        for cell in read.rows[0] {
            XCTAssertTrue(cell.underline && cell.strikethrough)
            XCTAssertEqual(cell.fontSize, 20)
            XCTAssertEqual(cell.color, 0xFF14_47FF)
            XCTAssertEqual(cell.alignment, 2)
            XCTAssertEqual(cell.background, 0xFFFF_F3C4)
        }
        XCTAssertEqual(read.rows[1][0].fontSize, 15)
        XCTAssertEqual(read.rows[1][0].alignment, 0)
        XCTAssertFalse(read.rows[1][0].underline)
        // The row with the larger text is the higher.
        XCTAssertGreaterThan(read.cellRects[0][0].height, read.cellRects[1][0].height + 10)
    }

    /// The looks of a whole table, stored as the Windows client's code stores them.
    func testHeadingsLinesAndPapers() throws {
        var table = try XCTUnwrap(SamsungTable(binary: try fixture("table-2x3-windows.bin")))
        XCTAssertEqual(table.lines, .rounded)
        XCTAssertFalse(table.headingRow || table.headingColumn)
        XCTAssertEqual(table.paper(row: 0, column: 0), 0)

        table.setHeading(row: true)
        XCTAssertEqual(table.tableProps, [0x06])
        XCTAssertEqual(table.paper(row: 0, column: 2), 0xFFEE_EBE7)
        XCTAssertEqual(table.paper(row: 1, column: 0), 0)
        XCTAssertEqual(table.rows[0].map(\.bold), [true, true, true])
        XCTAssertEqual(table.rows[0].map(\.color), [0xFF3A_3A3D, 0xFF3A_3A3D, 0xFF3A_3A3D])
        XCTAssertEqual(table.rows[1].map(\.bold), [false, false, true], "the other rows are as they were")
        table.setHeading(column: true)
        XCTAssertEqual(table.tableProps, [0x07])
        XCTAssertEqual(table.paper(row: 1, column: 0), 0xFFEE_EBE7)

        // A paper for the whole table: every cell's own, and the heading's goes with it.
        table.setPaper(SamsungTable.papers[4])
        XCTAssertEqual(table.paper(row: 1, column: 1), 0xFFDA_ECFB)
        XCTAssertEqual(table.paper(row: 0, column: 1), 0xFFC5_E0F5)
        XCTAssertEqual(table.rows[0][1].color, 0xFF2F_528B)
        XCTAssertTrue(table.rows.allSatisfy { $0.allSatisfy(\.ownsBackground) })
        XCTAssertEqual(SamsungTable.heading(for: 0xFF80_4020), 0xFF7A_4021, "a colour of one's own: nine tenths of it and a tenth of a warm grey")

        var read = try XCTUnwrap(SamsungTable(binary: table.binary))
        XCTAssertEqual(read.binary, table.binary)
        XCTAssertTrue(read.headingRow && read.headingColumn)
        XCTAssertEqual(read.paper(row: 0, column: 1), 0xFFC5_E0F5)

        read.setHeading(row: false, column: false)
        XCTAssertEqual(read.tableProps, [0x04])
        XCTAssertEqual(read.rows[0].map(\.bold), [false, false, false])
        XCTAssertEqual(read.rows[0][0].color, 0xFF25_2525)
        XCTAssertEqual(read.paper(row: 0, column: 0), 0xFFDA_ECFB)

        // The five kinds of lines, each read back as the kind that was set.
        let left = table.rect.minX
        for kind in SamsungTable.Lines.allCases {
            read.setLines(kind)
            XCTAssertEqual(try XCTUnwrap(SamsungTable(binary: read.binary)).lines, kind)
            // The cells keep half the outer line's width from the table's edge, where it has one.
            let inset = read.cellRects[0][0].minX
            XCTAssertEqual(Double(inset), kind == .horizontal || kind == .none ? 0 : 0.15, accuracy: 0.001, "\(kind)")
            XCTAssertEqual(read.rect.minX, left, accuracy: 0.001)
        }
        XCTAssertEqual(SamsungTable.sides(read.border).map(\.width), [0, 0, 0, 0])
        read.setLines(.horizontal)
        XCTAssertEqual(SamsungTable.sides(read.cellBorder).map(\.width), [0, 0.3, 0, 0.3])
        read.setLines(.rounded)
        XCTAssertEqual(read.border, table.border, "back to what a new table has")
    }

    /// A line through the text is kept in four bytes where every other property has eight.
    func testStruckThroughTextIsWrittenShort() throws {
        var table = SamsungTable(rows: 1, columns: 1, pageWidth: 848, top: 100)
        table.change { $0.text = "gone"; $0.strikethrough = true; $0.underline = true }
        let read = try XCTUnwrap(SamsungTable(binary: table.binary))
        let record = try XCTUnwrap(read.rows[0][0].record)
        XCTAssertEqual(record.spans.first { $0.type == 20 }?.value, [1, 0, 0, 0])
        XCTAssertEqual(record.spans.first { $0.type == 7 }?.value, [1, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertTrue(read.rows[0][0].strikethrough && read.rows[0][0].underline)
        XCTAssertEqual(SamsungTable.most, 30)
    }
}
