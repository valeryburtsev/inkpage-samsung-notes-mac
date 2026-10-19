import SamsungNotesKit
import SwiftUI

/// The privacy policy or the terms of use, in a window of its own: from Settings and the Help menu.
struct PrivacyPolicyView: View {
    var title = "\(LocalStore.appName) Privacy Policy"
    var effective = PrivacyPolicy.effective
    var sections = PrivacyPolicy.sections

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text("Effective \(effective)").foregroundStyle(.secondary)
                }
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        ForEach(Array(section.body.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.enumerated()), id: \.offset) { _, line in
                            paragraph(line)
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    /// A paragraph, or an item of a list, with its links and emphasis.
    @ViewBuilder private func paragraph(_ line: String) -> some View {
        let item = line.hasPrefix("- ")
        let text = (try? AttributedString(markdown: item ? String(line.dropFirst(2)) : line)) ?? AttributedString(line)
        if item {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
