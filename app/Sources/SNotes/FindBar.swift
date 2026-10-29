import SwiftUI

/// The bar for finding text in the open note: what to look for, how many places hold it, and
/// the way to the next and the one before.
struct FindBar: View {
    let session: NoteSession
    @State private var query = ""
    @FocusState private var typing: Bool

    var body: some View {
        let text = session.text
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Find in this note", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 190)
                .focused($typing)
                .onSubmit { text.findStep(NSEvent.modifierFlags.contains(.shift) ? -1 : 1); typing = true }
                .onChange(of: query) { text.find(query) }
                .accessibilityLabel("Find in this note")
            Text(query.isEmpty ? "" : text.found.isEmpty ? "Not found" : "\(text.foundIndex + 1) of \(text.found.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 62, alignment: .trailing)
            Button { text.findStep(-1) } label: { Image(systemName: "chevron.up").frame(width: 24, height: 22).contentShape(.rect) }
                .disabled(text.found.isEmpty).hoverHighlight(radius: 7).help("Previous (⇧Return)").accessibilityLabel("Previous")
            Button { text.findStep(1) } label: { Image(systemName: "chevron.down").frame(width: 24, height: 22).contentShape(.rect) }
                .disabled(text.found.isEmpty).hoverHighlight(radius: 7).help("Next (Return)").accessibilityLabel("Next")
            Button { close() } label: { Text("Done").padding(.horizontal, 8).frame(height: 22).contentShape(.rect) }.hoverHighlight(radius: 7).keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .floatingBar()
        .glassEffect(.regular, in: .capsule)
        .onAppear { typing = true }
        .onDisappear { text.endFind() }
        .onExitCommand { close() }
    }

    private func close() {
        session.finding = false
        session.text.focus()
    }
}
