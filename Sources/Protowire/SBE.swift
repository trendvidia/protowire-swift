// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

/// A namespace for SBE (Simple Binary Encoding) related types and utilities.
public enum SBE {
    /// The size of the SBE message header in bytes.
    public static let headerSize: Int = 8
    /// The size of the SBE group header in bytes.
    public static let groupHeaderSize: Int = 4

    /// Represents the primitive encoding types supported by SBE.
    public enum Encoding: String {
        case int8, int16, int32, int64
        case uint8, uint16, uint32, uint64
        case float, double, char
    }

    /// Represents the header of an SBE message.
    public struct MessageHeader: Equatable {
        /// The length of the root block in bytes.
        public var blockLength: UInt16
        /// The template identifier.
        public var templateID: UInt16
        /// The schema identifier.
        public var schemaID: UInt16
        /// The schema version.
        public var version: UInt16

        /// Initializes a new `MessageHeader`.
        public init(blockLength: UInt16, templateID: UInt16, schemaID: UInt16, version: UInt16) {
            self.blockLength = blockLength
            self.templateID = templateID
            self.schemaID = schemaID
            self.version = version
        }
    }

    /// Represents the header of an SBE group.
    public struct GroupHeader: Equatable {
        /// The length of each block in the group in bytes.
        public var blockLength: UInt16
        /// The number of entries in the group.
        public var numInGroup: UInt16

        /// Initializes a new `GroupHeader`.
        public init(blockLength: UInt16, numInGroup: UInt16) {
            self.blockLength = blockLength
            self.numInGroup = numInGroup
        }
    }

    // MARK: - Primitives

    /// Reads an SBE message header from the given data.
    /// - Parameter data: The data to read from.
    /// - Returns: The decoded `MessageHeader`, or `nil` if the data is too short.
    public static func readHeader(_ data: Data) -> MessageHeader? {
        guard data.count >= headerSize else { return nil }
        return MessageHeader(
            blockLength: data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt16.self).littleEndian },
            templateID:  data.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self).littleEndian },
            schemaID:    data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self).littleEndian },
            version:     data.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).littleEndian }
        )
    }

    /// Writes an SBE message header to the given buffer.
    /// - Parameters:
    ///   - buffer: The buffer to write to.
    ///   - header: The header to encode.
    public static func writeHeader(_ buffer: inout Data, _ header: MessageHeader) {
        let bl = header.blockLength.littleEndian
        let tid = header.templateID.littleEndian
        let sid = header.schemaID.littleEndian
        let ver = header.version.littleEndian
        withUnsafeBytes(of: bl) { buffer.append(contentsOf: $0) }
        withUnsafeBytes(of: tid) { buffer.append(contentsOf: $0) }
        withUnsafeBytes(of: sid) { buffer.append(contentsOf: $0) }
        withUnsafeBytes(of: ver) { buffer.append(contentsOf: $0) }
    }
}
