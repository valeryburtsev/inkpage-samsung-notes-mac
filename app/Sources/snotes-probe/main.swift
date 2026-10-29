import Foundation
import CoreGraphics
import SamsungNotesKit

// Development companion for the Samsung Notes client. Nothing here signs in or stores secrets.
//   snotes-probe gate [WINSDK|ANDROIDSDK] [iterations]   build a sign-in address and ask the gate about it
let arguments = Array(CommandLine.arguments.dropFirst())

func run() async {
    switch arguments.first {
    case "gate":
        let gate = SamsungAccount.Gate(rawValue: arguments.count > 1 ? arguments[1] : "WINSDK") ?? .windows
        do {
            let entry = try await SamsungAccount.entryPoint(gate: gate, country: "PT")
            print("entry: chkDoNum=\(entry.chkDoNum) keyIterations=\(entry.keyIterations.map(String.init) ?? "-") signIn=\(entry.signInURI)")
            var overrides: [String: String] = [:]
            var iterations: Int?
            for argument in arguments.dropFirst(2) {
                if let split = argument.firstIndex(of: "=") { overrides[String(argument[..<split])] = String(argument[argument.index(after: split)...]) } else { iterations = Int(argument) }
            }
            let pending = try SamsungAccount.begin(gate: gate, country: "PT", language: "en", deviceID: AccountCrypto.randomHex(16), entry: entry, iterations: iterations, overrides: overrides)
            let response = try await HTTPClient.shared.request("GET", pending.signInURL, headers: ["User-Agent": SamsungAccount.browserUserAgent, "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"])
            print("gate: HTTP \(response.status)")
            if let location = response.header("Location") {
                let shown = location.replacingOccurrences(of: #"credentials=[0-9a-f]+"#, with: "credentials=…", options: .regularExpression)
                print("location: \(shown.prefix(1400))")
                print("state echoed: \(location.contains(pending.state))")
            } else {
                let text = response.text
                let title = text.range(of: #"<title>[^<]*</title>"#, options: .regularExpression).map { String(text[$0]) } ?? ""
                print("page: \(text.count) chars \(title)")
                for marker in ["error", "Error", "invalid", "signInForm", "svcParam", "unsupported"] where text.contains(marker) { print("  contains \(marker)") }
            }
        } catch { print("error: \(error)") }
    case "import-capture" where arguments.count >= 3:
        importCapture(flows: URL(fileURLWithPath: arguments[1]), store: LocalStore(root: URL(fileURLWithPath: arguments[2])))
    case "templates" where arguments.count >= 2:
        // Every ruling on a page of the Windows client's size, side by side, for looking at.
        let all = PageTemplate.allCases.filter { $0 != .blank }
        let page = CGSize(width: 848, height: 1200), gap = 40.0, columns = 5
        let rows = (all.count + columns - 1) / columns
        let dark = arguments.contains("--dark")
        let size = CGSize(width: Double(columns) * (page.width + gap) + gap, height: Double(rows) * (page.height + gap) + gap)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: dark ? 0.3 : 0.8, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        for (index, template) in all.enumerated() {
            let rect = CGRect(x: gap + Double(index % columns) * (page.width + gap), y: gap + Double(index / columns) * (page.height + gap), width: page.width, height: page.height)
            context.setFillColor(dark ? CGColor(gray: 0.004, alpha: 1) : CGColor(srgbRed: 0.988, green: 0.988, blue: 0.988, alpha: 1))
            context.fill(rect)
            template.draw(in: context, page: rect, dark: dark)
        }
        if let image = context.makeImage() { NoteRenderer.writePNG(image, to: URL(fileURLWithPath: arguments[1])) }
    case "render" where arguments.count >= 3:
        render(store: LocalStore(root: URL(fileURLWithPath: arguments[1])), out: URL(fileURLWithPath: arguments[2]), dark: arguments.contains("--dark"))
    default:
        print("usage: snotes-probe gate [WINSDK|ANDROIDSDK] [key=value…] | import-capture <flows.jsonl> <store> | render <store> <out> [--dark] | templates <out.png> [--dark]")
    }
}

/// Builds a library from a capture taken with tools/capture, so the app can be tried without signing in.
func importCapture(flows: URL, store: LocalStore) {
    guard let text = try? String(contentsOf: flows, encoding: .utf8) else { print("cannot read \(flows.path)"); return }
    store.removeEverything()
    var library = Library()
    let blobs = flows.deletingLastPathComponent().appendingPathComponent("blobs")
    func body(_ record: [String: Any], _ side: String) -> Data? {
        guard let body = record[side] as? [String: Any] else { return nil }
        if let b64 = body["b64"] as? String { return Data(base64Encoded: b64) }
        if let text = body["text"] as? String { return Data(text.utf8) }
        if body["kind"] as? String == "blob", let hash = body["sha256"] as? String { return try? Data(contentsOf: blobs.appendingPathComponent(hash)) }
        return nil
    }
    func ingest(serverID: String, parts: [MultipartPart]) {
        guard let xml = parts.first(where: { $0.name == "noteResource" })?.body, let document = try? NoteDocument(xml: xml), !document.pages.isEmpty else { return }
        var strokes: [String: Data] = [:]
        for part in parts where part.name == "strokeResource" { if let id = part.filename?.split(separator: "_").first { strokes[String(id)] = part.body } }
        guard let record = try? store.ingest(serverID: serverID, commitID: document.commitID ?? "local", deviceName: "", xml: xml, strokes: strokes) else { return }
        library.notes[record.id] = record
        for file in document.files { if let data = try? Data(contentsOf: blobs.appendingPathComponent(file.id)) { store.writeFile(record.id, file.id, data) } }
        // A picture the capture saw only on its way down is a response body of the same hash.
        for hash in [document.firstImage].compactMap({ $0 }) where !store.hasFile(record.id, hash) { if let data = downloads[hash] { store.writeFile(record.id, hash, data) } }
    }
    var downloads: [String: Data] = [:]
    var records: [[String: Any]] = []
    for line in text.split(separator: "\n") {
        guard let record = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], record["type"] as? String == "http" else { continue }
        records.append(record)
        if let response = record["response_body"] as? [String: Any], let hash = response["sha256"] as? String, let data = body(record, "response_body") { downloads[hash] = data }
    }
    for record in records {
        guard let url = record["url"] as? String, let method = record["method"] as? String else { continue }
        let path = URLComponents(string: url)?.path ?? ""
        if path.hasSuffix("/compareForDownsync"), let data = body(record, "response_body") {
            ingest(serverID: path.split(separator: "/").dropLast().last.map(String.init) ?? "", parts: Multipart.parse(data))
        } else if method == "POST", path.hasSuffix("/samsungnotes/v1/notes"), let data = body(record, "request_body") {
            ingest(serverID: "created", parts: Multipart.parse(data))
        }
    }
    library.nodes = CaptureFolders.nodes(from: records.compactMap { record -> Data? in
        guard let url = record["url"] as? String, URLComponents(string: url)?.path.hasSuffix("/folder/changes") == true else { return nil }
        return body(record, "response_body")
    })
    library.lastSync = Date()
    library.cloudBytes = library.notes.values.reduce(0) { $0 + $1.bytes }
    store.save(library)
    print("imported \(library.notes.count) notes, \(library.nodes.count) tree nodes into \(store.root.path)")
    for note in library.notes.values.sorted(by: { $0.modifiedAt > $1.modifiedAt }) {
        print("  \(note.id.prefix(8)) ink=\(note.hasInk) text=\(note.hasText) cover=\(note.coverFile?.prefix(8) ?? "-") title=\(note.title.isEmpty ? "(none)" : "set") state=\(library.nodes[note.id]?.state.rawValue ?? "?")")
    }
}

func render(store: LocalStore, out: URL, dark: Bool) {
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for record in store.loadLibrary().notes.values {
        guard let note = try? store.load(record.id) else { print("cannot load \(record.id)"); continue }
        if let image = NoteRenderer.thumbnail(note, side: 520, dark: dark) {
            NoteRenderer.writePNG(image, to: out.appendingPathComponent("\(record.id)-thumb.png"))
        }
        let layout = NoteLayout(note.document)
        let scale = 900 / layout.pageWidth
        let width = 900, height = Int(layout.pageRect(0).height * scale)
        if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1); context.scaleBy(x: scale, y: scale)
            NoteRenderer.draw(note, in: context, dark: dark) { note.image($0) }
            if let image = context.makeImage() { NoteRenderer.writePNG(image, to: out.appendingPathComponent("\(record.id)-page.png")) }
        }
        print("rendered \(record.id) text=\(note.document.body.plain.count) density=\(note.document.density) pages=\(note.document.pages.count) strokes=\(note.strokes.count)")
    }
}

await run()
