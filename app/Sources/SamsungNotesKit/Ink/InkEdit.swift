import CoreGraphics
import Foundation

/// Changes to strokes that are made of their points: cutting a part away, straightening.
public enum InkEdit {
    /// What is left of a stroke's points when a disc is rubbed out of it: the runs of points
    /// outside the disc, each ending where the stroke meets the disc's edge. Nil when the disc
    /// does not touch the stroke; empty when nothing is left.
    public static func cut(_ points: [InkPoint], centre: CGPoint, radius: Double) -> [[InkPoint]]? {
        guard radius > 0, !points.isEmpty else { return nil }
        func inside(_ point: InkPoint) -> Bool { hypot(point.x - centre.x, point.y - centre.y) <= radius }
        // Points far apart (a straight line is two) are filled in first, so that a disc between them is not missed.
        let step = max(radius / 2, 0.5)
        var dense: [InkPoint] = []
        for (index, point) in points.enumerated() {
            if index > 0 {
                let before = points[index - 1]
                let gap = hypot(point.x - before.x, point.y - before.y)
                if gap > step {
                    let count = min(Int(gap / step), 4_000)
                    for part in 1...max(count, 1) where Double(part) < Double(count + 1) {
                        let share = Double(part) / Double(count + 1)
                        dense.append(InkPoint(x: before.x + (point.x - before.x) * share, y: before.y + (point.y - before.y) * share,
                                              pressure: before.pressure + (point.pressure - before.pressure) * share,
                                              time: before.time.flatMap { from in point.time.map { from + Int(Double($0 - from) * share) } }))
                    }
                }
            }
            dense.append(point)
        }
        guard dense.contains(where: inside) else { return nil }
        /// Where the way from a point outside to one inside crosses the disc's edge.
        func edge(_ outer: InkPoint, _ inner: InkPoint) -> InkPoint {
            var low = 0.0, high = 1.0
            for _ in 0..<18 {
                let middle = (low + high) / 2
                let x = outer.x + (inner.x - outer.x) * middle, y = outer.y + (inner.y - outer.y) * middle
                if hypot(x - centre.x, y - centre.y) <= radius { high = middle } else { low = middle }
            }
            return InkPoint(x: outer.x + (inner.x - outer.x) * low, y: outer.y + (inner.y - outer.y) * low,
                            pressure: outer.pressure + (inner.pressure - outer.pressure) * low, time: outer.time)
        }
        var pieces: [[InkPoint]] = []
        var run: [InkPoint] = []
        for (index, point) in dense.enumerated() {
            if inside(point) {
                if !run.isEmpty {
                    run.append(edge(dense[index - 1], point))
                    pieces.append(run)
                    run = []
                }
            } else {
                if run.isEmpty, index > 0, inside(dense[index - 1]) { run.append(edge(point, dense[index - 1])) }
                run.append(point)
            }
        }
        if !run.isEmpty { pieces.append(run) }
        // A piece shorter than the line is wide is a crumb, and goes.
        return pieces.filter { piece in
            guard piece.count >= 2, let first = piece.first, let last = piece.last else { return false }
            let length = zip(piece, piece.dropFirst()).reduce(0.0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            return length > 0.75 || hypot(last.x - first.x, last.y - first.y) > 0.75
        }
    }

    /// A stroke's points as a straight line from where it began to where it ended, as the
    /// Windows client makes one ("Straighten lines"): a point for every hundredth of the
    /// page's lesser side, five steps at the least, at half pressure, with times that slow
    /// toward the end as the client's do.
    public static func straightened(_ points: [InkPoint], pageWidth: Double, pageHeight: Double) -> [InkPoint] {
        guard let first = points.first, let last = points.last, points.count > 1 else { return points }
        let length = hypot(last.x - first.x, last.y - first.y)
        let unit = max(min(pageWidth, pageHeight) / 100, 0.5)
        let count = min(max(Int(length / unit), 5), 4_000)
        return (0...count).map { index in
            let share = Double(index) / Double(count)
            let time = Int(log(Double(index + 1)) / log(Double(count + 1)) * Double(count) * 6)
            return InkPoint(x: first.x + (last.x - first.x) * share, y: first.y + (last.y - first.y) * share, pressure: 0.5, time: time)
        }
    }
}
