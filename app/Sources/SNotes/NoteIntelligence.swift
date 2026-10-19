import AppKit
import FoundationModels
import SamsungNotesKit
import SwiftUI

/// What the Mac's own language model (Apple Intelligence, on the device) does in a note, after
/// Apple's Notes: writes text to order, and reads a calculation that is put in words. Nothing
/// leaves the Mac for it. The arithmetic itself is never the model's: it is done by `MathNotes`.
enum NoteIntelligence {
    /// Nil when the model can be asked; else why not, in a sentence.
    static var unavailable: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return String(localized: "This Mac does not have Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled): return String(localized: "Apple Intelligence is switched off. Turn it on in System Settings › Apple Intelligence & Siri.")
        case .unavailable(.modelNotReady): return String(localized: "Apple Intelligence is still getting ready on this Mac. Try again in a while.")
        case .unavailable: return String(localized: "Apple Intelligence is not available just now.")
        }
    }

    @Generable
    struct Arithmetic {
        @Guide(description: "A plain arithmetic expression that uses only numbers, the signs + - * / ^ and parentheses. Empty when the text is not a calculation.")
        var expression: String
    }

    /// A calculation written in words ("15% of 240", "3 feet in cm") as plain arithmetic
    /// ("0.15 * 240", "3 * 30.48"), for `MathNotes` to work out. Nil when it is not one.
    static func arithmetic(for phrase: String) async -> String? {
        guard unavailable == nil else { return nil }
        let session = LanguageModelSession(instructions: """
            You turn a short phrase from someone's notes into plain arithmetic. Use only numbers, + - * / ^ and parentheses. \
            Convert units by multiplying with the exact factor. Do not work the result out. \
            If the phrase is not a calculation, give an empty expression.
            """)
        guard let answer = try? await session.respond(to: phrase, generating: Arithmetic.self) else { return nil }
        let found = answer.content.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        return found.isEmpty ? nil : found
    }
}

/// Text written to order for a note: asked for in a sentence, shown as it comes, and taken
/// into the note, tried again, or changed by saying how.
@MainActor @Observable
final class NoteWriter {
    private(set) var draft = ""
    private(set) var isWriting = false
    private(set) var problem: String?
    @ObservationIgnored private var session: LanguageModelSession?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Asks for text. `title` and `before` are the note's title and what stands before the
    /// caret, so that what is written fits what is there. A second request in the same
    /// sitting changes what was written ("shorter", "more formal").
    func write(_ request: String, title: String, before: String) {
        let wanted = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, !isWriting else { return }
        if let reason = NoteIntelligence.unavailable { problem = reason; return }
        let again = session != nil && !draft.isEmpty
        if session == nil {
            session = LanguageModelSession(instructions: """
                You write text for the user's note. Give only the text to put into the note: no introduction, no closing remark, no quotation marks around it, no Markdown. \
                Write in the language of the request unless it asks for another. Keep to what was asked for.
                """)
        }
        var prompt = wanted
        if !again {
            let context = before.suffix(1500).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { prompt += "\n\nThe note is called: \(title)" }
            if !context.isEmpty { prompt += "\n\nThe note so far ends like this:\n\(context)" }
        } else {
            prompt = "Change the text you wrote: \(wanted)"
        }
        isWriting = true
        problem = nil
        draft = ""
        let session = session
        task = Task { [weak self] in
            do {
                guard let session else { return }
                for try await part in session.streamResponse(to: prompt) {
                    guard !Task.isCancelled else { break }
                    self?.draft = part.content
                }
            } catch {
                if !Task.isCancelled { self?.problem = String(localized: "The text could not be written. \(error.localizedDescription)") }
            }
            self?.draft = self?.draft.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self?.isWriting = false
        }
    }

    func stop() {
        task?.cancel()
        isWriting = false
    }

    /// Begins anew: what was written and said is forgotten.
    func reset() {
        stop()
        session = nil
        draft = ""
        problem = nil
    }
}

/// The button in the note's toolbar that opens the panel to ask for text; what is written goes
/// in at the caret.
struct WriteWithAI: View {
    let session: NoteSession
    @State private var writer = NoteWriter()

    var body: some View {
        @Bindable var session = session
        Button { session.writerOpen.toggle() } label: { Label("Write with AI", systemImage: "apple.intelligence") }
        .help("Write with AI (⇧⌘J): describe what you want, and it is written at the caret")
        .disabled(!session.canEdit)
        .popover(isPresented: $session.writerOpen, arrowEdge: .bottom) { WritePanel(session: session, writer: writer) }
    }
}

/// Where the text is asked for, shown as it is written, and taken into the note.
private struct WritePanel: View {
    let session: NoteSession
    let writer: NoteWriter
    @State private var request = ""
    @FocusState private var asking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !writer.draft.isEmpty || writer.isWriting {
                ScrollView {
                    Text(writer.draft.isEmpty ? " " : writer.draft).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            }
            if let problem = writer.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                TextField(writer.draft.isEmpty ? "Describe what you want to write" : "Describe a change", text: $request, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...4).focused($asking)
                    .onSubmit(ask)
                if writer.isWriting {
                    ProgressView().controlSize(.small)
                    Button("Stop") { writer.stop() }
                } else {
                    Button(action: ask) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)) }
                        .buttonStyle(.plain).disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Write").accessibilityLabel("Write")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            if !writer.draft.isEmpty, !writer.isWriting {
                HStack {
                    Button("Discard") { writer.reset(); session.writerOpen = false }
                    Spacer()
                    Button("Insert") { insert() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
            // Said before anything is asked, and readable: what is written here is written by AI.
            Label("Written by AI (Apple Intelligence, on this Mac). Check what it writes.", systemImage: "apple.intelligence").font(.callout).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 400)
        .onAppear { asking = true }
        .onDisappear { if !writer.isWriting, writer.draft.isEmpty { writer.reset() } }
    }

    private func ask() {
        let wanted = request
        request = ""
        let text = session.text
        let before = (text.text.plain as NSString).substring(to: min(text.selection.lowerBound, (text.text.plain as NSString).length))
        writer.write(wanted, title: session.title, before: before)
    }

    private func insert() {
        let at = session.text.selection.lowerBound
        session.text.insert(writer.draft, at: at, name: "Write with AI")
        writer.reset()
        session.writerOpen = false
        session.text.focus()
    }
}
