// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import SwiftProtobuf
import XCTest
@testable import Protowire

/// The per-call limits of draft -01 § Mandatory Limits. Each test shows a
/// lowered value refusing what the default accepts.
final class LimitsTests: XCTestCase {
    struct Text: Codable {
        var value: String?
        enum CodingKeys: Int, CodingKey { case value = 1 }
    }
    struct Bytes: Codable {
        var value: Data?
        enum CodingKeys: Int, CodingKey { case value = 1 }
    }
    struct List: Codable {
        var values: [Int32]?
        enum CodingKeys: Int, CodingKey { case values = 1 }
    }
    struct Names: Codable {
        var values: [String]?
        enum CodingKeys: Int, CodingKey { case values = 1 }
    }
    struct Labels: Codable {
        var labels: [String: String]?
        enum CodingKeys: Int, CodingKey { case labels = 1 }
    }
    final class Tree: Codable {
        var child: Tree?
        enum CodingKeys: Int, CodingKey { case child = 1 }
    }
    struct Big: Decodable {
        var big_int: Pxf_BigInt?
        var big_float: Pxf_BigFloat?
        enum CodingKeys: Int, CodingKey { case big_int = 1, big_float = 3 }
    }

    private func pxf(_ limits: Hardening.Limits = .init()) -> PXFDecoder {
        let d = PXFDecoder()
        d.limits = limits
        return d
    }

    private func pb(_ limits: Hardening.Limits = .init()) -> PBDecoder {
        let d = PBDecoder()
        d.limits = limits
        return d
    }

    private func assertRepeatedCount<T>(_ body: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { err in
            guard case DecoderError.repeatedCountExceeded = err else {
                return XCTFail("expected repeatedCountExceeded, got \(err)", file: file, line: line)
            }
        }
    }

    private func assertTooLarge<T>(_ body: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { err in
            guard case DecoderError.messageTooLarge = err else {
                return XCTFail("expected messageTooLarge, got \(err)", file: file, line: line)
            }
        }
    }

    // MARK: - MaxMessageSize

    func testDefaultsAreTheDraftsConstants() {
        let l = Hardening.Limits()
        XCTAssertEqual(l.maxMessageSize, 67_108_864)
        XCTAssertEqual(l.maxBytesLiteralLength, 67_108_864)
        XCTAssertEqual(l.maxRepeatedCount, 67_108_864)
        XCTAssertEqual(l.maxNestingDepth, 100)
        XCTAssertEqual(l.maxNumericLiteralDigits, 4096)
        XCTAssertEqual(l.maxBigFloatExponent, 16384)
    }

    func testPXFMessageSize() throws {
        let doc = Data(#"value = "0123456789""#.utf8)
        XCTAssertNoThrow(try pxf().decode(Text.self, from: doc))
        XCTAssertNoThrow(try pxf(.init(maxMessageSize: doc.count)).decode(Text.self, from: doc))
        assertTooLarge(try pxf(.init(maxMessageSize: doc.count - 1)).decode(Text.self, from: doc))
        let text = String(decoding: doc, as: UTF8.self)
        assertTooLarge(try pxf(.init(maxMessageSize: doc.count - 1)).decode(Text.self, from: text))
        assertTooLarge(try pxf(.init(maxMessageSize: doc.count - 1)).unmarshalFull(Text.self, from: text))
    }

    func testSchemaLessParseMessageSize() throws {
        let parser = PXF.Parser(string: "a = 1")
        parser.limits.maxMessageSize = 4
        assertTooLarge(try parser.parseDocument())
    }

    func testPBMessageSize() throws {
        let bytes = try PBEncoder().encode(Text(value: "0123456789"))
        XCTAssertNoThrow(try pb().decode(Text.self, from: bytes))
        XCTAssertNoThrow(try pb(.init(maxMessageSize: bytes.count)).decode(Text.self, from: bytes))
        assertTooLarge(try pb(.init(maxMessageSize: bytes.count - 1)).decode(Text.self, from: bytes))
    }

    private let sbeTemplate = SBE.MessageTemplate(
        templateID: 7, schemaID: 1, version: 0, blockLength: 4,
        fields: [SBE.FieldTemplate(name: "a", offset: 0, size: 4, encoding: .uint32)],
        groups: [SBE.GroupTemplate(name: "g", blockLength: 4,
                                   fields: [SBE.FieldTemplate(name: "b", offset: 0, size: 4, encoding: .uint32)])])

    /// Header, root block, group header and `count` entries.
    private func sbeMessage(count: Int) throws -> Data {
        let entries = (0..<count).map { ["b": UInt32($0)] as [String: Any] }
        return try SBEMarshaller().marshal(["a": UInt32(1), "g": entries], template: sbeTemplate)
    }

    func testSBEMessageSize() throws {
        let bytes = try sbeMessage(count: 2)
        let u = SBEUnmarshaller()
        XCTAssertNoThrow(try u.unmarshal(bytes, template: sbeTemplate))
        u.limits.maxMessageSize = bytes.count - 1
        assertTooLarge(try u.unmarshal(bytes, template: sbeTemplate))
        XCTAssertNoThrow(try SBE.View(data: bytes, template: sbeTemplate))
        assertTooLarge(try SBE.View(data: bytes, template: sbeTemplate, limits: .init(maxMessageSize: bytes.count - 1)))
    }

    /// One byte over the default. Every byte of this input is zero, which no
    /// format would get far with, so reaching `messageTooLarge` shows the size
    /// was checked first. `Data(count:)` does not touch the pages.
    func testDefaultRefusesOneByteOver64MiB() throws {
        let input = Data(count: Hardening.maxMessageSize + 1)
        assertTooLarge(try pxf().decode(Text.self, from: input))
        assertTooLarge(try pb().decode(Text.self, from: input))
        assertTooLarge(try SBEUnmarshaller().unmarshal(input, template: sbeTemplate))
        assertTooLarge(try SBE.View(data: input, template: sbeTemplate))
    }

    // MARK: - MaxBytesLiteralLength

    func testBytesLiteralLength() throws {
        let doc = "value = b\"\(Data(count: 12).base64EncodedString())\""
        XCTAssertEqual(try pxf().decode(Bytes.self, from: doc).value?.count, 12)
        XCTAssertNoThrow(try pxf(.init(maxBytesLiteralLength: 12)).decode(Bytes.self, from: doc))
        XCTAssertThrowsError(try pxf(.init(maxBytesLiteralLength: 11)).decode(Bytes.self, from: doc)) { err in
            guard case DecoderError.bytesLiteralTooLong(let decoded, let limit) = err else {
                return XCTFail("expected bytesLiteralTooLong, got \(err)")
            }
            XCTAssertEqual(decoded, 12)
            XCTAssertEqual(limit, 11)
        }
    }

    /// Refused on its length: this body is not valid base64, so a decode
    /// would have failed differently.
    func testBytesLiteralIsRefusedBeforeDecoding() throws {
        let doc = "value = b\"\(String(repeating: "!", count: 16))\""
        XCTAssertThrowsError(try pxf(.init(maxBytesLiteralLength: 4)).decode(Bytes.self, from: doc)) { err in
            guard case DecoderError.bytesLiteralTooLong = err else {
                return XCTFail("expected bytesLiteralTooLong, got \(err)")
            }
        }
    }

    func testBytesLiteralInProtoDirective() throws {
        let doc = "@proto b\"\(Data(count: 12).base64EncodedString())\"\n"
        XCTAssertNoThrow(try PXF.Parser(string: doc).parseDocument())
        let parser = PXF.Parser(string: doc)
        parser.limits.maxBytesLiteralLength = 11
        XCTAssertThrowsError(try parser.parseDocument())
    }

    // MARK: - MaxRepeatedCount

    func testPXFList() throws {
        let doc = "values = [1, 2, 3]"
        XCTAssertEqual(try pxf().decode(List.self, from: doc).values ?? [], [1, 2, 3])
        XCTAssertNoThrow(try pxf(.init(maxRepeatedCount: 3)).decode(List.self, from: doc))
        assertRepeatedCount(try pxf(.init(maxRepeatedCount: 2)).decode(List.self, from: doc))
    }

    func testPXFMap() throws {
        let doc = #"labels = { a: "1" b: "2" c: "3" }"#
        XCTAssertNoThrow(try pxf(.init(maxRepeatedCount: 3)).decode(Labels.self, from: doc))
        assertRepeatedCount(try pxf(.init(maxRepeatedCount: 2)).decode(Labels.self, from: doc))
    }

    func testPXFCountsAcrossBindings() throws {
        let lists = "values = [1, 2]\nvalues = [3]"
        assertRepeatedCount(try pxf(.init(maxRepeatedCount: 2)).decode(List.self, from: lists))
        let maps = "labels = { a: \"1\" b: \"2\" }\nlabels { c: \"3\" }"
        assertRepeatedCount(try pxf(.init(maxRepeatedCount: 2)).decode(Labels.self, from: maps))
    }

    /// A keyed block's entries are `Block`s, which the parser doesn't count.
    /// They are elements once the schema has turned them into a list.
    func testPXFKeyedEntriesAreCounted() throws {
        struct Anything: Decodable { init(from decoder: Decoder) throws {} }
        let root = Bundle.module.resourceURL!.appendingPathComponent("testdata/conformance")
        let set = try Google_Protobuf_FileDescriptorSet(
            serializedBytes: try Data(contentsOf: root.appendingPathComponent("descriptors/keyed.binpb")),
            extensions: Pxf_Annotations_Extensions)
        let doc = try Data(contentsOf: root.appendingPathComponent("corpus/keyed/roundtrip-keyed.pxf"))
        let decoder = PXFDecoder(annotations: PXF.Annotations(descriptorSet: set), rootMessage: "keyed.v1.Node")
        decoder.limits.maxRepeatedCount = 2
        XCTAssertNoThrow(try decoder.decode(Anything.self, from: doc))
        decoder.limits.maxRepeatedCount = 1
        assertRepeatedCount(try decoder.decode(Anything.self, from: doc))
    }

    func testPXFCountIsPerFieldNotPerDocument() throws {
        struct Two: Decodable { var a: [Int32]; var b: [Int32] }
        XCTAssertNoThrow(try pxf(.init(maxRepeatedCount: 2)).decode(Two.self, from: "a = [1, 2]\nb = [3, 4]"))
    }

    func testPXFMessageBlockIsNotCounted() throws {
        struct Three: Decodable { var a: Int32; var b: Int32; var c: Int32 }
        struct Outer: Decodable { var m: Three }
        XCTAssertNoThrow(try pxf(.init(maxRepeatedCount: 2)).decode(Outer.self, from: "m { a = 1 b = 2 c = 3 }"))
    }

    func testPBPacked() throws {
        let bytes = try PBEncoder().encode(List(values: [1, 2, 3]))
        XCTAssertEqual(try pb().decode(List.self, from: bytes).values ?? [], [1, 2, 3])
        XCTAssertNoThrow(try pb(.init(maxRepeatedCount: 3)).decode(List.self, from: bytes))
        assertRepeatedCount(try pb(.init(maxRepeatedCount: 2)).decode(List.self, from: bytes))
    }

    func testPBUnpackedIsCounted() throws {
        let bytes = Data([0x08, 0x01, 0x08, 0x02, 0x08, 0x03]) // field 1, three varints
        XCTAssertEqual(try pb().decode(List.self, from: bytes).values ?? [], [1, 2, 3])
        assertRepeatedCount(try pb(.init(maxRepeatedCount: 2)).decode(List.self, from: bytes))
    }

    func testPBStrings() throws {
        let bytes = try PBEncoder().encode(Names(values: ["a", "b", "c"]))
        XCTAssertNoThrow(try pb(.init(maxRepeatedCount: 3)).decode(Names.self, from: bytes))
        assertRepeatedCount(try pb(.init(maxRepeatedCount: 2)).decode(Names.self, from: bytes))
    }

    func testPBMap() throws {
        let bytes = try PBEncoder().encode(Labels(labels: ["a": "1", "b": "2", "c": "3"]))
        XCTAssertNoThrow(try pb(.init(maxRepeatedCount: 3)).decode(Labels.self, from: bytes))
        assertRepeatedCount(try pb(.init(maxRepeatedCount: 2)).decode(Labels.self, from: bytes))
    }

    func testSBEGroup() throws {
        let bytes = try sbeMessage(count: 3)
        let u = SBEUnmarshaller()
        XCTAssertEqual((try u.unmarshal(bytes, template: sbeTemplate)["g"] as? [[String: Any]])?.count, 3)
        u.limits.maxRepeatedCount = 3
        XCTAssertNoThrow(try u.unmarshal(bytes, template: sbeTemplate))
        u.limits.maxRepeatedCount = 2
        assertRepeatedCount(try u.unmarshal(bytes, template: sbeTemplate))
        assertRepeatedCount(try SBE.View(data: bytes, template: sbeTemplate, limits: .init(maxRepeatedCount: 2)))
    }

    /// These used to trap or to return a short list.
    func testSBERefusesWhatTheBytesCannotHold() throws {
        var truncated = try sbeMessage(count: 2)
        truncated.removeLast()
        XCTAssertThrowsError(try SBEUnmarshaller().unmarshal(truncated, template: sbeTemplate))
        XCTAssertThrowsError(try SBE.View(data: truncated, template: sbeTemplate))

        var shortBlock = try sbeMessage(count: 0)
        shortBlock[shortBlock.startIndex] = 2
        XCTAssertThrowsError(try SBEUnmarshaller().unmarshal(shortBlock, template: sbeTemplate))
        XCTAssertThrowsError(try SBE.View(data: shortBlock, template: sbeTemplate))

        let header = try sbeMessage(count: 0).prefix(SBE.headerSize)
        XCTAssertThrowsError(try SBEUnmarshaller().unmarshal(header, template: sbeTemplate))
    }

    /// A newer schema's longer wire block is read past, and a slice with a
    /// non-zero start index is still read at the right offsets.
    func testSBEAcceptsLongerWireBlockInASlice() throws {
        let message = try sbeMessage(count: 1)
        var longer = message.prefix(SBE.headerSize)
        longer[longer.startIndex] = 6
        longer.append(contentsOf: message[SBE.headerSize..<(SBE.headerSize + 4)])
        longer.append(contentsOf: [0, 0])
        longer.append(contentsOf: message[(SBE.headerSize + 4)...])
        let sliced = (Data([0xFF, 0xFF]) + longer).dropFirst(2)
        let out = try SBEUnmarshaller().unmarshal(sliced, template: sbeTemplate)
        XCTAssertEqual((out["g"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(try SBE.View(data: sliced, template: sbeTemplate).group("g").countEntries, 1)
    }

    // MARK: - MaxNestingDepth

    func testPXFNestingDepth() throws {
        let doc = String(repeating: "child{", count: 5) + String(repeating: "}", count: 5)
        XCTAssertNoThrow(try pxf().decode(Tree.self, from: doc))
        XCTAssertNoThrow(try pxf(.init(maxNestingDepth: 5)).decode(Tree.self, from: doc))
        XCTAssertThrowsError(try pxf(.init(maxNestingDepth: 4)).decode(Tree.self, from: doc)) { err in
            guard case DecoderError.nestingDepthExceeded = err else {
                return XCTFail("expected nestingDepthExceeded, got \(err)")
            }
        }
    }

    func testPBNestingDepth() throws {
        var bytes = Data()
        for _ in 0..<5 {
            var outer = Data([0x0A])
            Protowire.appendVarint(&outer, UInt64(bytes.count))
            outer.append(bytes)
            bytes = outer
        }
        XCTAssertNoThrow(try pb().decode(Tree.self, from: bytes))
        XCTAssertThrowsError(try pb(.init(maxNestingDepth: 3)).decode(Tree.self, from: bytes)) { err in
            guard case DecoderError.nestingDepthExceeded = err else {
                return XCTFail("expected nestingDepthExceeded, got \(err)")
            }
        }
    }

    // MARK: - MaxNumericLiteralDigits

    func testNumericLiteralDigits() throws {
        let doc = "big_int = 123456"
        XCTAssertNoThrow(try pxf().decode(Big.self, from: doc))
        XCTAssertNoThrow(try pxf(.init(maxNumericLiteralDigits: 6)).decode(Big.self, from: doc))
        XCTAssertThrowsError(try pxf(.init(maxNumericLiteralDigits: 5)).decode(Big.self, from: doc)) { err in
            guard case DecoderError.numericLiteralTooLong(let n, _) = err else {
                return XCTFail("expected numericLiteralTooLong, got \(err)")
            }
            XCTAssertEqual(n, 6)
        }
    }

    /// A decimal or float literal carries the call's limits as an integer
    /// one does: the cap is the call's, not the constant (design call 10).
    func testFloatLiteralsFollowTheCallsLimits() throws {
        struct Numbers: Decodable {
            var d: Pxf_Decimal?
            var f: Pxf_BigFloat?
        }
        for doc in ["d = 1.23456", "f = 1.23456"] {
            XCTAssertNoThrow(try pxf(.init(maxNumericLiteralDigits: 6)).decode(Numbers.self, from: doc), doc)
            XCTAssertThrowsError(try pxf(.init(maxNumericLiteralDigits: 5)).decode(Numbers.self, from: doc), doc) { err in
                guard case DecoderError.numericLiteralTooLong(let n, 5) = err else {
                    return XCTFail("\(doc): expected numericLiteralTooLong, got \(err)")
                }
                XCTAssertEqual(n, 6)
            }
        }
        XCTAssertNoThrow(try pxf().decode(Numbers.self, from: "f = 1e30"))
        XCTAssertThrowsError(try pxf(.init(maxBigFloatExponent: 8)).decode(Numbers.self, from: "f = 1e30"))
    }

    /// The cap is for big-number fields. An `int64` fails on range instead.
    func testDigitCapLeavesFixedWidthFieldsAlone() throws {
        struct Plain: Decodable { var n: Int64 }
        XCTAssertEqual(try pxf(.init(maxNumericLiteralDigits: 2)).decode(Plain.self, from: "n = 123456").n, 123456)
    }

    func testParsedLiteralEqualityIgnoresTheCap() throws {
        let lowered = PXF.Parser(string: "a = 1")
        lowered.limits.maxNumericLiteralDigits = 2
        let a = try lowered.parseDocument()
        let b = try PXF.Parser(string: "a = 1").parseDocument()
        XCTAssertEqual(a.entries.count, 1)
        XCTAssertTrue((a.entries[0] as! PXF.Assignment).value.isEqual(to: (b.entries[0] as! PXF.Assignment).value))
    }

    // MARK: - MaxBigFloatExponent

    /// `big_float { mantissa = 0x01, exponent = e }` as protobuf bytes.
    private func bigFloat(exponent: Int32) -> Data {
        var inner = Data([0x0A, 0x01, 0x01, 0x10])
        Protowire.appendVarint(&inner, UInt64(bitPattern: Int64(exponent)))
        var out = Data([0x1A])
        Protowire.appendVarint(&out, UInt64(inner.count))
        out.append(inner)
        return out
    }

    func testBigFloatExponent() throws {
        // A one-bit mantissa, so the binary exponent is exponent + 1.
        XCTAssertNoThrow(try pb().decode(Big.self, from: bigFloat(exponent: 16383)))
        XCTAssertNoThrow(try pb().decode(Big.self, from: bigFloat(exponent: -16385)))
        for e: Int32 in [16384, -16386, .max, .min] {
            XCTAssertThrowsError(try pb().decode(Big.self, from: bigFloat(exponent: e)), "\(e)") { err in
                guard case DecoderError.bigFloatExponentExceeded = err else {
                    return XCTFail("expected bigFloatExponentExceeded, got \(err)")
                }
            }
        }
        XCTAssertNoThrow(try pb(.init(maxBigFloatExponent: 11)).decode(Big.self, from: bigFloat(exponent: 10)))
        XCTAssertThrowsError(try pb(.init(maxBigFloatExponent: 10)).decode(Big.self, from: bigFloat(exponent: 10)))
    }

    func testBigFloatZeroHasNoExponent() throws {
        var inner = Data([0x10])
        Protowire.appendVarint(&inner, UInt64(bitPattern: Int64(Int32.max)))
        var out = Data([0x1A])
        Protowire.appendVarint(&out, UInt64(inner.count))
        out.append(inner)
        XCTAssertNoThrow(try pb().decode(Big.self, from: out))
    }

    /// A big-number literal is bound by the call's limits, not the constants.
    func testABoundLiteralFollowsTheCallsLimits() throws {
        func field(_ name: String, _ number: Int32, _ type: Google_Protobuf_FieldDescriptorProto.TypeEnum) -> Google_Protobuf_FieldDescriptorProto {
            var f = Google_Protobuf_FieldDescriptorProto()
            f.name = name
            f.number = number
            f.type = type
            f.label = .optional
            return f
        }
        var bigFloat = Google_Protobuf_DescriptorProto()
        bigFloat.name = "BigFloat"
        bigFloat.field = [field("mantissa", 1, .bytes), field("exponent", 2, .int32), field("prec", 3, .uint32), field("negative", 4, .bool)]
        var pxf = Google_Protobuf_FileDescriptorProto()
        pxf.name = "pxf/bignum.proto"
        pxf.package = "pxf"
        var decimal = Google_Protobuf_DescriptorProto()
        decimal.name = "Decimal"
        decimal.field = [field("unscaled", 1, .bytes), field("scale", 2, .int32), field("negative", 3, .bool)]
        pxf.messageType = [bigFloat, decimal]
        var f = field("rate", 1, .message)
        f.typeName = ".pxf.BigFloat"
        var d = field("price", 2, .message)
        d.typeName = ".pxf.Decimal"
        var holder = Google_Protobuf_DescriptorProto()
        holder.name = "Holder"
        holder.field = [f, d]
        var file = Google_Protobuf_FileDescriptorProto()
        file.name = "h.proto"
        file.package = "h.v1"
        file.syntax = "proto3"
        file.dependency = ["pxf/bignum.proto"]
        file.messageType = [holder]

        struct Anything: Decodable { init(from decoder: Decoder) throws {} }
        let decoder = PXFDecoder(annotations: PXF.Annotations(files: [pxf, file]), rootMessage: "h.v1.Holder")
        XCTAssertNoThrow(try decoder.decode(Anything.self, from: "rate = 1e30"))
        decoder.limits.maxBigFloatExponent = 8
        XCTAssertThrowsError(try decoder.decode(Anything.self, from: "rate = 1e30"))
        decoder.limits.maxNumericLiteralDigits = 6
        XCTAssertNoThrow(try decoder.decode(Anything.self, from: "price = 1.23456"))
        decoder.limits.maxNumericLiteralDigits = 5
        XCTAssertThrowsError(try decoder.decode(Anything.self, from: "price = 1.23456")) { err in
            guard case DecoderError.numericLiteralTooLong(6, 5) = err else {
                return XCTFail("expected numericLiteralTooLong, got \(err)")
            }
        }
    }
}
