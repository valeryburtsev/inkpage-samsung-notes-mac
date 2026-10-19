import AppKit
import AuthenticationServices
import SamsungNotesKit

/// This app's registration with Google: the client ID under which Google lets it ask an
/// account for permission. Whoever builds the app makes it once in Google Cloud Console
/// (APIs & Services › Credentials › Create OAuth client ID; application type "iOS", which is
/// Google's name for an app of Apple's platforms, with this app's bundle ID) and writes it
/// here. It is not a secret: it only names the app on Google's sign-in page.
///
/// A client of the type "Desktop app" works too: then its secret goes into `clientSecret`.
enum GoogleRegistration {
    static let clientID = ""
    static let clientSecret = ""

    /// The client in use: the one built in, or for trying one out without building,
    /// `defaults write <bundle id> GoogleClientID <id>`.
    static var client: GoogleClient? {
        // The stand-in for Google that the checks use takes any client.
        if Launch.value("--google-test-server") != nil { return GoogleClient(id: "check.apps.googleusercontent.com") }
        let defaults = UserDefaults.standard
        let id = clientID.isEmpty ? (defaults.string(forKey: "GoogleClientID") ?? "") : clientID
        guard id.hasSuffix(".apps.googleusercontent.com") else { return nil }
        return GoogleClient(id: id, secret: clientID.isEmpty ? (defaults.string(forKey: "GoogleClientSecret") ?? "") : clientSecret)
    }
}

/// Google's sign-in page in the system's sign-in window, which shares the browser's session
/// (an account already signed in there is offered) and hands Google's answer back to the app.
@MainActor
final class GoogleWebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first { $0.isVisible } ?? ASPresentationAnchor() }
    }

    /// Shows the page. `done` gets the address Google sent the window to, when that address is
    /// one of `scheme`; nil when the window was closed first.
    func show(_ page: URL, scheme: String?, done: @escaping @MainActor (URL?) -> Void) {
        session?.cancel()
        let session = ASWebAuthenticationSession(url: page, callbackURLScheme: scheme) { url, _ in
            Task { @MainActor in done(url) }
        }
        session.presentationContextProvider = self
        // A check does not share the browser's session, so the system does not stop to ask whether it may.
        session.prefersEphemeralWebBrowserSession = Launch.value("--google-test-server") != nil
        self.session = session
        if !session.start() { done(nil) }
    }

    /// The page, until Google answers to an address of the app's own.
    func answer(_ page: URL, scheme: String) async -> URL? {
        await withCheckedContinuation { continuation in show(page, scheme: scheme) { continuation.resume(returning: $0) } }
    }

    func close() {
        session?.cancel()
        session = nil
    }
}

extension AppModel {
    /// Reads from the account what the views show of it.
    func refreshGoogle() async {
        if Launch.value("--google-stand-in") != nil { googleSignedIn = true; googleEmail = "check@example.com"; return }
        // The permission was given to the client the app was built with, and holds for no other.
        if let client = GoogleRegistration.client { await google.setClient(client) }
        googleSignedIn = await google.isSignedIn
        googleEmail = await google.email
    }

    /// Asks for the Google account's permission on Google's own page, and syncs with the
    /// account's Drive once it is given.
    func signInToGoogle() {
        guard !googleSigningIn, !isDemo else { return }
        guard let client = GoogleRegistration.client else {
            lastError = String(localized: "This build of the app is not registered with Google yet, so Google will not show it a sign-in page. A Google client ID has to be built into the app once (see GoogleSignIn.swift).")
            return
        }
        googleSigningIn = true
        let web = GoogleWebSignIn()
        Task {
            await google.setClient(client)
            do {
                if client.appScheme != nil {
                    let pending = try await google.beginSignIn()
                    guard let callback = await web.answer(pending.page, scheme: pending.callbackScheme) else { throw GoogleAccount.Failure.cancelled }
                    try await google.completeSignIn(pending, callback: callback)
                } else {
                    // A client answered on a port of this Mac: the window stays until the answer has come there.
                    let account = google
                    try await google.signIn { page in
                        Task { @MainActor in web.show(page, scheme: nil) { _ in Task { await account.cancelSignIn() } } }
                    }
                    web.close()
                }
                // Whatever this Mac kept of another account's Drive is not this one's.
                CloudMirror(store: store, cloud: google.drive(), folder: store.root.appendingPathComponent("google")).reset()
                await refreshGoogle()
                googleSigningIn = false
                NSApplication.shared.activate()
                if provider == .google { syncError = nil; syncNow() } else { chooseProvider(.google) }
            } catch {
                web.close()
                await refreshGoogle()
                googleSigningIn = false
                NSApplication.shared.activate()
                if error as? GoogleAccount.Failure != .cancelled { lastError = AppModel.describe(error, with: .google) }
            }
        }
    }

    /// Signs out of Google: the notes stop being synced with its Drive, after the usual question.
    func signOutOfGoogle() {
        guard googleSignedIn, !isSyncing, !googleSigningIn else { return }
        if provider == .google {
            chooseProvider(.none)
            guard provider != .google else { return }
        }
        Task {
            await google.signOut()
            CloudMirror(store: store, cloud: google.drive(), folder: store.root.appendingPathComponent("google")).reset()
            await refreshGoogle()
        }
    }
}
