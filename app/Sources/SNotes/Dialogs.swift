import AppKit

/// Questions asked before something that cannot be taken back, on the window in front.
@MainActor
enum Dialogs {
    static func confirm(title: String, message: String, action: String, destructive: Bool = true, then work: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action).hasDestructiveAction = destructive
        alert.addButton(withTitle: String(localized: "Cancel"))
        if let window = host {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { if response == .alertFirstButtonReturn { work() } }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            work()
        }
    }

    /// Asks for a name. Used where there is no place to type it in the window itself.
    static func askName(title: String, value: String, placeholder: String, action: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func inform(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window = host { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// The window a sheet belongs on: the one in front, unless it is a panel or already has a sheet.
    static var host: NSWindow? {
        func fits(_ window: NSWindow?) -> Bool {
            guard let window else { return false }
            return window.isVisible && !window.isMiniaturized && !(window is NSPanel) && window.styleMask.contains(.titled) && window.attachedSheet == nil && !window.isSheet
        }
        for window in [NSApp.keyWindow, NSApp.mainWindow] where fits(window) { return window }
        // With the app in the background no window is "in front": the notes window is the place then.
        let open = NSApp.orderedWindows.filter(fits)
        return open.first { $0.identifier?.rawValue.hasPrefix("main") == true } ?? open.first
    }
}
