// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation
import SwiftProtobuf

// How a field's PXF annotations are read off its options, in both spellings.
//
// The bracket form `[(pxf.required) = true]` lowers to extensions 1314 to 1316.
// The annotation form `@required` / `@default(v)` lowers to one AnnotationList
// on extension 1327, and a compiler never writes one form from the other, so a
// reader of the brackets alone binds a migrated schema with nothing enforced.
// The carrier has no generated type here: its shape is small and frozen by
// STABILITY.md promise 3, so this walks the bytes. A descriptor set parsed
// without `Pxf_Annotations_Extensions` leaves the brackets in the same unknown
// bytes, and they are read from there too. Mirrors protowire-go's
// encoding/pxf/annotations.go and carrier.go.

extension PXF {
    /// What a field's options say, in whichever spelling.
    struct FieldAnnotations {
        var required = false
        var requiredFromCarrier = false
        var defaultLiteral: String?
        var defaultFromCarrier = false
        /// Why the field's default can't be used: a carrier argument that is
        /// no single literal, or two spellings that disagree.
        var defaultProblem: String?
        var keyName: String?

        private static let extRequired = 1314
        private static let extDefault = 1315
        private static let extKey = 1316
        private static let extAnnotations = 1327

        static func read(_ fd: Google_Protobuf_FieldDescriptorProto) -> FieldAnnotations {
            var got = FieldAnnotations()
            let options = fd.options
            if options.hasPxf_required { got.required = options.Pxf_required }
            if options.hasPxf_default { got.defaultLiteral = options.Pxf_default }
            if options.hasPxf_key { got.keyName = options.Pxf_key }

            var carrier: [UInt8] = []
            var wire = WireReader(Array(options.unknownFields.data))
            while let f = wire.next() {
                switch f.number {
                case extRequired:
                    if !got.required, let v = f.varint { got.required = v != 0 }
                case extDefault:
                    if got.defaultLiteral == nil, let v = f.bytes { got.defaultLiteral = String(decoding: v, as: UTF8.self) }
                case extKey:
                    if got.keyName == nil, let v = f.bytes { got.keyName = String(decoding: v, as: UTF8.self) }
                case extAnnotations:
                    // A message split across occurrences merges, and this one
                    // holds only a repeated field, so concatenating is the merge.
                    if let v = f.bytes { carrier += v }
                default:
                    break
                }
            }
            if !carrier.isEmpty { got.fold(Carrier.parse(carrier, fd)) }
            return got
        }

        /// Honours both spellings and reconciles neither (RFC-001 §8.5). Either
        /// one makes a field required. Two defaults that differ refuse the
        /// schema, since picking one would give meaning to the spelling.
        private mutating func fold(_ c: Carrier) {
            if c.required {
                if !required { requiredFromCarrier = true }
                required = true
            }
            if let problem = c.problem {
                defaultProblem = problem
                defaultFromCarrier = true
            } else if let def = c.defaultLiteral {
                if let bracket = defaultLiteral {
                    if bracket != def {
                        defaultProblem = "(pxf.default) = \"\(bracket)\" and @default = \"\(def)\" carry different values, and the two surfaces must not be reconciled (RFC-001 §8.5)"
                    }
                } else {
                    defaultLiteral = def
                    defaultFromCarrier = true
                }
            }
        }
    }

    /// One field of a protobuf message, read without a schema.
    struct WireField {
        var number: Int
        var varint: UInt64?
        var fixed64: UInt64?
        var bytes: [UInt8]?
    }

    /// Walks protobuf fields, stopping at the first malformed one and keeping
    /// what came before: a schema is not unannotated because its last byte
    /// was garbled.
    struct WireReader {
        private let b: [UInt8]
        private var i = 0

        init(_ bytes: [UInt8]) { b = bytes }

        private mutating func varint() -> UInt64? {
            var v: UInt64 = 0
            var shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let c = b[i]
                i += 1
                v |= UInt64(c & 0x7F) << shift
                if c & 0x80 == 0 { return v }
                shift += 7
            }
            return nil
        }

        private mutating func take(_ n: Int) -> ArraySlice<UInt8>? {
            guard n >= 0, n <= b.count - i else { return nil }
            defer { i += n }
            return b[i..<(i + n)]
        }

        mutating func next() -> WireField? {
            guard i < b.count, let tag = varint(), tag >> 3 <= UInt64(Int32.max) else { return nil }
            var field = WireField(number: Int(tag >> 3))
            switch tag & 7 {
            case 0:
                guard let v = varint() else { return nil }
                field.varint = v
            case 1:
                guard let s = take(8) else { return nil }
                field.fixed64 = s.reversed().reduce(0) { $0 << 8 | UInt64($1) }
            case 2:
                guard let n = varint(), n <= UInt64(Int.max), let s = take(Int(n)) else { return nil }
                field.bytes = Array(s)
            case 5:
                guard take(4) != nil else { return nil }
            default:
                return nil
            }
            return field
        }
    }

    /// The part of the 1327 AnnotationList this port enforces. Other
    /// annotations belong to validators and documentation generators.
    fileprivate struct Carrier {
        var required = false
        var defaultLiteral: String?
        var problem: String?

        private static let annotationRequired = "protowire.schema.v1.required"
        private static let annotationDefault = "protowire.schema.v1.default"

        static func parse(_ bytes: [UInt8], _ fd: Google_Protobuf_FieldDescriptorProto) -> Carrier {
            var got = Carrier()
            var wire = WireReader(bytes)
            while let f = wire.next() {
                if f.number == 1, let entry = f.bytes { got.apply(entry, fd) }
            }
            return got
        }

        private mutating func apply(_ entry: [UInt8], _ fd: Google_Protobuf_FieldDescriptorProto) {
            var name = ""
            var args: [[UInt8]] = []
            var wire = WireReader(entry)
            while let f = wire.next() {
                if f.number == 1, let v = f.bytes { name = String(decoding: v, as: UTF8.self) }
                if f.number == 2, let v = f.bytes { args.append(v) }
            }
            switch name {
            case Self.annotationRequired:
                required = true
            case Self.annotationDefault:
                if defaultLiteral != nil || problem != nil { return } // A second one is the compiler's to reject.
                guard let arg = args.first(where: { ["", "value"].contains(Self.argName($0)) }) else {
                    problem = "@default carries no value argument"
                    return
                }
                switch Self.literal(arg, fd) {
                case .success(let v): defaultLiteral = v
                case .failure(let p): problem = p.message
                }
            default:
                break
            }
        }

        private static func argName(_ arg: [UInt8]) -> String {
            var wire = WireReader(arg)
            while let f = wire.next() {
                if f.number == 1, let v = f.bytes { return String(decoding: v, as: UTF8.self) }
            }
            return ""
        }

        private struct Problem: Error {
            let message: String
            init(_ message: String) { self.message = message }
        }

        /// An AnnotationArg as the literal the bracket form would carry, so
        /// everything downstream is shared between the two spellings.
        private static func literal(_ arg: [UInt8], _ fd: Google_Protobuf_FieldDescriptorProto) -> Swift.Result<String, Problem> {
            var wire = WireReader(arg)
            while let f = wire.next() {
                switch f.number {
                case 10:
                    if let v = f.bytes { return .success(String(decoding: v, as: UTF8.self)) }
                case 11:
                    // AnnotationArg has no unsigned member: a large unsigned
                    // literal arrives reinterpreted through int64.
                    if let v = f.varint {
                        return .success(unsignedTarget(fd) ? String(v) : String(Int64(bitPattern: v)))
                    }
                case 12:
                    if let v = f.fixed64 {
                        return .success(GoFloat.format(Double(bitPattern: v), positional: exactDecimalTarget(fd)))
                    }
                case 13:
                    if let v = f.varint { return .success(v != 0 ? "true" : "false") }
                case 14:
                    if let v = f.bytes { return .success(Data(v).base64EncodedString()) }
                case 15:
                    if let v = f.bytes { return enumLiteral(v) }
                case 16:
                    if let v = f.bytes { return bigIntLiteral(v) }
                case 17:
                    if let v = f.bytes { return decimalLiteral(v) }
                case 18:
                    if let v = f.bytes {
                        guard let number = try? Pxf_BigFloat(serializedBytes: Data(v)) else {
                            return .failure(Problem("@default's big_float_value is not well-formed"))
                        }
                        guard number.prec != 0 else {
                            return .failure(Problem("@default's big_float_value declares no precision"))
                        }
                        guard let literal = try? number.pxfLiteral else {
                            return .failure(Problem("@default's big_float_value is past the limits of a literal"))
                        }
                        return .success(literal)
                    }
                default:
                    break
                }
            }
            return .failure(Problem("@default's value is empty"))
        }

        private static func enumLiteral(_ literal: [UInt8]) -> Swift.Result<String, Problem> {
            var wire = WireReader(literal)
            while let f = wire.next() {
                guard f.number == 1, let v = f.bytes else { continue }
                var inner = WireReader(v)
                while let g = inner.next() {
                    if g.number == 2, let name = g.bytes, !name.isEmpty {
                        return .success(String(decoding: name, as: UTF8.self))
                    }
                }
                return .failure(Problem("@default names an enum value the lowering pass left unresolved"))
            }
            return .failure(Problem("@default carries a message or list literal, and a default is exactly one literal"))
        }

        private static func unsignedTarget(_ fd: Google_Protobuf_FieldDescriptorProto) -> Bool {
            switch fd.type {
            case .uint32, .fixed32, .uint64, .fixed64: return true
            case .message: return [".google.protobuf.UInt32Value", ".google.protobuf.UInt64Value"].contains(fd.typeName)
            default: return false
            }
        }

        private static func exactDecimalTarget(_ fd: Google_Protobuf_FieldDescriptorProto) -> Bool {
            fd.type == .message && [".pxf.BigInt", ".pxf.Decimal"].contains(fd.typeName)
        }

        /// The magnitude's decimal digits. A descriptor is untrusted and this
        /// is quadratic, so a magnitude past the literal digit cap is refused
        /// here. The reference converts it, and fails when the default is read.
        private static func digits(_ magnitude: [UInt8]) -> String? {
            let width = magnitude.drop { $0 == 0 }
            guard width.count <= Hardening.maxNumericLiteralDigits else { return nil }
            var limbs = Array(width)
            var chunks: [UInt32] = []
            while !limbs.isEmpty {
                var remainder: UInt64 = 0
                var quotient: [UInt8] = []
                quotient.reserveCapacity(limbs.count)
                for byte in limbs {
                    let v = remainder << 8 | UInt64(byte)
                    let q = v / 1_000_000_000
                    remainder = v % 1_000_000_000
                    if !quotient.isEmpty || q != 0 { quotient.append(UInt8(q)) }
                }
                chunks.append(UInt32(remainder))
                limbs = quotient
            }
            guard let top = chunks.popLast() else { return "0" }
            var out = String(top)
            for chunk in chunks.reversed() {
                let s = String(chunk)
                out += String(repeating: "0", count: 9 - s.count) + s
            }
            return out
        }

        private static func bigIntLiteral(_ b: [UInt8]) -> Swift.Result<String, Problem> {
            var abs: [UInt8] = []
            var negative = false
            var wire = WireReader(b)
            while let f = wire.next() {
                if f.number == 1, let v = f.bytes { abs = v }
                if f.number == 2, let v = f.varint { negative = v != 0 }
            }
            guard let d = digits(abs) else { return .failure(Problem("@default's big_int_value exceeds MaxNumericLiteralDigits")) }
            return .success(negative && d != "0" ? "-" + d : d)
        }

        private static func decimalLiteral(_ b: [UInt8]) -> Swift.Result<String, Problem> {
            var unscaled: [UInt8] = []
            var scale: Int32 = 0
            var negative = false
            var wire = WireReader(b)
            while let f = wire.next() {
                if f.number == 1, let v = f.bytes { unscaled = v }
                if f.number == 2, let v = f.varint { scale = Int32(truncatingIfNeeded: v) }
                if f.number == 3, let v = f.varint { negative = v != 0 }
            }
            // The bound comes first: the work below follows a number, not the
            // carrier's length.
            let limit = Hardening.maxNumericLiteralDigits
            guard Int(scale) <= limit, Int(scale) >= -limit else {
                return .failure(Problem("@default's decimal_value has scale \(scale), and MaxNumericLiteralDigits=\(limit) bounds its magnitude"))
            }
            guard let d = digits(unscaled) else { return .failure(Problem("@default's decimal_value exceeds MaxNumericLiteralDigits")) }
            let sign = negative && d != "0" ? "-" : ""
            if scale < 0 { return .success(sign + (d == "0" ? d : d + String(repeating: "0", count: Int(-scale)))) }
            if scale == 0 { return .success(sign + d) }
            let padded = String(repeating: "0", count: max(0, Int(scale) + 1 - d.count)) + d
            let split = padded.index(padded.endIndex, offsetBy: -Int(scale))
            return .success(sign + padded[..<split] + "." + padded[split...])
        }
    }

    /// Go's `strconv.FormatFloat(v, 'g', -1, 64)`, or 'f' for `positional`,
    /// because two spellings of a default are compared as text.
    enum GoFloat {
        static func format(_ v: Double, positional: Bool) -> String {
            if v.isNaN { return "NaN" }
            if v.isInfinite { return v < 0 ? "-Inf" : "+Inf" }
            let sign = v.sign == .minus ? "-" : ""
            if v == 0 { return sign + "0" }
            let (digits, exponent) = shortest(abs(v))
            // Shortest 'g' switches to %e at exponent 6, whatever the digit count.
            if !positional, exponent < -4 || exponent >= 6 {
                var out = sign + String(digits.prefix(1))
                if digits.count > 1 { out += "." + digits.dropFirst() }
                let e = abs(exponent)
                return out + "e" + (exponent < 0 ? "-" : "+") + (e < 10 ? "0" : "") + String(e)
            }
            if exponent < 0 {
                return sign + "0." + String(repeating: "0", count: -exponent - 1) + digits
            }
            if digits.count <= exponent + 1 {
                return sign + digits + String(repeating: "0", count: exponent + 1 - digits.count)
            }
            let split = digits.index(digits.startIndex, offsetBy: exponent + 1)
            return sign + digits[..<split] + "." + digits[split...]
        }

        /// The shortest round-trip digits and the decimal exponent of the first.
        private static func shortest(_ v: Double) -> (digits: String, exponent: Int) {
            var text = "\(v)"
            var exponent = 0
            if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
                exponent = Int(text[text.index(after: e)...]) ?? 0
                text = String(text[..<e])
            }
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            let whole = String(parts[0])
            let fraction = parts.count > 1 ? String(parts[1]) : ""
            var digits = whole + fraction
            exponent += whole.count - 1
            let leading = digits.prefix { $0 == "0" }.count
            digits = String(digits.dropFirst(leading))
            exponent -= leading
            while digits.count > 1, digits.hasSuffix("0") { digits.removeLast() }
            return (digits, exponent)
        }
    }

    /// Standard and URL-safe alphabets, with or without padding, as a bytes
    /// literal reads them. One input can't mix the two alphabets.
    static func decodeBase64Lenient(_ raw: String) -> Data? {
        let urlSafe = raw.contains("-") || raw.contains("_")
        if urlSafe, raw.contains("+") || raw.contains("/") { return nil }
        var text = urlSafe ? raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") : raw
        if !text.contains("="), text.utf8.count % 4 != 0 {
            text += String(repeating: "=", count: 4 - text.utf8.count % 4)
        }
        return Data(base64Encoded: text)
    }
}
