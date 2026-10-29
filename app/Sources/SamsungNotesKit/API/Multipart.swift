import Foundation
import zlib

/// One part of a multipart/form-data body.
public struct MultipartPart {
    public var name: String
    public var filename: String?
    public var contentType: String?
    public var body: Data
}

public enum Multipart {
    /// Splits a multipart body. The boundary is taken from the first line, so the caller does not
    /// need the Content-Type header.
    public static func parse(_ data: Data) -> [MultipartPart] {
        guard data.starts(with: Data("--".utf8)), let lineEnd = data.firstRange(of: Data("\r\n".utf8)) else { return [] }
        let delimiter = Data("\r\n".utf8) + data[data.startIndex..<lineEnd.lowerBound]
        var parts: [MultipartPart] = []
        var cursor = lineEnd.upperBound
        while cursor < data.endIndex {
            let end = data.range(of: delimiter, in: cursor..<data.endIndex)?.lowerBound ?? data.endIndex
            let section = data[cursor..<end]
            if let split = section.firstRange(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: section[section.startIndex..<split.lowerBound], as: UTF8.self)
                var part = MultipartPart(name: "", filename: nil, contentType: nil, body: Data(section[split.upperBound...]))
                for line in head.components(separatedBy: "\r\n") {
                    let lower = line.lowercased()
                    if lower.hasPrefix("content-disposition:") {
                        part.name = parameter("name", in: line) ?? ""
                        part.filename = parameter("filename", in: line)
                    } else if lower.hasPrefix("content-type:") {
                        part.contentType = line.dropFirst("content-type:".count).trimmingCharacters(in: .whitespaces)
                    }
                }
                parts.append(part)
            }
            guard end < data.endIndex else { break }
            cursor = end + delimiter.count
            if data[cursor...].starts(with: Data("--".utf8)) { break }
            if data[cursor...].starts(with: Data("\r\n".utf8)) { cursor += 2 }
        }
        return parts
    }

    static func parameter(_ name: String, in header: String) -> String? {
        for piece in header.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where piece.lowercased().hasPrefix(name + "=") {
            return piece.dropFirst(name.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    /// Builds a body the way the Windows client does: no quotes around names.
    public static func build(_ parts: [MultipartPart], boundary: String) -> Data {
        var out = Data()
        for part in parts {
            out.append(Data("--\(boundary)\r\n".utf8))
            if let type = part.contentType { out.append(Data("Content-Type: \(type)\r\n".utf8)) }
            var disposition = "Content-Disposition: form-data; name=\(part.name)"
            if let file = part.filename { disposition += "; filename=\(file); filename*=utf-8''\(file)" }
            out.append(Data("\(disposition)\r\n\r\n".utf8))
            out.append(part.body)
            out.append(Data("\r\n".utf8))
        }
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }
}

public enum Gzip {
    public static func compress(_ data: Data) -> Data? {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        var out = Data(count: Int(deflateBound(&stream, UInt(data.count))) + 32)
        let capacity = out.count
        let status: Int32 = data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int32 in
            out.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) -> Int32 in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(capacity)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { return nil }
        out.count = Int(stream.total_out)
        return out
    }

    public static func decompress(_ data: Data) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, 47, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var status: Int32 = Z_OK
        data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            repeat {
                status = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
                    stream.next_out = pointer.baseAddress
                    stream.avail_out = uInt(pointer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                out.append(buffer, count: buffer.count - Int(stream.avail_out))
            } while status == Z_OK
        }
        return status == Z_STREAM_END ? out : nil
    }
}
