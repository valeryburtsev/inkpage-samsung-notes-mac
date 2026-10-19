import Foundation

/// The app's terms of use: shown in the app (Help menu, Settings) and kept word for word as
/// `TERMS.md` at the project's root, to publish beside the privacy policy. A test keeps the two the same.
/// What Samsung Cloud sync asks the user to accept is `samsungRisks`, which these terms repeat.
public enum TermsOfUse {
    public static let effective = "14 October 2026"
    /// Raised whenever the risks of Samsung Cloud sync are worded anew: the app then asks for them to be accepted again.
    public static let samsungRisksVersion = 1

    static var name: String { LocalStore.appName }

    /// What anyone turning on Samsung Cloud sync is told, and has to accept, first.
    public static var samsungRisks: [String] {
        [
            "\(name) is not made, endorsed, supported or approved by Samsung. To sync, it talks to Samsung Cloud the way Samsung's own Notes app for Windows does, without Samsung's permission.",
            "Samsung may change or block this at any time, and sync can stop without warning.",
            "Samsung's terms of service forbid reverse engineering its services and deciphering what is sent to and from its servers, which is how this sync works. Using it may break those terms, and Samsung may suspend or close your Samsung account, with the notes in it, if it suspects that.",
            "Notes can be duplicated, changed or lost. Keep a backup of anything that matters to you.",
            "This feature is offered as an experiment, as is, without any warranty. You use it entirely at your own risk: the developer of \(name) is not responsible for any loss or damage to your notes, your devices or your Samsung account.",
            "You are responsible for following Samsung's terms of service.",
        ]
    }

    public static var sections: [LegalSection] {
        [
            LegalSection(title: "Agreement", body: """
            These terms apply to your use of \(name), a notes app for the Mac made by an independent developer ("we"). By using the app you agree to them. If you do not agree, do not use the app.
            """),
            LegalSection(title: "Not affiliated with Samsung, Apple or Google", body: """
            \(name) is an independent app. It is not made, endorsed, sponsored, supported or approved by Samsung Electronics, Apple or Google.

            Samsung, Samsung Notes, Samsung Cloud and Galaxy are trademarks of Samsung Electronics Co., Ltd. Apple, Mac, iCloud and Apple Intelligence are trademarks of Apple Inc. Google and Google Drive are trademarks of Google LLC. These names are used only to say which services the app can work with.
            """),
            LegalSection(title: "Samsung Cloud sync is experimental and unofficial", body: """
            The app can keep notes in sync with Samsung Cloud through your own Samsung account. Before it does, it asks you to accept the following, which is part of these terms:

            \(samsungRisks.map { "- " + $0 }.joined(separator: "\n"))

            You can stop Samsung Cloud sync at any time in Settings › Account & Sync. Notes kept only on your Mac, or synced through iCloud Drive or Google Drive, do not depend on Samsung.
            """),
            LegalSection(title: "Other services", body: """
            When you sync through iCloud Drive or Google Drive, or use features of macOS such as Apple Intelligence and Writing Tools, those services' own terms apply between you and their providers. You are responsible for following them.
            """),
            LegalSection(title: "Your notes", body: """
            Your notes are yours. We do not receive them and claim no rights in them. You are responsible for what you write and keep, and for keeping copies of anything that matters to you: export your notes from time to time (Share and Export in a note's toolbar).
            """),
            LegalSection(title: "Use of the app", body: """
            Use the app lawfully, and only with accounts and content you are entitled to use. Do not use it to break the terms of any service it connects to on behalf of someone else, or to reach anyone else's data.
            """),
            LegalSection(title: "No warranty", body: """
            The app is provided "as is" and "as available", without warranties of any kind, express or implied, including any warranty of merchantability, fitness for a particular purpose, non-infringement, or that it will work without interruption or error, or keep your notes without loss. Some places do not allow the exclusion of certain warranties; there, these exclusions apply as far as the law allows.
            """),
            LegalSection(title: "Limitation of liability", body: """
            As far as the law allows, we are not liable for any indirect, incidental, special, consequential or punitive damages, or for any loss of data, notes, accounts, profits or goodwill, arising from your use of the app or of any service it connects to, even if we were told such damage was possible. Where liability cannot be excluded, it is limited to the amount you paid for the app, if any. Nothing in these terms limits liability that cannot be limited by law.
            """),
            LegalSection(title: "Changes and ending", body: """
            We may change the app, including removing Samsung Cloud sync, and these terms. A new version of the terms ships with the app with a new date at the top; using the app after that means you accept it. You can stop using the app at any time.
            """),
            LegalSection(title: "Contact", body: """
            Questions about these terms: [\(PrivacyPolicy.contact)](mailto:\(PrivacyPolicy.contact)).
            """),
        ]
    }

    /// The whole terms as Markdown: what `TERMS.md` holds.
    public static var markdown: String {
        var out = "# \(name) Terms of Use\n\nEffective \(effective).\n"
        for section in sections { out += "\n## \(section.title)\n\n\(section.body)\n" }
        return out
    }
}
