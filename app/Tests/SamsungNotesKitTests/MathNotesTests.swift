import XCTest
@testable import SamsungNotesKit

final class MathNotesTests: XCTestCase {
    private func answer(_ text: String, _ variables: [String: Double] = [:]) -> String? {
        MathNotes.evaluate(text, variables: variables).map(MathNotes.format)
    }

    func testArithmeticIsDoneAsWritten() {
        XCTAssertEqual(answer("10+5"), "15")
        XCTAssertEqual(answer("2 + 3 × 4"), "14")
        XCTAssertEqual(answer("(2 + 3) * 4"), "20")
        XCTAssertEqual(answer("7 / 2"), "3.5")
        XCTAssertEqual(answer("10 ÷ 4 − 1"), "1.5")
        XCTAssertEqual(answer("2^10"), "1024")
        XCTAssertEqual(answer("2^3^2"), "512", "powers go from the right")
        XCTAssertEqual(answer("-3 + 5"), "2")
        XCTAssertEqual(answer("1/3"), "0.333333")
        XCTAssertEqual(answer("1,250 * 2"), "2500")
        XCTAssertEqual(answer("0.1 + 0.2"), "0.3")
        XCTAssertEqual(answer("5!"), "120")
        XCTAssertNil(answer("1/0"))
        XCTAssertNil(answer("2 +"))
        XCTAssertNil(answer("call mum"))
        XCTAssertNil(answer(""))
    }

    func testPerCentFunctionsAndNames() {
        XCTAssertEqual(answer("50%"), "0.5")
        XCTAssertEqual(answer("200 + 10%"), "220", "a tenth of the 200 is added")
        XCTAssertEqual(answer("200 - 25%"), "150")
        XCTAssertEqual(answer("15% * 240"), "36")
        XCTAssertEqual(answer("sqrt(16) + abs(-2)"), "6")
        XCTAssertEqual(answer("√9"), "3")
        XCTAssertEqual(answer("max(3, 7, 5) - min(3, 7)"), "4")
        XCTAssertEqual(answer("round(3.14159, 2)"), "3.14")
        XCTAssertEqual(answer("2 pi"), "6.283185")
        XCTAssertEqual(answer("2(3+4)"), "14")
        XCTAssertEqual(answer("width * 3", ["width": 12]), "36")
        XCTAssertNil(answer("height * 3", ["width": 12]))
    }

    func testOnlyWhatIsComputedIsAnswered() {
        XCTAssertTrue(MathNotes.isCalculation("10+5"))
        XCTAssertTrue(MathNotes.isCalculation("sqrt(2)"))
        XCTAssertTrue(MathNotes.isCalculation("x", variables: ["x": 5]))
        XCTAssertFalse(MathNotes.isCalculation("15"), "a number alone is not a calculation")
        XCTAssertFalse(MathNotes.isCalculation("Total"))
        XCTAssertFalse(MathNotes.isCalculation("10 +"))
    }

    func testLinesGiveNamesTheirValues() {
        let names = MathNotes.variables(in: ["Shopping", "width = 12", "area = width * 3 = 36", "note = buy milk", "pi = 4", "rate=7.5%"])
        XCTAssertEqual(names["width"], 12)
        XCTAssertEqual(names["area"], 36)
        XCTAssertNil(names["note"])
        XCTAssertNil(names["pi"], "a name the arithmetic has already is not given another value")
        XCTAssertEqual(names["rate"] ?? 0, 0.075, accuracy: 1e-12)
        XCTAssertEqual(answer("area / 2", names), "18")
    }
}
