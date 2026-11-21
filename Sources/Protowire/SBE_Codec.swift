// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation

/// A marshaller that encodes dictionary-based values into SBE binary format.
public final class SBEMarshaller {
    /// Initializes a new `SBEMarshaller`.
    public init() {}

    /// Marshals the given values into SBE binary format according to the template.
    /// - Parameters:
    ///   - values: The values to encode, indexed by field name.
    ///   - template: The SBE message template to use for encoding.
    /// - Returns: The encoded SBE data.
    /// - Throws: An error if encoding fails.
    public func marshal(_ values: [String: Any], template: SBE.MessageTemplate) throws -> Data {
        var data = Data()
        let header = SBE.MessageHeader(blockLength: UInt16(template.blockLength), templateID: template.templateID, schemaID: template.schemaID, version: template.version)
        SBE.writeHeader(&data, header)
        
        var block = Data(count: template.blockLength)
        for ft in template.fields {
            if let val = values[ft.name] { try writeField(&block, ft, val) }
        }
        data.append(block)
        
        for gt in template.groups {
            let list = (values[gt.name] as? [[String: Any]]) ?? []
            var ghData = Data()
            withUnsafeBytes(of: UInt16(gt.blockLength).littleEndian) { ghData.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt16(list.count).littleEndian) { ghData.append(contentsOf: $0) }
            data.append(ghData)
            
            for entry in list {
                var entryBlock = Data(count: gt.blockLength)
                for ft in gt.fields {
                    if let val = entry[ft.name] { try writeField(&entryBlock, ft, val) }
                }
                data.append(entryBlock)
            }
        }
        return data
    }

    private func writeField(_ block: inout Data, _ ft: SBE.FieldTemplate, _ value: Any) throws {
        if let composite = ft.composite {
            if let subValues = value as? [String: Any] {
                for sf in composite { if let sv = subValues[sf.name] { try writeField(&block, sf, sv, baseOffset: ft.offset) } }
            }
            return
        }
        try writeScalar(&block, ft, value, baseOffset: 0)
    }

    private func writeField(_ block: inout Data, _ ft: SBE.FieldTemplate, _ value: Any, baseOffset: Int) throws {
        if let composite = ft.composite {
            if let subValues = value as? [String: Any] {
                for sf in composite { if let sv = subValues[sf.name] { try writeField(&block, sf, sv, baseOffset: baseOffset + ft.offset) } }
            }
            return
        }
        try writeScalar(&block, ft, value, baseOffset: baseOffset)
    }

    private func writeScalar(_ block: inout Data, _ ft: SBE.FieldTemplate, _ value: Any, baseOffset: Int) throws {
        guard let encoding = ft.encoding else { return }
        let off = baseOffset + ft.offset
        switch encoding {
        case .int8:   block[off] = UInt8(bitPattern: Int8(truncatingIfNeeded: toI64(value)))
        case .uint8:  block[off] = UInt8(truncatingIfNeeded: toU64(value))
        case .int16:  writeLE(Int16(truncatingIfNeeded: toI64(value)), to: &block, at: off)
        case .uint16: writeLE(UInt16(truncatingIfNeeded: toU64(value)), to: &block, at: off)
        case .int32:  writeLE(Int32(truncatingIfNeeded: toI64(value)), to: &block, at: off)
        case .uint32: writeLE(UInt32(truncatingIfNeeded: toU64(value)), to: &block, at: off)
        case .int64:  writeLE(toI64(value), to: &block, at: off)
        case .uint64: writeLE(toU64(value), to: &block, at: off)
        case .float:  writeLE((value as? Float ?? Float(value as? Double ?? 0)).bitPattern, to: &block, at: off)
        case .double: writeLE((value as? Double ?? Double(value as? Float ?? 0)).bitPattern, to: &block, at: off)
        case .char:
            let bytes = ft.isBytes ? Self.rawBytes(value).prefix(ft.size) : SBE.cutString(Array(((value as? String) ?? "").utf8), ft.size)
            for (i, b) in bytes.enumerated() { block[off + i] = b }
            for i in bytes.count..<ft.size { block[off + i] = 0 }
        }
    }

    /// A bytes field's value: `Data`, `[UInt8]`, or a `String`'s UTF-8.
    private static func rawBytes(_ v: Any) -> [UInt8] {
        if let d = v as? Data { return Array(d) }
        if let b = v as? [UInt8] { return b }
        return Array(((v as? String) ?? "").utf8)
    }

    private func toI64(_ v: Any) -> Int64 { if let n = v as? Int64 { return n } else if let n = v as? Int { return Int64(n) } else if let n = v as? Int32 { return Int64(n) } else { return 0 } }
    private func toU64(_ v: Any) -> UInt64 { if let n = v as? UInt64 { return n } else if let n = v as? UInt { return UInt64(n) } else if let n = v as? UInt32 { return UInt64(n) } else { return 0 } }
    private func writeLE<T: FixedWidthInteger>(_ v: T, to d: inout Data, at o: Int) { withUnsafeBytes(of: v.littleEndian) { for i in 0..<MemoryLayout<T>.size { d[o+i] = $0[i] } } }
}

/// An unmarshaller that decodes SBE binary data into dictionary-based values.
public final class SBEUnmarshaller {
    /// The limits for each decode call; the `Hardening` constants by default.
    public var limits = Hardening.Limits()

    /// Initializes a new `SBEUnmarshaller`.
    public init() {}
    
    /// Unmarshals SBE binary data into a dictionary of values according to the template.
    /// - Parameters:
    ///   - data: The SBE data to decode.
    ///   - template: The SBE message template to use for decoding.
    /// - Returns: A dictionary containing the decoded values, indexed by field name.
    /// - Throws: An error if decoding fails.
    public func unmarshal(_ data: Data, template: SBE.MessageTemplate) throws -> [String: Any] {
        try limits.checkMessageSize(data.count)
        guard data.count >= SBE.headerSize else { throw PB.Error.corruptData }
        let header = SBE.readHeader(data)!
        if header.templateID != template.templateID { throw PB.Error.corruptData }
        // A wire block may be longer than the template's (newer schemas append
        // fields), never shorter.
        guard Int(header.blockLength) >= template.blockLength,
              data.count >= SBE.headerSize + Int(header.blockLength) else { throw PB.Error.corruptData }
        var res: [String: Any] = [:]
        let rbStart = data.startIndex + SBE.headerSize
        let rbEnd = rbStart + Int(header.blockLength)
        let rb = data.subdata(in: rbStart..<rbEnd)
        for ft in template.fields { res[ft.name] = try readField(rb, ft) }
        var pos = rbEnd
        for gt in template.groups {
            let (bl, count) = try SBE.readGroupHeader(data, at: pos, entryBlockLength: gt.blockLength, limits: limits)
            pos += SBE.groupHeaderSize
            var list: [[String: Any]] = []
            for _ in 0..<count {
                let ed = data.subdata(in: pos..<pos+bl); var entry: [String: Any] = [:]
                for ft in gt.fields { entry[ft.name] = try readField(ed, ft) }
                list.append(entry); pos += bl
            }
            res[gt.name] = list
        }
        return res
    }

    private func readField(_ block: Data, _ ft: SBE.FieldTemplate, baseOffset: Int = 0) throws -> Any {
        if let composite = ft.composite {
            var sub: [String: Any] = [:]
            for sf in composite { sub[sf.name] = try readField(block, sf, baseOffset: baseOffset + ft.offset) }
            return sub
        }
        guard let enc = ft.encoding else { return NSNull() }
        let off = block.startIndex + baseOffset + ft.offset
        switch enc {
        case .int8: return Int8(bitPattern: block[off])
        case .uint8: return block[off]
        case .int16: return block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off - block.startIndex, as: Int16.self).littleEndian }
        case .uint16: return block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off - block.startIndex, as: UInt16.self).littleEndian }
        case .int32: return block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off - block.startIndex, as: Int32.self).littleEndian }
        case .uint32: return block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off - block.startIndex, as: UInt32.self).littleEndian }
        case .int64: return block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off - block.startIndex, as: Int64.self).littleEndian }
        case .uint64: return block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off - block.startIndex, as: UInt64.self).littleEndian }
        case .float: return Float(bitPattern: block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off - block.startIndex, as: UInt32.self).littleEndian })
        case .double: return Double(bitPattern: block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off - block.startIndex, as: UInt64.self).littleEndian })
        case .char:
            let raw = block[off..<off+ft.size]
            if ft.isBytes { return Data(raw) }
            // HARDENING.md § UTF-8: a string field is valid UTF-8 whatever the
            // source encoding, and a char[] says nothing about its own. Text in
            // another encoding belongs in a bytes field.
            let text = SBE.trimmingTrailingNULs(raw)
            guard SBE.isValidUTF8(text) else { throw DecoderError.invalidUTF8(field: ft.name) }
            return String(decoding: text, as: UTF8.self)
        }
    }
}
