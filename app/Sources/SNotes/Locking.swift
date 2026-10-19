import AppKit
import LocalAuthentication
import SamsungNotesKit
import SwiftUI

/// Locked notes. Samsung's lock is not encryption: a locked note comes from the service like
/// any other, marked as locked, and every client asks who is there before it shows the note.
/// Samsung's clients ask for the account's notes password; this Mac asks for Touch ID (which
/// falls back to the Mac's own password). The notes password itself can be changed from here,
/// for the other devices: that is the one place it is typed.
extension AppModel {
    /// Reads the notes password's verifier and the account's mark from the keychain.
    func refreshLock() async {
        lockPasscode = await account.passcode
        lockOwner = await account.lockOwner
    }

    /// True once a password typed here was accepted by a verifier made on another device: this
    /// Mac then makes verifiers the way Samsung's clients do, and may set a new password.
    var lockDerivationConfirmed: Bool { UserDefaults.standard.bool(forKey: "lockDerivationConfirmed") }

    /// Checks a typed password against the account's verifier.
    func checkLockPassword(_ password: String) -> Bool {
        guard let code = lockPasscode, code.verify(password) else { return false }
        // Whatever verifier is checked here was made by a Samsung client unless this Mac set it;
        // either way a match on one this Mac did not make shows the making is the same.
        if !lockMadeHere { UserDefaults.standard.set(true, forKey: "lockDerivationConfirmed") }
        return true
    }

    private var lockMadeHere: Bool { UserDefaults.standard.string(forKey: "lockMadeHere") == lockPasscode?.hash }

    /// Locks or unlocks notes, after Touch ID (or the Mac's password, which Touch ID falls back
    /// to). The note is marked as Samsung's clients mark a locked note, so it is locked on every
    /// device; there it opens with the account's notes password, here with Touch ID.
    func askToLock(_ ids: [String], _ locked: Bool) {
        let affected = ids.filter { library.notes[$0].map { $0.isLocked != locked } ?? false }
        guard !affected.isEmpty else { return }
        let owner = lockOwner ?? ""
        let what = affected.count == 1 ? String(localized: "this note") : String(localized: "\(affected.count) notes")
        LockPrompt.touchID(locked ? String(localized: "lock \(what)") : String(localized: "take the lock off \(what)")) { [weak self] passed in
            guard let self else { return }
            guard passed else {
                if !LockPrompt.canUseTouchID() { self.lastError = String(localized: "This Mac has no password or Touch ID to check with, so notes cannot be locked or unlocked here.") }
                return
            }
            for id in affected {
                // What is typed in the note on screen is stored first.
                NoteSession.live.object(forKey: id as NSString)?.saveNow()
                do { try self.edits.setLocked(id, locked, owner: owner) } catch { self.lastError = String(localized: "The note could not be \(locked ? "locked" : "unlocked"). \(AppModel.describe(error))") }
            }
            self.changed()
        }
    }

    /// Sets a new notes password for the whole account: kept here, and sent with the next sync.
    func setLockPassword(_ password: String) -> Bool {
        guard signedIn, let made = Passcode.make(password) else { return false }
        UserDefaults.standard.set(made.hash, forKey: "lockMadeHere")
        lockPasscode = made
        Task {
            await account.setPasscode(made, unsent: true)
            syncNow()
        }
        return true
    }
}

/// Asks who is at the keyboard: Touch ID, or the Mac's password where there is none.
@MainActor
enum LockPrompt {
    static func canUseTouchID() -> Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    static func touchID(_ reason: String, done: @escaping @MainActor (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { done(false); return }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in DispatchQueue.main.async { done(ok) } }
    }
}

/// The sheet for a new notes password: the one in use (when there is one), the new one, twice.
struct LockPasswordSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var fresh = ""
    @State private var again = ""
    @State private var problem: String?

    var body: some View {
        let changing = model.lockPasscode != nil
        VStack(alignment: .leading, spacing: 14) {
            Text(changing ? "Change password for locked notes" : "Create password").font(.headline)
            Text("One password for all the locked notes of your Samsung account, on every device.").font(.callout).foregroundStyle(.secondary)
            Form {
                if changing { SecureField("Current password", text: $current) }
                SecureField("New password", text: $fresh)
                SecureField("Confirm password", text: $again)
            }
            Text(problem ?? "Enter a password with at least 4 characters in it.").font(.callout).foregroundStyle(problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") { save(changing) }.keyboardShortcut(.defaultAction).disabled(fresh.count < Passcode.minimumLength || again.isEmpty || (changing && current.isEmpty))
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func save(_ changing: Bool) {
        if changing, !model.checkLockPassword(current) { problem = String(localized: "The current password is not right."); return }
        guard fresh == again else { problem = String(localized: "The two new passwords are not the same."); return }
        guard model.setLockPassword(fresh) else { problem = String(localized: "The password could not be set."); return }
        dismiss()
    }
}
