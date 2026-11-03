// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import XCTest
import SwiftProtobuf
@testable import Protowire

/// HARDENING.md § UTF-8 and draft -01 § SBE Annotations, mirrored from
/// protowire-go/encoding/sbe/utf8_test.go: a string field holds valid UTF-8 on
/// the way in and is cut on a character boundary on the way out, while a bytes
/// field takes any bytes and is cut at its length. The templates come from a
/// descriptor, so the string/bytes split is the one `SBE.templates(from:)` makes.
final class SBEUTF8Tests: XCTestCase {
    private func field(_ name: String, _ number: Int32, _ type: Google_Protobuf_FieldDescriptorProto.TypeEnum,
                       label: Google_Protobuf_FieldDescriptorProto.Label = .optional,
                       typeName: String? = nil, length: UInt32? = nil) -> Google_Protobuf_FieldDescriptorProto {
        var f = Google_Protobuf_FieldDescriptorProto()
        f.name = name
        f.number = number
        f.type = type
        f.label = label
        if let t = typeName { f.typeName = t }
        if let l = length { f.options.Sbe_length = l }
        return f
    }

    private func message(_ name: String, templateID: UInt32? = nil, _ fields: [Google_Protobuf_FieldDescriptorProto]) -> Google_Protobuf_DescriptorProto {
        var m = Google_Protobuf_DescriptorProto()
        m.name = name
        if let t = templateID { m.options.Sbe_templateID = t }
        m.field = fields
        return m
    }

    /// The Go test's utf8.proto: Quote has 4-byte fields, Cut 8-byte ones,
    /// CutTiny one 3-byte string.
    private func templates() throws -> [String: SBE.MessageTemplate] {
        var file = Google_Protobuf_FileDescriptorProto()
        file.name = "utf8.proto"
        file.package = "utf8.v1"
        file.options.Sbe_schemaID = 2
        file.options.Sbe_version = 0
        file.messageType = [
            message("Code", [field("text", 1, .string, length: 4)]),
            message("Row", [field("tag", 1, .string, length: 4)]),
            message("Quote", templateID: 1, [
                field("symbol", 1, .string, length: 4),
                field("raw", 2, .bytes, length: 4),
                field("code", 3, .message, typeName: ".utf8.v1.Code"),
                field("rows", 4, .message, label: .repeated, typeName: ".utf8.v1.Row"),
            ]),
            message("CutCode", [field("text", 1, .string, length: 8)]),
            message("CutRow", [field("tag", 1, .string, length: 8)]),
            message("Cut", templateID: 2, [
                field("text", 1, .string, length: 8),
                field("raw", 2, .bytes, length: 8),
                field("code", 3, .message, typeName: ".utf8.v1.CutCode"),
                field("rows", 4, .message, label: .repeated, typeName: ".utf8.v1.CutRow"),
            ]),
            message("CutTiny", templateID: 3, [field("text", 1, .string, length: 3)]),
        ]
        return try SBE.templates(from: file)
    }

    /// A Quote laid out by hand, because the marshaller is not the producer
    /// under test: the bytes come from a feed. Each value is padded to 4 bytes.
    private func quoteFrame(_ symbol: [UInt8], _ raw: [UInt8], _ code: [UInt8], rows: [[UInt8]] = []) -> Data {
        func pad(_ b: [UInt8]) -> [UInt8] { b + [UInt8](repeating: 0, count: 4 - b.count) }
        var d = Data()
        SBE.writeHeader(&d, SBE.MessageHeader(blockLength: 12, templateID: 1, schemaID: 2, version: 0))
        d.append(contentsOf: pad(symbol) + pad(raw) + pad(code))
        d.append(contentsOf: [4, 0, UInt8(rows.count), 0])
        for r in rows { d.append(contentsOf: pad(r)) }
        return d
    }

    func testDescriptorMarksBytesFields() throws {
        let quote = try XCTUnwrap(try templates()["utf8.v1.Quote"])
        XCTAssertEqual(quote.fields.map(\.name), ["symbol", "raw", "code"])
        XCTAssertEqual(quote.fields.map(\.isBytes), [false, true, false])
    }

    func testStringFieldRejectsInvalidUTF8() throws {
        let quote = try XCTUnwrap(try templates()["utf8.v1.Quote"])
        let sites: [(String, ([UInt8]) -> Data)] = [
            ("root field", { self.quoteFrame($0, [], []) }),
            ("composite field", { self.quoteFrame([], [], $0) }),
            ("group field", { self.quoteFrame([], [], [], rows: [Array("ok".utf8), $0]) }),
        ]
        let sequences: [(String, [UInt8])] = [
            ("stray byte", [0x41, 0x42, 0xFF]),
            ("lone continuation", [0x80]),
            ("latin-1", [0x63, 0x61, 0x66, 0xE9]),
            ("cut off at the end of the field", [0x61, 0x62, 0x63, 0xC3]),
            ("overlong", [0xC0, 0x80]),
            ("surrogate", [0xED, 0xA0, 0x80]),
            ("past U+10FFFF", [0xF4, 0x90, 0x80, 0x80]),
        ]
        for (site, frame) in sites {
            for (name, bad) in sequences {
                XCTAssertThrowsError(try SBEUnmarshaller().unmarshal(frame(bad), template: quote), "\(site)/\(name)") { error in
                    guard case DecoderError.invalidUTF8 = error else {
                        return XCTFail("\(site)/\(name): \(error)")
                    }
                }
            }
        }
    }

    /// The check must not refuse what the rule allows: a bytes field takes
    /// anything, and valid text keeps its multi-byte characters, an interior
    /// NUL, and a leading one.
    func testStringFieldAcceptsValidUTF8() throws {
        let quote = try XCTUnwrap(try templates()["utf8.v1.Quote"])
        let frame = quoteFrame(Array("€a".utf8), [0xFF, 0xFE, 0x80, 0xC0], Array("a\u{0}b".utf8), rows: [Array("😀".utf8), [0, 0x7A]])
        let got = try SBEUnmarshaller().unmarshal(frame, template: quote)
        XCTAssertEqual(got["symbol"] as? String, "€a")
        XCTAssertEqual(got["raw"] as? Data, Data([0xFF, 0xFE, 0x80, 0xC0]))
        XCTAssertEqual((got["code"] as? [String: Any])?["text"] as? String, "a\u{0}b")
        let rows = try XCTUnwrap(got["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["tag"] as? String }, ["😀", "\u{0}z"])
    }
}
