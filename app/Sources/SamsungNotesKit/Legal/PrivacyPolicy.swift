import Foundation

/// A part of one of the app's legal texts: a heading and its paragraphs and lists in Markdown.
public struct LegalSection: Sendable, Identifiable {
    public let title: String
    public let body: String
    public var id: String { title }
    public init(title: String, body: String) { self.title = title; self.body = body }
}

/// The app's privacy policy: shown in the app (Settings › General, Help menu) and kept word for
/// word as `PRIVACY.md` at the project's root, the copy to publish at a public address for the
/// App Store, Google's sign-in verification and anyone else who asks. A test keeps the two the same.
public enum PrivacyPolicy {
    /// Where questions and requests about personal information go.
    public static let contact = "hello@krushock.com"
    public static let effective = "14 October 2026"

    public typealias Section = LegalSection

    public static let sections: [Section] = [
        Section(title: "In short", body: """
        \(LocalStore.appName) is an independent notes app for the Mac. It is not made, endorsed or run by Samsung, Apple or Google.

        - Your notes stay on your Mac. Nothing is sent anywhere unless you turn on sync.
        - With sync on, the app talks only to the service you chose (Samsung Cloud, iCloud Drive or Google Drive), using your own account with that service.
        - The developer of \(LocalStore.appName) runs no server and never receives your notes, your account details or anything else about you.
        - There is no analytics, no advertising and no tracking. Nothing is sold or shared.
        """),
        Section(title: "What the app handles", body: """
        - **Your notes**: their text, handwriting, pictures, PDFs, recordings, folders and settings, as you make them or as they come from your sync service.
        - **Sign-in details for the sync service you choose**: the tokens that service gives the app after you sign in on its own page. The app never sees or stores your passwords for Samsung or Google. The tokens are kept in your Mac's keychain.
        - **For Samsung Cloud**: your Mac's name (shown in Samsung Notes as the device a note was last edited on) and identifiers the app makes up at random for this Mac. No hardware identifiers or serial numbers are read or sent.
        - **For Google Drive**: the email address of the Google account you sign in with, shown in Settings so you know which account is in use.
        - **The password of locked notes**, if you set one: stored only as a salted verifier, never as the password itself.
        """),
        Section(title: "Where your information goes", body: """
        - **Nowhere, while sync is off.** Notes are kept in the app's folder on your Mac (`~/Library/Application Support/\(LocalStore.appName)`).
        - **Samsung Cloud (experimental and unofficial)**: when you sign in with your Samsung account, notes go to and come from Samsung's servers, as they do from Samsung's own Notes apps. Samsung has not made, approved or endorsed this; the Terms of Use say what that means for you. Samsung's privacy notice applies to what Samsung holds.
        - **iCloud Drive**: notes are written to a folder named \(LocalStore.appName) in your iCloud Drive, which Apple stores under Apple's privacy policy. Locked notes can be encrypted there with a password you choose.
        - **Google Drive**: the app asks Google only for access to a folder of its own in your Drive (the scope `drive.appdata`). It cannot see, open or change any other file in your Drive. Locked notes can be encrypted there with a password you choose. Google's privacy policy applies to what Google holds.

        Information goes from your Mac directly to the service you chose, over encrypted connections (HTTPS). It does not pass through any server of the developer's.
        """),
        Section(title: "Information from Google", body: """
        \(LocalStore.appName) uses what it receives from Google's APIs only to keep your notes in sync in your own Drive and to show which account is signed in. It does not transfer that information to anyone, does not use it for advertising, and no person reads it.

        \(LocalStore.appName)'s use and transfer of information received from Google APIs to any other app will adhere to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements.
        """),
        Section(title: "What is done on your Mac", body: """
        - **Handwriting search**: handwriting is read by macOS on your Mac, so that it can be searched. It never leaves the Mac.
        - **Apple Intelligence**: answering calculations as you type and Write with AI use the language model built into macOS, on your Mac. What you ask and what it writes are not sent to the developer.
        - **Writing Tools**: proofreading, rewriting and summarising are features of macOS. Apple's privacy policy applies to them.

        Both Apple Intelligence features can be switched off in Settings › General.
        """),
        Section(title: "Logs", body: """
        To help find faults, the app keeps a log of its sync requests on your Mac (`sync.log` in the app's folder): the address and the result of each request, and the kind of thing that was refused. It does not contain your notes' content or your tokens. It stays on your Mac unless you choose to send it to someone.
        """),
        Section(title: "Keeping and deleting", body: """
        - Notes stay on your Mac until you delete them. Deleting the app's folder removes everything the app keeps on the Mac.
        - Signing out of a sync service in Settings removes its tokens from the keychain.
        - Notes held by Samsung, Apple or Google stay with them until you delete them there, under their terms. To remove \(LocalStore.appName)'s access to your Google account, use your Google account's settings (Security › Third-party apps). Its folder in your Drive can be deleted from Drive's settings (Manage apps).
        """),
        Section(title: "Children", body: """
        \(LocalStore.appName) is a general notes app for everyone. It is not directed at children under 13 and is not offered in any children's category.

        The developer collects no personal information from anyone, children included: the app has no account of its own, no analytics, no advertising and no server. A child's notes stay on the Mac, or go to the Samsung, Apple or Google account used to sync them, under that service's own rules for children's accounts.

        If you are a parent or guardian and have a question about your child's use of \(LocalStore.appName), write to the address under Contact.
        """),
        Section(title: "Your rights, including in California", body: """
        The developer does not collect, sell or share personal information, and so holds none about you to give access to, correct or delete. Under the California Consumer Privacy Act and similar laws you nonetheless have the right to know what personal information is collected, to have it deleted or corrected, and not to be discriminated against for using these rights. What the sync services hold about you is theirs to answer for: Samsung, Apple and Google each take such requests through their own privacy pages.

        In the past 12 months the developer has collected no categories of personal information, and has sold or shared none. The app does not respond to Do Not Track signals because it does no tracking.
        """),
        Section(title: "Changes", body: """
        If this policy changes, the new version is shipped with the app and published at the same address, with a new date at the top.
        """),
        Section(title: "Contact", body: """
        Questions or requests about this policy: [\(PrivacyPolicy.contact)](mailto:\(PrivacyPolicy.contact)).
        """),
    ]

    /// The whole policy as Markdown: what `PRIVACY.md` holds.
    public static var markdown: String {
        var out = "# \(LocalStore.appName) Privacy Policy\n\nEffective \(effective).\n"
        for section in sections { out += "\n## \(section.title)\n\n\(section.body)\n" }
        return out
    }
}
