import CoreGraphics
import Foundation
import XCTest

@testable import SamsungNotesKit

final class StrokeDecoderTests: XCTestCase {
    private static let phoneIDs = [
        "9aac3664-c50b-11f1-8cc5-f3e90122fd91",
        "9c66f836-c50b-11f1-83d7-dbbfc8a98c7d",
    ]
    private static let windowsIDs = [
        "d327c070-c50c-11f1-8147-0382a824b25c",
        "d6f81de4-c50c-11f1-ae1d-435558a63b11",
        "d8a89c40-c50c-11f1-90b5-bf78f04793cc",
    ]
    private static var allIDs: [String] { phoneIDs + windowsIDs }

    private func fixtureData(_ id: String) throws -> Data {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try Data(contentsOf: fixtures.appendingPathComponent("strokes/\(id).bin"))
    }

    private func argb(fromSigned value: Int32) -> UInt32 { UInt32(bitPattern: value) }

    func testDecodesAllFixtures() throws {
        for id in Self.allIDs {
            let stroke = try StrokeDecoder.decode(try fixtureData(id))
            XCTAssertEqual(stroke.id, id)
            XCTAssertGreaterThan(stroke.points.count, 1, id)

            let bounds = stroke.bounds
            XCTAssertFalse(bounds.isNull, id)
            let inflated = bounds.insetBy(dx: -2, dy: -2)
            for point in stroke.points {
                XCTAssertTrue(
                    inflated.contains(CGPoint(x: point.x, y: point.y)),
                    "\(id): point (\(point.x), \(point.y)) outside \(bounds)")
            }

            let xs = stroke.points.map(\.x)
            let ys = stroke.points.map(\.y)
            let width = (xs.max() ?? 0) - (xs.min() ?? 0)
            let height = (ys.max() ?? 0) - (ys.min() ?? 0)
            if bounds.width > 5 {
                XCTAssertGreaterThanOrEqual(width, Double(bounds.width) * 0.95, "\(id): width coverage")
            }
            if bounds.height > 5 {
                XCTAssertGreaterThanOrEqual(height, Double(bounds.height) * 0.95, "\(id): height coverage")
            }
        }
    }

    func testPointCounts() throws {
        let expected = [76, 20, 450, 244, 332]
        for (id, count) in zip(Self.allIDs, expected) {
            XCTAssertEqual(try StrokeDecoder.decode(try fixtureData(id)).points.count, count, id)
        }
    }

    func testPhoneStrokeStyleMatchesPenInfo() throws {
        // penInfo color="-15448065" size="7.6499996", stringIdList id 0 = FountainPen.
        let expected = argb(fromSigned: -15_448_065)
        XCTAssertEqual(expected, 0xFF14_47FF)
        for id in Self.phoneIDs {
            let stroke = try StrokeDecoder.decode(try fixtureData(id))
            XCTAssertEqual(stroke.argb, expected, id)
            XCTAssertEqual(stroke.penSize, 7.6499996, accuracy: 1e-4, id)
            XCTAssertEqual(stroke.penNameID, 0, id)
            XCTAssertNil(stroke.penName, id)
        }
    }

    func testWindowsStrokeStyleMatchesPenInfo() throws {
        // penInfo color="-51658" size="6.00666618".
        let expected = argb(fromSigned: -51_658)
        XCTAssertEqual(expected, 0xFFFF_3636)
        for id in Self.windowsIDs {
            let stroke = try StrokeDecoder.decode(try fixtureData(id))
            XCTAssertEqual(stroke.argb, expected, id)
            XCTAssertEqual(stroke.penSize, 6.00666618, accuracy: 1e-4, id)
            XCTAssertEqual(stroke.penNameID, 0, id)
            // Mouse input stores a constant pressure of 1 and millisecond timestamps.
            XCTAssertTrue(stroke.points.allSatisfy { $0.pressure == 1 }, id)
            XCTAssertEqual(stroke.points.first?.time, 0, id)
            let times = stroke.points.compactMap(\.time)
            XCTAssertEqual(times.count, stroke.points.count, id)
            XCTAssertEqual(times, times.sorted(), "\(id): timestamps should not go backwards")
            XCTAssertGreaterThan(times.last ?? 0, 500, id)
        }
    }

    func testKnownFirstPoint() throws {
        let stroke = try StrokeDecoder.decode(try fixtureData(Self.phoneIDs[1]))
        XCTAssertEqual(stroke.bounds, CGRect(x: 218, y: 438, width: 597, height: 55))
        XCTAssertEqual(stroke.points.first, InkPoint(x: 218, y: 493, pressure: 0, time: 0))
        XCTAssertEqual(stroke.points[1].x, 220, accuracy: 1e-9)
        XCTAssertEqual(stroke.points.last?.y ?? 0, 438, accuracy: 1e-9)
    }

    func testMalformedInputThrowsInsteadOfCrashing() throws {
        XCTAssertThrowsError(try StrokeDecoder.decode(Data()))
        XCTAssertThrowsError(try StrokeDecoder.decode(Data([0xFF, 0xFF, 0xFF, 0xFF])))
        XCTAssertThrowsError(try StrokeDecoder.decode(Data(repeating: 0xFF, count: 512)))
        XCTAssertThrowsError(try StrokeDecoder.decode(Data(repeating: 0x00, count: 512)))

        let data = try fixtureData(Self.phoneIDs[1])
        // Every truncation either throws or yields a stroke; none may trap. Slices with a
        // non-zero start index exercise Data's index handling as well.
        for length in 0..<data.count {
            _ = try? StrokeDecoder.decode(data.prefix(length))
            _ = try? StrokeDecoder.decode(data.suffix(length))
        }
        // The stroke frame is cut short, so its declared size no longer fits.
        XCTAssertThrowsError(try StrokeDecoder.decode(data.prefix(200)))

        // Deterministic corruption: overwrite each byte in turn with hostile values.
        for index in 0..<data.count {
            for value: UInt8 in [0x00, 0x7F, 0xFF] {
                var corrupted = data
                corrupted[index] = value
                if let stroke = try? StrokeDecoder.decode(corrupted) {
                    XCTAssertLessThanOrEqual(stroke.points.count, Int(UInt16.max))
                }
            }
        }
    }

    func testRendererDrawsInk() throws {
        let stroke = try StrokeDecoder.decode(try fixtureData(Self.phoneIDs[0]))
        let width = 200, height = 200
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drewInk: Bool = try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            // y-down page space, scaled so the stroke's bounds fill the bitmap.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            let scale = min(CGFloat(width) / stroke.bounds.maxX, CGFloat(height) / stroke.bounds.maxY)
            context.scaleBy(x: scale, y: scale)
            InkRenderer.draw(stroke, in: context)
            context.flush()
            return buffer.contains { $0 != 0 }
        }
        XCTAssertTrue(drewInk)

        let path = InkRenderer.path(for: stroke)
        XCTAssertFalse(path.isEmpty)
        XCTAssertTrue(stroke.bounds.insetBy(dx: -1, dy: -1).contains(path.boundingBoxOfPath))

        // Degenerate strokes must not trap.
        var empty = stroke
        empty.points = []
        XCTAssertTrue(InkRenderer.path(for: empty).isEmpty)
        var marker = stroke
        marker.penName = "com.samsung.android.sdk.pen.pen.preload.Marker"
        marker.points = Array(stroke.points.prefix(1))
        let scratch = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        InkRenderer.draw(empty, in: scratch)
        InkRenderer.draw(marker, in: scratch)
    }
}
