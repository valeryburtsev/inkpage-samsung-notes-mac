import AppKit
import SamsungNotesKit

/// Samsung Cloud sync is unofficial: before it is turned on, the person turning it on reads what
/// that means and accepts it, with a tick, every time the wording changes. Without that it stays off.
@MainActor
enum SamsungRisks {
    private static let key = "samsungRisksAccepted"

    /// The version of the wording accepted on this Mac, and when; nil when none was.
    static var accepted: (version: Int, at: Date)? {
        guard let stored = UserDefaults.standard.dictionary(forKey: key), let version = stored["version"] as? Int, let at = stored["at"] as? Date else { return nil }
        return (version, at)
    }

    static var isAccepted: Bool {
        // Scripted checks and the demo talk to no real Samsung server.
        if Launch.value("--editor-check") != nil || Launch.value("--window-snapshot") != nil { return true }
        return (accepted?.version ?? 0) >= TermsOfUse.samsungRisksVersion
    }

    /// Asks, unless it was accepted already. `then` runs only when it is.
    static func confirm(then: @escaping @MainActor () -> Void) {
        if isAccepted { then(); return }
        if ask(accepting: true) {
            UserDefaults.standard.set(["version": TermsOfUse.samsungRisksVersion, "at": Date()], forKey: key)
            then()
        }
    }

    /// Shows what was accepted, to read again; nothing changes.
    static func show() { _ = ask(accepting: false) }

    /// Taking back what was accepted: the next time Samsung Cloud sync is turned on, it is asked again.
    static func forget() { UserDefaults.standard.removeObject(forKey: key) }

    private final class Tick: NSObject {
        weak var button: NSButton?
        @objc func changed(_ sender: NSButton) { button?.isEnabled = sender.state == .on }
    }

    /// The dialog. With `accepting`, the button that turns sync on is enabled only once the box is ticked.
    private static func ask(accepting: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Samsung Cloud sync is experimental and unofficial")
        alert.informativeText = String(localized: "Read this before you turn it on.")
        let points = TermsOfUse.samsungRisks.map { "•  " + $0 }.joined(separator: "\n\n")
        let text = NSTextField(wrappingLabelWithString: points)
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        text.preferredMaxLayoutWidth = 380
        text.setAccessibilityLabel(String(localized: "The risks of Samsung Cloud sync"))
        let stack = NSStackView(views: [text])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        let tick = Tick()
        var box: NSButton?
        if accepting {
            let check = NSButton(checkboxWithTitle: String(localized: "I have read this, and I use Samsung Cloud sync at my own risk"), target: tick, action: #selector(Tick.changed(_:)))
            stack.addArrangedSubview(check)
            box = check
            alert.addButton(withTitle: String(localized: "Turn On Samsung Cloud Sync"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.buttons[0].isEnabled = false
            tick.button = alert.buttons[0]
        } else {
            if let accepted { stack.addArrangedSubview(NSTextField(labelWithString: String(localized: "You accepted this on \(accepted.at.formatted(date: .long, time: .shortened))."))) }
            alert.addButton(withTitle: String(localized: "OK"))
        }
        let size = stack.fittingSize
        stack.frame = NSRect(x: 0, y: 0, width: max(size.width, 380), height: size.height)
        alert.accessoryView = stack
        let answer = withExtendedLifetime(tick) { alert.runModal() }
        return accepting && answer == .alertFirstButtonReturn && box?.state == .on
    }
}
