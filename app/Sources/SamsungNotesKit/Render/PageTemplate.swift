import CoreGraphics
import Foundation

/// The ruled papers a page can have: lines, squares and dots in three widths, a to-do list, a
/// ruled page with a margin, a week, a month and music paper. They are drawn here, never stored
/// as pictures, with the measures Samsung's engine draws its own with (read from its code, see
/// `protocol/sync-protocol.md` 5.18), so that a page looks the same here as on a Galaxy device.
public enum PageTemplate: String, CaseIterable, Sendable, Identifiable {
    case blank
    case lineNarrow, lineMedium, lineWide
    case gridNarrow, gridMedium, gridWide
    case dotNarrow, dotMedium, dotWide
    case todo, oxford, weekly, monthly, manuscript

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .blank: return "Blank"
        case .lineNarrow: return "Narrow lines"
        case .lineMedium: return "Medium lines"
        case .lineWide: return "Wide lines"
        case .gridNarrow: return "Small squares"
        case .gridMedium: return "Medium squares"
        case .gridWide: return "Large squares"
        case .dotNarrow: return "Close dots"
        case .dotMedium: return "Medium dots"
        case .dotWide: return "Wide dots"
        case .todo: return "To-do list"
        case .oxford: return "Ruled with margin"
        case .weekly: return "Week"
        case .monthly: return "Month"
        case .manuscript: return "Music paper"
        }
    }

    /// From one row to the next, in units of text size (a page is 360 of them wide): the
    /// engine's whole-number cell times 1.35. The narrow lines and the ruled page with a margin
    /// are about the height of a line of ordinary text.
    public var pitch: Double {
        switch self {
        case .lineNarrow, .gridNarrow, .dotNarrow: return 12 * 1.35
        case .lineMedium, .gridMedium, .dotMedium: return 17 * 1.35
        case .lineWide, .gridWide, .dotWide: return 28 * 1.35
        case .todo: return 26 * 1.35
        case .oxford: return 11 * 1.35
        default: return 0
        }
    }

    /// Draws the paper's ruling over a page. `page` is the page's rectangle in a context whose
    /// y points down. Every measure is in units of text size, 360 to the page's width, and the
    /// ruling starts anew on every page.
    public func draw(in context: CGContext, page: CGRect, dark: Bool) {
        guard self != .blank, page.width > 1, page.height > 1, page.width.isFinite, page.height.isFinite else { return }
        let unit = page.width / 360
        let width = 360.0, height = page.height / unit
        context.saveGState()
        context.clip(to: page)
        context.translateBy(x: page.minX, y: page.minY)
        context.scaleBy(x: unit, y: unit)
        // A line is half a unit wide, and never thinner than one pixel of what it is drawn on.
        let transform = context.ctm
        let pixel = 1 / max(sqrt(abs(transform.a * transform.d - transform.b * transform.c)), 0.0001)
        func line(_ units: Double) -> CGFloat { max(units, pixel) }
        func ink(_ alpha: Double) -> CGColor {
            dark ? CGColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: alpha) : CGColor(srgbRed: 0.004, green: 0.004, blue: 0.008, alpha: alpha)
        }
        let ruling = ink(dark ? 0.3 : 0.2)
        context.setStrokeColor(ruling)
        context.setFillColor(ink(0.2))
        context.setLineWidth(line(0.5))
        func horizontal(_ y: Double, from: Double = 0, to: Double = 360) { context.move(to: CGPoint(x: from, y: y)); context.addLine(to: CGPoint(x: to, y: y)) }
        func vertical(_ x: Double, from: Double = 0, to: Double? = nil) { context.move(to: CGPoint(x: x, y: from)); context.addLine(to: CGPoint(x: x, y: to ?? height)) }
        // The rows of the rulings that repeat down the page begin ten units from its top, where the text does.
        let top = 10.0
        let step = pitch
        func rows(_ body: (Double) -> Void) {
            guard step > 0.5 else { return }
            var y = top
            var count = 0
            while y < height, count < 4_000 { body(y); y += step; count += 1 }
        }
        switch self {
        case .blank:
            break
        case .lineNarrow, .lineMedium, .lineWide:
            rows { horizontal($0) }
            context.strokePath()
        case .gridNarrow, .gridMedium, .gridWide:
            rows { horizontal($0) }
            var x = 0.0
            while x <= width { vertical(x, from: top); x += step }
            context.strokePath()
        case .dotNarrow, .dotMedium, .dotWide:
            // Dots two units across, a unit below each row's top; across the page they stand a
            // unit and a half further apart than the rows do.
            rows { y in
                var x = 0.0
                while x <= width + 1 {
                    context.addEllipse(in: CGRect(x: x - 1, y: y, width: 2, height: 2))
                    x += step + 1.5
                }
            }
            context.fillPath()
        case .todo:
            rows { y in
                horizontal(y)
                // A box to tick in each row, in the middle of its height.
                if y + step <= height + 1 { context.addPath(CGPath(roundedRect: CGRect(x: 16, y: y + (step - 14) / 2, width: 14, height: 14), cornerWidth: 1, cornerHeight: 1, transform: nil)) }
            }
            context.strokePath()
        case .oxford:
            rows { horizontal($0) }
            context.strokePath()
            context.setStrokeColor(CGColor(srgbRed: 1, green: 0.6, blue: 0.6, alpha: 1))
            vertical(53)
            vertical(56)
            context.strokePath()
        case .weekly:
            // A column for the days' names, and a row for each day.
            context.setLineWidth(line(1))
            var y = 27.0
            while y < height { horizontal(y); y += 68.4 }
            vertical(52, from: 27)
            context.strokePath()
        case .monthly:
            // A line for the month's name, a band for the days of the week, and the weeks.
            context.setLineWidth(line(1.5))
            context.setStrokeColor(ink(0.7))
            horizontal(65.3, from: 121.5, to: 238.5)
            horizontal(86.4)
            context.strokePath()
            context.setStrokeColor(ruling)
            var y = 107.6
            while y < height { horizontal(y); y += 80.11 }
            var x = 51.3
            while x < width { vertical(x, from: 86.9); x += 51.3 }
            context.strokePath()
        case .manuscript:
            // Music paper: a line for the title, then staves of five lines.
            context.setLineWidth(line(1.5))
            context.setStrokeColor(ink(1))
            horizontal(38.7, from: 90, to: 270)
            context.strokePath()
            context.setLineWidth(line(0.2))
            context.setStrokeColor(ink(0.7))
            var staff = 62.1
            while staff + 15.6 < height {
                for index in 0..<5 { horizontal(staff + Double(index) * 3.9, from: 22.5, to: 337.5) }
                staff += 39.3
            }
            context.strokePath()
        }
        context.restoreGState()
    }
}

/// The paper colours of the original's note style panel, row by row; the first is the plain page.
public enum PaperColors {
    public static let plain: UInt32 = 0xFFFC_FCFC
    /// The eighteen the Windows client offers in a note's style panel, in its order (read from its code).
    public static let all: [(name: String, argb: UInt32)] = [
        ("Plain", plain), ("Light grey", 0xFFE6_E6E6), ("Peach", 0xFFF4_E4D7), ("Pale pink", 0xFFF5_E4E4), ("Pale teal", 0xFFCB_DADD), ("Black", black),
        ("Orange", 0xFFFF_C69E), ("Yellow", 0xFFFF_EC94), ("Mint", 0xFFC8_F0E7), ("Light blue", 0xFFCA_E1FA), ("Lavender", 0xFFE5_DCF9), ("Pink", 0xFFFF_CACD),
        ("Salmon", 0xFFF0_CABD), ("Teal", 0xFFA7_C9CC), ("Slate", 0xFFB0_B2C8), ("Green", 0xFF77_B68E), ("Blue", 0xFF64_91AF), ("Rose", 0xFFCE_9192),
    ]
    /// The clients' black paper is a shade off pure black.
    public static let black: UInt32 = 0xFF01_0101
}
