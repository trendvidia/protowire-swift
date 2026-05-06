import Foundation

extension SBE {
    /// A view-based reader for SBE encoded data.
    public struct View {
        private let data: Data
        private let block: Data
        private let schema: ViewSchema

        internal init(data: Data, block: Data, schema: ViewSchema) {
            self.data = data
            self.block = block
            self.schema = schema
        }

        /// Initializes a new view from data and a template.
        public init(data: Data, template: MessageTemplate) throws {
            guard data.count >= SBE.headerSize else { throw PB.Error.corruptData }
            let bl = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self).littleEndian })
            let tid = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self).littleEndian }
            
            guard tid == template.templateID else { throw PB.Error.corruptData }
            guard data.count >= SBE.headerSize + bl else { throw PB.Error.corruptData }
            
            self.data = data
            let start = data.startIndex + SBE.headerSize
            self.block = data.subdata(in: start..<(start + bl))
            self.schema = template.view!
        }

        private func getField(_ name: String) -> FieldTemplate {
            guard let ft = schema.fieldMap[name] else { fatalError("SBE: unknown field \(name)") }
            return ft
        }

        /// Returns a signed integer value for a field.
        public func int(_ name: String) -> Int64 {
            let ft = getField(name)
            let off = block.startIndex + ft.offset
            switch ft.encoding {
            case .int8:   return Int64(Int8(bitPattern: block[off]))
            case .int16:  return Int64(block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off - block.startIndex, as: Int16.self).littleEndian })
            case .int32:  return Int64(block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off - block.startIndex, as: Int32.self).littleEndian })
            case .int64:  return block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off - block.startIndex, as: Int64.self).littleEndian }
            default:      fatalError("SBE: field \(name) is not a signed integer")
            }
        }

        /// Returns an unsigned integer value for a field.
        public func uint(_ name: String) -> UInt64 {
            let ft = getField(name)
            let off = block.startIndex + ft.offset
            switch ft.encoding {
            case .uint8:  return UInt64(block[off])
            case .uint16: return UInt64(block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off - block.startIndex, as: UInt16.self).littleEndian })
            case .uint32: return UInt64(block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off - block.startIndex, as: UInt32.self).littleEndian })
            case .uint64: return block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off - block.startIndex, as: UInt64.self).littleEndian }
            default:      fatalError("SBE: field \(name) is not an unsigned integer")
            }
        }

        /// Returns a float value for a field.
        public func float(_ name: String) -> Float {
            let ft = getField(name)
            let off = block.startIndex + ft.offset
            guard ft.encoding == .float else { fatalError("SBE: field \(name) is not a float") }
            return Float(bitPattern: block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off - block.startIndex, as: UInt32.self).littleEndian })
        }

        /// Returns a double value for a field.
        public func double(_ name: String) -> Double {
            let ft = getField(name)
            let off = block.startIndex + ft.offset
            guard ft.encoding == .double else { fatalError("SBE: field \(name) is not a double") }
            return Double(bitPattern: block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off - block.startIndex, as: UInt64.self).littleEndian })
        }

        /// Returns a boolean value for a field.
        public func bool(_ name: String) -> Bool {
            let ft = getField(name)
            return block[block.startIndex + ft.offset] != 0
        }

        /// Returns a string value for a field.
        public func string(_ name: String) -> String {
            let ft = getField(name)
            let off = block.startIndex + ft.offset
            let raw = block.subdata(in: off..<(off + ft.size))
            return String(data: raw, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
        }

        /// Returns binary data for a field.
        public func bytes(_ name: String) -> Data {
            let ft = getField(name)
            let off = block.startIndex + ft.offset
            return block.subdata(in: off..<(off + ft.size))
        }

        /// Returns a view for a composite field.
        public func composite(_ name: String) -> View {
            let ft = getField(name)
            guard let cv = ft.compositeView else { fatalError("SBE: field \(name) is not a composite") }
            let off = block.startIndex + ft.offset
            return View(data: data, block: block.subdata(in: off..<(off + ft.size)), schema: cv)
        }

        /// Returns a view for a group.
        public func group(_ name: String) -> GroupView {
            var pos = data.startIndex + SBE.headerSize + block.count
            for gn in schema.groupOrder {
                let bl = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos - data.startIndex, as: UInt16.self).littleEndian })
                let count = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos + 2 - data.startIndex, as: UInt16.self).littleEndian })
                if gn == name {
                    return GroupView(data: data.subdata(in: pos..<data.endIndex), blockLength: bl, count: count, schema: schema.groupMap[name]!)
                }
                pos += SBE.groupHeaderSize + count * bl
            }
            fatalError("SBE: unknown group \(name)")
        }
    }

    /// A view-based reader for an SBE group.
    public struct GroupView {
        private let data: Data
        private let blockLength: Int
        private let count: Int
        private let schema: ViewSchema

        internal init(data: Data, blockLength: Int, count: Int, schema: ViewSchema) {
            self.data = data
            self.blockLength = blockLength
            self.count = count
            self.schema = schema
        }

        /// Returns the number of entries in the group.
        public var countEntries: Int { count }

        /// Returns a view for an entry in the group.
        public func entry(_ i: Int) -> View {
            guard i < count else { fatalError("SBE: group index out of bounds") }
            let start = data.startIndex + SBE.groupHeaderSize + i * blockLength
            return View(data: data, block: data.subdata(in: start..<(start + blockLength)), schema: schema)
        }
    }
}
