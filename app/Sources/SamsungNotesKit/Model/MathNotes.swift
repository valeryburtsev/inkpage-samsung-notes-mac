import Foundation

/// Calculations written in a note: "10+5=" is answered where it stands. The arithmetic is
/// done here, exactly; what is written in words is first put into arithmetic by whoever
/// can read it (the app asks the system's language model), and then done here too.
public enum MathNotes {
    /// The value of an arithmetic expression, or nil when it is not one: numbers, + − × ÷ ^,
    /// brackets, per cent, the usual functions, and names given a value earlier in the note.
    public static func evaluate(_ expression: String, variables: [String: Double] = [:]) -> Double? {
        var parser = Parser(expression, variables: variables)
        guard let value = parser.sum(), parser.atEnd, value.isFinite else { return nil }
        return value
    }

    /// True for what is worth answering: something is computed in it (a sign, a function, a
    /// name with a value), not a number standing alone.
    public static func isCalculation(_ expression: String, variables: [String: Double] = [:]) -> Bool {
        var parser = Parser(expression, variables: variables)
        guard parser.sum() != nil, parser.atEnd else { return false }
        return parser.steps > 0
    }

    /// A result as it is written into the note: whole numbers whole, others to six places at most.
    public static func format(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if abs(value) < 1e15, abs(value - value.rounded()) < 1e-9 { return String(format: "%.0f", value.rounded()) }
        if abs(value) >= 1e15 || abs(value) < 1e-6 { return String(format: "%g", value) }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// The names the lines of a note give values to ("width = 12", "area = width * 3"), read
    /// from the top: a later line may use an earlier one's.
    public static func variables(in lines: [String]) -> [String: Double] {
        var known: [String: Double] = [:]
        for line in lines {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard isName(name), !reserved.contains(name.lowercased()) else { continue }
            // What follows the sign up to a second one: "x = 4 + 1 = 5" names 4 + 1.
            let rest = line[line.index(after: equals)...]
            let value = rest.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if let number = evaluate(value, variables: known) { known[name] = number }
        }
        return known
    }

    public static func isName(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, CharacterSet.letters.contains(first) || first == "_" else { return false }
        return text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
    }

    static let reserved: Set<String> = ["pi", "e", "sqrt", "cbrt", "abs", "sin", "cos", "tan", "asin", "acos", "atan", "ln", "log", "log2", "exp", "round", "floor", "ceil", "min", "max", "pow"]

    private struct Parser {
        let text: [Character]
        var at = 0
        let variables: [String: Double]
        /// How many things were computed: signs, functions, names looked up.
        var steps = 0
        /// The last operand read was a bare percentage ("10%"), for "200 + 10%".
        var percent = false

        init(_ expression: String, variables: [String: Double]) {
            text = Array(expression)
            self.variables = variables
        }

        var atEnd: Bool { mutating get { skip(); return at >= text.count } }

        mutating func skip() { while at < text.count, text[at] == " " || text[at] == "\u{00A0}" || text[at] == "\t" { at += 1 } }

        mutating func take(_ options: String) -> Character? {
            skip()
            guard at < text.count, options.contains(text[at]) else { return nil }
            at += 1
            return text[at - 1]
        }

        mutating func sum() -> Double? {
            guard var value = product() else { return nil }
            while let sign = take("+-−–") {
                percent = false
                guard let next = product() else { return nil }
                // "200 + 10%" adds a tenth of the 200, as a calculator does.
                let amount = percent ? value * next : next
                value = sign == "+" ? value + amount : value - amount
                steps += 1
                percent = false
            }
            return value
        }

        mutating func product() -> Double? {
            guard var value = power() else { return nil }
            while true {
                if let sign = take("*×·/÷:") {
                    guard let next = power() else { return nil }
                    if sign == "*" || sign == "×" || sign == "·" { value *= next } else { guard next != 0 else { return nil }; value /= next }
                    steps += 1
                    percent = false
                } else if next("(") || nextIsName {
                    // "2(3+4)", "2 pi": written side by side is multiplied.
                    guard let other = power() else { return nil }
                    value *= other
                    steps += 1
                    percent = false
                } else {
                    return value
                }
            }
        }

        mutating func next(_ character: Character) -> Bool { skip(); return at < text.count && text[at] == character }
        var nextIsName: Bool { mutating get { skip(); return at < text.count && (text[at].isLetter || text[at] == "_" || text[at] == "π" || text[at] == "√") } }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if take("^") != nil {
                guard let exponent = power() else { return nil }
                steps += 1
                percent = false
                return pow(base, exponent)
            }
            return base
        }

        mutating func unary() -> Double? {
            if take("-−–") != nil { return unary().map { -$0 } }
            if take("+") != nil { return unary() }
            guard var value = atom() else { return nil }
            percent = false
            while take("%") != nil { value /= 100; percent = true; steps += 1 }
            if take("!") != nil {
                guard value >= 0, value <= 170, value == value.rounded() else { return nil }
                value = (1...max(Int(value), 1)).reduce(1.0) { $0 * Double($1) }
                steps += 1
            }
            return value
        }

        mutating func atom() -> Double? {
            skip()
            guard at < text.count else { return nil }
            let character = text[at]
            if character == "(" {
                at += 1
                guard let value = sum(), take(")") != nil else { return nil }
                return value
            }
            if character == "√" {
                at += 1
                steps += 1
                return unary().flatMap { $0 >= 0 ? $0.squareRoot() : nil }
            }
            if character.isNumber || character == "." { return number() }
            if character.isLetter || character == "_" || character == "π" { return named() }
            return nil
        }

        mutating func number() -> Double? {
            var digits = ""
            while at < text.count {
                let character = text[at]
                if character.isASCII, character.isNumber || character == "." {
                    digits.append(character)
                } else if character == ",", at + 3 < text.count + 0, digits.count >= 1, digits.count <= 3 || digits.contains(","),
                          text[(at + 1)...].prefix(3).count == 3, text[(at + 1)...].prefix(3).allSatisfy({ $0.isASCII && $0.isNumber }),
                          !(at + 4 < text.count && text[at + 4].isASCII && text[at + 4].isNumber) {
                    // A comma before a group of three digits sets thousands apart.
                    digits.append(character)
                } else {
                    break
                }
                at += 1
            }
            return Double(digits.replacingOccurrences(of: ",", with: ""))
        }

        mutating func named() -> Double? {
            var name = ""
            while at < text.count, text[at].isLetter || text[at].isNumber || text[at] == "_" || text[at] == "π" { name.append(text[at]); at += 1 }
            let lower = name.lowercased()
            if next("(") {
                at += 1
                var arguments: [Double] = []
                if !next(")") {
                    repeat { guard let value = sum() else { return nil }; arguments.append(value) } while take(",;") != nil
                }
                guard take(")") != nil else { return nil }
                steps += 1
                return apply(lower, arguments)
            }
            if let value = variables[name] { steps += 1; return value }
            switch lower {
            case "pi", "π": steps += 1; return .pi
            case "e": steps += 1; return M_E
            default: return nil
            }
        }

        func apply(_ name: String, _ arguments: [Double]) -> Double? {
            if let x = arguments.first, arguments.count == 1 {
                switch name {
                case "sqrt": return x >= 0 ? x.squareRoot() : nil
                case "cbrt": return cbrt(x)
                case "abs": return abs(x)
                case "sin": return sin(x)
                case "cos": return cos(x)
                case "tan": return tan(x)
                case "asin": return asin(x)
                case "acos": return acos(x)
                case "atan": return atan(x)
                case "ln": return x > 0 ? log(x) : nil
                case "log": return x > 0 ? log10(x) : nil
                case "log2": return x > 0 ? log2(x) : nil
                case "exp": return exp(x)
                case "round": return x.rounded()
                case "floor": return x.rounded(.down)
                case "ceil": return x.rounded(.up)
                default: break
                }
            }
            switch name {
            case "min": return arguments.min()
            case "max": return arguments.max()
            case "pow": return arguments.count == 2 ? pow(arguments[0], arguments[1]) : nil
            case "round": return arguments.count == 2 ? (arguments[0] * pow(10, arguments[1])).rounded() / pow(10, arguments[1]) : nil
            default: return nil
            }
        }
    }
}
