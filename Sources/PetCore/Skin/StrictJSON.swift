import Foundation

public struct SkinError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

indirect enum JSONValue {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(String), bool(Bool), null
}

public enum StrictJSON {
    public static func validate(_ data: Data) throws { _ = try parse(data) }
    public static func validate(_ data: Data, maximumBytes: Int) throws { _ = try parse(data, maximumBytes: maximumBytes) }
    static func parse(_ data: Data, maximumBytes: Int = 131072) throws -> JSONValue {
        guard !data.isEmpty, maximumBytes > 0, data.count <= maximumBytes else { throw SkinError(maximumBytes == 131072 ? "JSON 为空或超过 128 KiB" : "JSON 为空或超过允许大小") }
        var bytes = Array(data)
        if bytes.starts(with:[239,187,191]) { bytes.removeFirst(3) }
        guard String(bytes:bytes,encoding:.utf8) != nil else { throw SkinError("JSON 必须使用有效 UTF-8") }
        var parser = Parser(bytes: bytes)
        let value = try parser.value(depth:0)
        parser.space()
        guard parser.i == bytes.count else { throw SkinError("JSON 存在多余内容") }
        return value
    }
    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        mutating func space() { while i < bytes.count && [9,10,13,32].contains(bytes[i]) { i += 1 } }
        mutating func take(_ byte: UInt8) -> Bool { space(); if i < bytes.count && bytes[i] == byte { i += 1; return true }; return false }
        mutating func require(_ byte: UInt8) throws { guard take(byte) else { throw SkinError("JSON 语法错误，字节 \(i)") } }
        mutating func string() throws -> String {
            space(); let start = i; try require(34)
            while i < bytes.count {
                if bytes[i] == 34 {
                    i += 1
                    do { return try JSONDecoder().decode(String.self,from:Data(bytes[start..<i])) }
                    catch { throw SkinError("JSON 字符串或转义无效") }
                }
                if bytes[i] < 32 { throw SkinError("JSON 字符串含未转义控制符") }
                if bytes[i] == 92 { i += 1 }
                i += 1
            }
            throw SkinError("JSON 字符串未结束")
        }
        mutating func value(depth: Int) throws -> JSONValue {
            space(); guard i < bytes.count else { throw SkinError("JSON 意外结束") }
            if bytes[i] == 123 {
                guard depth < 64 else { throw SkinError("JSON 嵌套超过 64 层") }
                i += 1; var object: [String:JSONValue] = [:]; var keys = Set<String>()
                if take(125) { return .object(object) }
                repeat {
                    let key = try string()
                    guard keys.insert(key.lowercased()).inserted else { throw SkinError("JSON 字段重复：\(key)") }
                    try require(58); object[key] = try value(depth:depth+1)
                    if take(125) { return .object(object) }
                    try require(44)
                } while true
            }
            if bytes[i] == 91 {
                guard depth < 64 else { throw SkinError("JSON 嵌套超过 64 层") }
                i += 1; var array: [JSONValue] = []
                if take(93) { return .array(array) }
                repeat {
                    array.append(try value(depth:depth+1))
                    if take(93) { return .array(array) }
                    try require(44)
                } while true
            }
            if bytes[i] == 34 { return .string(try string()) }
            for (literal,result) in [("true",JSONValue.bool(true)),("false",.bool(false)),("null",.null)] {
                let pattern = Array(literal.utf8)
                if bytes[i...].starts(with:pattern) { i += pattern.count; return result }
            }
            let start = i
            if bytes[i] == 45 { i += 1 }
            guard i < bytes.count else { throw SkinError("JSON 数字无效") }
            if bytes[i] == 48 { i += 1 }
            else { guard (49...57).contains(bytes[i]) else { throw SkinError("JSON 值无效") }; while i < bytes.count && (48...57).contains(bytes[i]) { i += 1 } }
            if i < bytes.count && bytes[i] == 46 {
                i += 1; let s=i; while i < bytes.count && (48...57).contains(bytes[i]) { i += 1 }; guard i>s else { throw SkinError("JSON 小数无效") }
            }
            if i < bytes.count && [69,101].contains(bytes[i]) {
                i += 1; if i < bytes.count && [43,45].contains(bytes[i]) { i += 1 }
                let s=i; while i < bytes.count && (48...57).contains(bytes[i]) { i += 1 }; guard i>s else { throw SkinError("JSON 指数无效") }
            }
            return .number(String(decoding:bytes[start..<i],as:UTF8.self))
        }
    }
}
