import XCTest
@testable import SamsungNotesKit

final class PrivacyPolicyTests: XCTestCase {
    /// `PRIVACY.md` at the project's root (next to `app/`) is the policy the app shows, word for word.
    func testThePublishedCopyIsThePolicyTheAppShows() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // `PRIVACY_WRITE=1 swift test --filter PrivacyPolicyTests` writes the copy anew after the policy changed.
        if ProcessInfo.processInfo.environment["PRIVACY_WRITE"] != nil { try PrivacyPolicy.markdown.write(to: root.appendingPathComponent("PRIVACY.md"), atomically: true, encoding: .utf8) }
        let published = try String(contentsOf: root.appendingPathComponent("PRIVACY.md"), encoding: .utf8)
        XCTAssertEqual(published, PrivacyPolicy.markdown, "PRIVACY.md differs from PrivacyPolicy.swift: copy PrivacyPolicy.markdown into it")
        XCTAssertTrue(PrivacyPolicy.markdown.contains("Limited Use requirements"), "Google's verification asks for this sentence")
    }

    /// `TERMS.md` at the project's root is the terms the app shows, word for word.
    func testThePublishedTermsAreTheTermsTheAppShows() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if ProcessInfo.processInfo.environment["PRIVACY_WRITE"] != nil { try TermsOfUse.markdown.write(to: root.appendingPathComponent("TERMS.md"), atomically: true, encoding: .utf8) }
        let published = try String(contentsOf: root.appendingPathComponent("TERMS.md"), encoding: .utf8)
        XCTAssertEqual(published, TermsOfUse.markdown, "TERMS.md differs from TermsOfUse.swift: run PRIVACY_WRITE=1 swift test --filter PrivacyPolicyTests")
        XCTAssertTrue(TermsOfUse.markdown.contains("at your own risk"))
        XCTAssertFalse(TermsOfUse.markdown.contains("SNotes") || PrivacyPolicy.markdown.contains("SNotes"), "the app's former name is gone")
    }

    /// The app's folder under its former name is moved to the new name once, and only when the new one is not there.
    func testTheFormerFolderIsTakenOver() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let former = base.appendingPathComponent("SNotes/notes", isDirectory: true)
        try FileManager.default.createDirectory(at: former, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: base.appendingPathComponent("SNotes/library.json"))
        let root = LocalStore.root(in: base)
        XCTAssertEqual(root.lastPathComponent, "Inkpage")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("SNotes").path))
        // A folder of the former name made later (an old build run again) does not replace the new one.
        try FileManager.default.createDirectory(at: base.appendingPathComponent("SNotes"), withIntermediateDirectories: true)
        _ = LocalStore.root(in: base)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
    }
}
