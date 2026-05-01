import Foundation

/// A namespace for Protowire encoding and decoding utilities.
public enum Protowire {
    /// The type used for field numbers in Protowire.
    public typealias Number = Int32

    /// Represents the wire types supported by the Protowire protocol.
    public enum WireType: Int8 {
        /// Variable-length integer.
        case varint = 0
        /// 64-bit fixed-length value.
        case fixed64 = 1
        /// Length-delimited bytes.
        case bytes = 2
        /// Start of a group (deprecated).
        case startGroup = 3
        /// End of a group (deprecated).
        case endGroup = 4
        /// 32-bit fixed-length value.
        case fixed32 = 5
    }

    /// The minimum valid field number.
    public static let minValidNumber: Number = 1
    /// The maximum valid field number.
    public static let maxValidNumber: Number = (1 << 29) - 1

    // MARK: - Varint

    /// Appends a 64-bit unsigned integer as a varint to the given buffer.
    /// - Parameters:
    ///   - buffer: The data buffer to append to.
    ///   - value: The value to encode.
    public static func appendVarint(_ buffer: inout Data, _ value: UInt64) {
        var v = value
        while v >= 0x80 {
            buffer.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        buffer.append(UInt8(v))
    }

    /// Consumes a varint from the beginning of the given data.
    /// - Parameter data: The data to read from.
    /// - Returns: A tuple containing the decoded value and the number of bytes consumed, or `nil` if decoding failed.
    public static func consumeVarint(_ data: Data) -> (value: UInt64, length: Int)? {
        var value: UInt64 = 0
        var shift: Int = 0
        for (i, byte) in data.enumerated() {
            if i >= 10 { return nil } // Too many bytes for 64-bit varint
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return (value, i + 1)
            }
            shift += 7
        }
        return nil
    }

    // MARK: - Tag

    /// Encodes a field number and wire type into a tag.
    /// - Parameters:
    ///   - number: The field number.
    ///   - type: The wire type.
    /// - Returns: The encoded tag value.
    public static func encodeTag(number: Number, type: WireType) -> UInt64 {
        return (UInt64(number) << 3) | UInt64(type.rawValue)
    }

    /// Appends an encoded tag to the given buffer.
    /// - Parameters:
    ///   - buffer: The data buffer to append to.
    ///   - number: The field number.
    ///   - type: The wire type.
    public static func appendTag(_ buffer: inout Data, number: Number, type: WireType) {
        appendVarint(&buffer, encodeTag(number: number, type: type))
    }

    /// Consumes a tag from the beginning of the given data.
    /// - Parameter data: The data to read from.
    /// - Returns: A tuple containing the field number, wire type, and the number of bytes consumed, or `nil` if decoding failed.
    public static func consumeTag(_ data: Data) -> (number: Number, type: WireType, length: Int)? {
        guard let (tag, n) = consumeVarint(data) else { return nil }
        let wireTypeRaw = Int8(tag & 0x07)
        guard let wireType = WireType(rawValue: wireTypeRaw) else { return nil }
        let number = Number(tag >> 3)
        if number < minValidNumber || number > maxValidNumber { return nil }
        return (number, wireType, n)
    }

    // MARK: - ZigZag

    /// Encodes a signed 64-bit integer using ZigZag encoding.
    /// - Parameter value: The value to encode.
    /// - Returns: The ZigZag-encoded unsigned integer.
    public static func encodeZigZag(_ value: Int64) -> UInt64 {
        return UInt64((value << 1) ^ (value >> 63))
    }

    /// Decodes a ZigZag-encoded unsigned integer into a signed 64-bit integer.
    /// - Parameter value: The ZigZag-encoded value.
    /// - Returns: The decoded signed 64-bit integer.
    public static func decodeZigZag(_ value: UInt64) -> Int64 {
        return Int64(value >> 1) ^ -Int64(value & 1)
    }

    // MARK: - Fixed Size

    /// Appends a 32-bit fixed-length integer to the given buffer in little-endian format.
    /// - Parameters:
    ///   - buffer: The data buffer to append to.
    ///   - value: The value to append.
    public static func appendFixed32(_ buffer: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { buffer.append(contentsOf: $0) }
    }

    /// Consumes a 32-bit fixed-length integer from the beginning of the given data.
    /// - Parameter data: The data to read from.
    /// - Returns: A tuple containing the decoded value and the number of bytes consumed (always 4), or `nil` if the data is too short.
    public static func consumeFixed32(_ data: Data) -> (value: UInt32, length: Int)? {
        guard data.count >= 4 else { return nil }
        let value = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        return (UInt32(littleEndian: value), 4)
    }

    /// Appends a 64-bit fixed-length integer to the given buffer in little-endian format.
    /// - Parameters:
    ///   - buffer: The data buffer to append to.
    ///   - value: The value to append.
    public static func appendFixed64(_ buffer: inout Data, _ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { buffer.append(contentsOf: $0) }
    }

    /// Consumes a 64-bit fixed-length integer from the beginning of the given data.
    /// - Parameter data: The data to read from.
    /// - Returns: A tuple containing the decoded value and the number of bytes consumed (always 8), or `nil` if the data is too short.
    public static func consumeFixed64(_ data: Data) -> (value: UInt64, length: Int)? {
        guard data.count >= 8 else { return nil }
        let value = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt64.self) }
        return (UInt64(littleEndian: value), 8)
    }

    // MARK: - Length Delimited

    /// Appends a length-delimited data block to the given buffer.
    /// - Parameters:
    ///   - buffer: The data buffer to append to.
    ///   - value: The data to append.
    public static func appendBytes(_ buffer: inout Data, _ value: Data) {
        appendVarint(&buffer, UInt64(value.count))
        buffer.append(value)
    }

    /// Consumes a length-delimited data block from the beginning of the given data.
    /// - Parameter data: The data to read from.
    /// - Returns: A tuple containing the decoded data and the number of bytes consumed, or `nil` if decoding failed.
    public static func consumeBytes(_ data: Data) -> (value: Data, length: Int)? {
        guard let (len, n) = consumeVarint(data) else { return nil }
        let totalLen = n + Int(len)
        guard data.count >= totalLen else { return nil }
        let start = data.startIndex + n
        let end = data.startIndex + totalLen
        return (data.subdata(in: start..<end), totalLen)
    }

    /// Appends a UTF-8 encoded string as a length-delimited block to the given buffer.
    /// - Parameters:
    ///   - buffer: The data buffer to append to.
    ///   - value: The string to append.
    public static func appendString(_ buffer: inout Data, _ value: String) {
        if let data = value.data(using: .utf8) {
            appendBytes(&buffer, data)
        }
    }

    /// Consumes a UTF-8 encoded string from the beginning of the given data.
    /// - Parameter data: The data to read from.
    /// - Returns: A tuple containing the decoded string and the number of bytes consumed, or `nil` if decoding failed.
    public static func consumeString(_ data: Data) -> (value: String, length: Int)? {
        guard let (bytes, n) = consumeBytes(data) else { return nil }
        guard let s = String(data: bytes, encoding: .utf8) else { return nil }
        return (s, n)
    }
}
