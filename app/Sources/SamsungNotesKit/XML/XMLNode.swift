import Foundation

/// A small DOM over Foundation's XMLParser: enough for the sync service's documents.
public final class XMLNode {
    public let name: String
    public var attributes: [String: String]
    public var children: [XMLNode] = []
    public var text: String = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    public subscript(_ attribute: String) -> String? { attributes[attribute] }
    public func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }
    public func all(_ name: String) -> [XMLNode] { children.filter { $0.name == name } }
    public func value(_ name: String) -> String? { child(name)?.text }

    /// The first element with this name anywhere below, depth first.
    public func descendant(_ name: String) -> XMLNode? {
        for child in children {
            if child.name == name { return child }
            if let found = child.descendant(name) { return found }
        }
        return nil
    }

    public func descendants(_ name: String) -> [XMLNode] {
        var out: [XMLNode] = []
        for child in children {
            if child.name == name { out.append(child) }
            out.append(contentsOf: child.descendants(name))
        }
        return out
    }

    public func double(_ attribute: String) -> Double? { attributes[attribute].flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
    /// Whole numbers, also when written with a fraction. Anything not finite or out of range is no number.
    public func int(_ attribute: String) -> Int? {
        attributes[attribute].flatMap { text in Int(text) ?? Double(text).flatMap { $0.isFinite && abs($0) < 1e15 ? Int($0) : nil } }
    }
    public func bool(_ attribute: String) -> Bool { attributes[attribute]?.lowercased() == "true" }
}

public enum XMLTree {
    public struct Failure: Error { public let reason: String }

    public static func parse(_ data: Data) throws -> XMLNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw Failure(reason: parser.parserError?.localizedDescription ?? "not XML")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        var stack: [XMLNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = XMLNode(name: elementName, attributes: attributeDict)
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if let node = stack.popLast(), !node.children.isEmpty { node.text = node.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }
}

extension String {
    /// Base64 to text, as the sync service encodes names.
    var decodedBase64: String? { Data(base64Encoded: self).flatMap { String(data: $0, encoding: .utf8) } }
    var escapedXML: String {
        replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
