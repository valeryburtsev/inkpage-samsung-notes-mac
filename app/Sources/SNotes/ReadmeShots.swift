import AppKit
import SamsungNotesKit

extension EditorChecks {
    /// Development aid: `--editor-check=<out> --readme-only` with an empty `--store=<folder>` fills that
    /// library with made-up notes and saves the README's pictures of them. Nothing in it is anyone's own.
    @MainActor static func readmeShots(model: AppModel, shot: @MainActor (String) async -> Void) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        let edits = model.edits
        model.mathResults = true

        // Typed notes.
        let notes: [(String, String)] = [
            ("Lemon cake", "200 g flour\n150 g sugar\n3 eggs\nZest and juice of two lemons\nBake 35 minutes at 180 °C"),
            ("Trip to Lisbon", "Flights on 12 May, back on the 18th\nPack: camera, charger, a light jacket\nTram 28 early in the morning\nPastéis de nata in Belém"),
            ("Weekly plan", "Monday: call the bank\nTuesday: dentist at 10\nWednesday: finish the slides\nFriday: dinner with friends"),
            ("Reading list", "The Left Hand of Darkness\nA Psalm for the Wild-Built\nPiranesi\nThe Dispossessed"),
        ]
        for (title, body) in notes { _ = try? edits.createTextNote(title: title, body: body) }

        // A sketch, in several pens.
        func curve(_ count: Int, _ point: (Double) -> CGPoint) -> [InkPoint] {
            (0...count).map { index in
                let t = Double(index) / Double(count)
                let at = point(t)
                return InkPoint(x: at.x, y: at.y, pressure: 0.55 + 0.4 * sin(t * .pi), time: index * 12)
            }
        }
        let sketch = try? edits.createTextNote(title: "Garden ideas", body: "")
        if let sketch {
            let size = LocalEdits.standardPenSize(pageWidth: 848)
            var strokes: [NewStroke] = []
            // A sun.
            strokes.append(NewStroke(points: curve(60) { t in CGPoint(x: 640 + 60 * cos(t * 2 * .pi), y: 170 + 60 * sin(t * 2 * .pi)) }, argb: 0xFFFF_B426, penSize: size * 1.6, pen: .fountain))
            for ray in 0..<8 {
                let angle = Double(ray) / 8 * 2 * .pi
                strokes.append(NewStroke(points: curve(8) { t in CGPoint(x: 640 + (80 + 30 * t) * cos(angle), y: 170 + (80 + 30 * t) * sin(angle)) }, argb: 0xFFFF_B426, penSize: size * 1.3, pen: .fountain))
            }
            // Three flowers on stems.
            for (index, x) in [180.0, 330.0, 480.0].enumerated() {
                let colors: [UInt32] = [0xFFFF_3636, 0xFF99_33FF, 0xFF33_96FF]
                strokes.append(NewStroke(points: curve(30) { t in CGPoint(x: x + 8 * sin(t * 3), y: 560 - 250 * t) }, argb: 0xFF37_D366, penSize: size * 1.2, pen: .fountain))
                strokes.append(NewStroke(points: curve(80) { t in
                    let angle = t * 2 * .pi, radius = 34 + 14 * cos(5 * angle)
                    return CGPoint(x: x + radius * cos(angle), y: 290 + radius * sin(angle))
                }, argb: colors[index], penSize: size * 1.4, pen: .fountain))
                strokes.append(NewStroke(points: curve(20) { t in CGPoint(x: x + 30 * t, y: 470 - 25 * sin(t * .pi)) }, argb: 0xFF37_D366, penSize: size, pen: .fountain))
            }
            // The ground, with the pencil, and a highlighted note to self.
            strokes.append(NewStroke(points: curve(60) { t in CGPoint(x: 110 + 520 * t, y: 565 + 6 * sin(t * 18)) }, argb: 0xFF67_6767, penSize: size, pen: .pencil))
            strokes.append(NewStroke(points: curve(20) { t in CGPoint(x: 110 + 300 * t, y: 650) }, argb: Pen.highlighter.ink(0xFFFF_F400), penSize: 26, pen: .highlighter))
            _ = try? edits.addStrokes(sketch, page: 0, strokes: strokes)
        }

        // A PDF, made here, written on.
        let pdfData = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        if let consumer = CGDataConsumer(data: pdfData as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) {
            for page in 0..<2 {
                context.beginPDFPage(nil)
                let graphics = NSGraphicsContext(cgContext: context, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphics
                let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26, weight: .bold)]
                let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.darkGray]
                (page == 0 ? "Field trip: the river valley" : "Notes for the second day").draw(at: CGPoint(x: 64, y: 700), withAttributes: heading)
                let lines = ["Meet at the station at 8:30.", "Bring water, a hat and good shoes.", "We walk about 9 km, with a stop for lunch by the old mill.",
                             "Look for herons near the bridge.", "The bus back leaves at 17:10."]
                for (index, line) in lines.enumerated() { line.draw(at: CGPoint(x: 64, y: 650 - CGFloat(index) * 26), withAttributes: body) }
                NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
                NSBezierPath(roundedRect: CGRect(x: 64, y: 260, width: 484, height: 200), xRadius: 8, yRadius: 8).fill()
                "Map".draw(at: CGPoint(x: 290, y: 352), withAttributes: body)
                NSGraphicsContext.restoreGraphicsState()
                context.endPDFPage()
            }
            context.closePDF()
        }
        if let pdf = try? edits.createPDFNote(title: "Field trip", pdf: pdfData as Data) {
            let size = LocalEdits.standardPenSize(pageWidth: 848)
            let ring = NewStroke(points: curve(70) { t in CGPoint(x: 330 + 270 * cos(t * 2.1 * .pi - 0.3), y: 120 + 42 * sin(t * 2.1 * .pi - 0.3)) }, argb: 0xFFFF_3636, penSize: size * 1.2, pen: .fountain)
            let underline = NewStroke(points: curve(20) { t in CGPoint(x: 92 + 330 * t, y: 302) }, argb: Pen.highlighter.ink(0xFF2F_EBD2), penSize: 24, pen: .highlighter)
            _ = try? edits.addStrokes(pdf, page: 0, strokes: [ring, underline])
        }

        model.changed(sync: false)
        model.path = []
        model.section = .all
        model.gridStyle = .grid
        await pause(2500)
        await shot("list")

        // The budget, typed in the note: the sums are answered where they stand.
        let budget = try? edits.createTextNote(title: "Budget", body: "")
        model.changed(sync: false)
        if let budget { model.open(budget) }
        await pause(2000)
        if let id = model.path.last, let session = NoteSession.live.object(forKey: id as NSString), let view = session.text.view {
            NSApplication.shared.activate(ignoringOtherApps: true)
            view.window?.makeKeyAndOrderFront(nil)
            view.window?.makeFirstResponder(view)
            await pause(300)
            for character in "Rent = 1200\nFood = 450\nTravel = 180\nRent + Food + Travel=\n15% of 1830=" { view.insertText(String(character), replacementRange: view.selectedRange()); await pause(8) }
            await pause(1500)
            EditorRemote.shared.drawing = false
            EditorRemote.shared.panel = true
            await pause(900)
            await shot("calculations")
            EditorRemote.shared.panel = false
        }

        // The sketch, with the pens' panel open.
        if let sketch {
            model.path = []
            await pause(600)
            model.open(sketch)
            await pause(2000)
            EditorRemote.shared.tool = .pen
            EditorRemote.shared.panel = true
            await pause(1200)
            await shot("drawing")
            EditorRemote.shared.panel = false
            EditorRemote.shared.drawing = false
        }

        // The PDF, with its pages at the side and a sticky note on it.
        if let pdf = model.library.notes.values.first(where: { $0.title == "Field trip" })?.id {
            model.path = []
            await pause(600)
            model.open(pdf)
            await pause(2200)
            if let session = NoteSession.live.object(forKey: pdf as NSString) { _ = session.addSticky(page: 0, text: "Ask about the bus times", paper: StickyDocument.papers[0]) }
            EditorRemote.shared.drawing = false
            EditorRemote.shared.pages = true
            await pause(2200)
            await shot("pdf")
            EditorRemote.shared.pages = false
        }

        // The list again, in the dark.
        model.path = []
        model.appearance = .dark
        await pause(2000)
        await shot("list-dark")
        model.appearance = .light
    }
}
