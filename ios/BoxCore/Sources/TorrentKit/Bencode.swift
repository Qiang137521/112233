import Foundation

/// A bencoded value (BEP 3).
public indirect enum BValue: Equatable, Sendable {
    case int(Int64)
    case bytes(Data)
    case list([BValue])
    case dict([String: BValue])

    public subscript(key: String) -> BValue? {
        if case .dict(let d) = self { return d[key] }
        return nil
    }

    public var int: Int64? { if case .int(let v) = self { return v }; return nil }
    public var data: Data? { if case .bytes(let v) = self { return v }; return nil }
    public var list: [BValue]? { if case .list(let v) = self { return v }; return nil }
    public var dict: [String: BValue]? { if case .dict(let v) = self { return v }; return nil }

    /// UTF-8 string, falling back to ISO-8859-1 so that no name is ever lost.
    public var string: String? {
        guard let d = data else { return nil }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
    }

    public static func str(_ s: String) -> BValue { .bytes(Data(s.utf8)) }
}

public enum BencodeError: Error, CustomStringConvertible {
    case unexpectedEnd
    case invalid(String)

    public var description: String {
        switch self {
        case .unexpectedEnd: return "bencode: unexpected end of data"
        case .invalid(let s): return "bencode: \(s)"
        }
    }
}

public struct BDecoder {
    private let bytes: [UInt8]
    private(set) var index: Int
    private var depth = 0
    /// Byte range of the top-level "info" dictionary, if one was seen.
    public private(set) var infoRange: Range<Int>?

    public init(_ data: Data) {
        self.bytes = [UInt8](data)
        self.index = 0
    }

    /// Decodes a whole buffer; trailing bytes are an error.
    public static func decode(_ data: Data) throws -> BValue {
        var d = BDecoder(data)
        let v = try d.next()
        guard d.index == d.bytes.count else { throw BencodeError.invalid("trailing data") }
        return v
    }

    /// Decodes one value at the start of `data` and returns how many bytes it used.
    public static func decodePrefix(_ data: Data) throws -> (BValue, Int) {
        var d = BDecoder(data)
        let v = try d.next()
        return (v, d.index)
    }

    public mutating func next() throws -> BValue {
        guard index < bytes.count else { throw BencodeError.unexpectedEnd }
        depth += 1
        defer { depth -= 1 }
        guard depth < 64 else { throw BencodeError.invalid("nesting too deep") }
        let c = bytes[index]
        switch c {
        case UInt8(ascii: "i"):
            index += 1
            let v = try readInt(until: UInt8(ascii: "e"))
            return .int(v)
        case UInt8(ascii: "l"):
            index += 1
            var items: [BValue] = []
            while true {
                guard index < bytes.count else { throw BencodeError.unexpectedEnd }
                if bytes[index] == UInt8(ascii: "e") { index += 1; break }
                items.append(try next())
            }
            return .list(items)
        case UInt8(ascii: "d"):
            index += 1
            var dict: [String: BValue] = [:]
            while true {
                guard index < bytes.count else { throw BencodeError.unexpectedEnd }
                if bytes[index] == UInt8(ascii: "e") { index += 1; break }
                let keyData = try readBytes()
                let key = String(decoding: keyData, as: UTF8.self)
                let start = index
                let value = try next()
                if depth == 1 && key == "info" { infoRange = start..<index }
                dict[key] = value
            }
            return .dict(dict)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .bytes(try readBytes())
        default:
            throw BencodeError.invalid("unexpected byte \(c) at \(index)")
        }
    }

    private mutating func readInt(until terminator: UInt8) throws -> Int64 {
        var negative = false
        var value: Int64 = 0
        var digits = 0
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { negative = true; index += 1 }
        while true {
            guard index < bytes.count else { throw BencodeError.unexpectedEnd }
            let c = bytes[index]
            index += 1
            if c == terminator { break }
            guard c >= 48 && c <= 57 else { throw BencodeError.invalid("bad digit") }
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (a, o2) = m.addingReportingOverflow(Int64(c - 48))
            guard !o1 && !o2 else { throw BencodeError.invalid("integer overflow") }
            value = a
            digits += 1
        }
        guard digits > 0 else { throw BencodeError.invalid("empty integer") }
        return negative ? -value : value
    }

    private mutating func readBytes() throws -> Data {
        let len = try readInt(until: UInt8(ascii: ":"))
        guard len >= 0, index + Int(len) <= bytes.count else { throw BencodeError.unexpectedEnd }
        let d = Data(bytes[index..<(index + Int(len))])
        index += Int(len)
        return d
    }
}

public enum BEncoder {
    public static func encode(_ value: BValue) -> Data {
        var out = Data()
        write(value, into: &out)
        return out
    }

    private static func write(_ value: BValue, into out: inout Data) {
        switch value {
        case .int(let v):
            out.append(contentsOf: Array("i\(v)e".utf8))
        case .bytes(let d):
            out.append(contentsOf: Array("\(d.count):".utf8))
            out.append(d)
        case .list(let items):
            out.append(UInt8(ascii: "l"))
            for i in items { write(i, into: &out) }
            out.append(UInt8(ascii: "e"))
        case .dict(let d):
            out.append(UInt8(ascii: "d"))
            // Keys must be sorted as raw byte strings.
            for key in d.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
                write(.bytes(Data(key.utf8)), into: &out)
                write(d[key]!, into: &out)
            }
            out.append(UInt8(ascii: "e"))
        }
    }
}
