// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import XCTest
import SwiftProtobuf
@testable import Protowire

/// `SBE.templates(from:)` against protowire's canonical `bench.v1.Order`
/// (testdata/sbe-bench.proto), built here as a descriptor with the
/// `(sbe.*)` options set through the generated extension accessors. The
/// expected layout is the one every port's bench-sbe agrees on: 8-byte
/// header, 42-byte root block, one group of 20-byte entries.
final class SBEDescriptorTests: XCTestCase {
    private func field(_ name: String, _ number: Int32, _ type: Google_Protobuf_FieldDescriptorProto.TypeEnum,
                       label: Google_Protobuf_FieldDescriptorProto.Label = .optional,
                       typeName: String? = nil, length: UInt32? = nil, encoding: String? = nil)
        -> Google_Protobuf_FieldDescriptorProto {
        var f = Google_Protobuf_FieldDescriptorProto()
        f.name = name
        f.number = number
        f.type = type
        f.label = label
        if let t = typeName { f.typeName = t }
        if let l = length { f.options.Sbe_length = l }
        if let e = encoding { f.options.Sbe_encoding = e }
        return f
    }

    private func benchFile() -> Google_Protobuf_FileDescriptorProto {
        var fill = Google_Protobuf_DescriptorProto()
        fill.name = "Fill"
        fill.field = [
            field("fill_price", 1, .int64),
            field("fill_qty", 2, .uint32),
            field("fill_id", 3, .uint64),
        ]
        var order = Google_Protobuf_DescriptorProto()
        order.name = "Order"
        order.options.Sbe_templateID = 1
        order.field = [
            field("order_id", 1, .uint64),
            field("symbol", 2, .string, length: 8),
            field("price", 3, .int64),
            field("quantity", 4, .uint32),
            field("side", 5, .enum, typeName: ".bench.v1.Side"),
            field("active", 6, .bool),
            field("weight", 7, .double),
            field("score", 8, .float),
            field("fills", 9, .message, label: .repeated, typeName: ".bench.v1.Order.Fill"),
        ]
        order.nestedType = [fill]
        var file = Google_Protobuf_FileDescriptorProto()
        file.name = "sbe-bench.proto"
        file.package = "bench.v1"
        file.options.Sbe_schemaID = 1
        file.options.Sbe_version = 0
        file.messageType = [order]
        return file
    }

    func testBenchOrderLayoutMatchesTheReference() throws {
        let templates = try SBE.templates(from: benchFile())
        XCTAssertEqual(Array(templates.keys), ["bench.v1.Order"], "only messages with (sbe.template_id) get a template")
        let tmpl = try XCTUnwrap(templates["bench.v1.Order"])
        XCTAssertEqual(tmpl.templateID, 1)
        XCTAssertEqual(tmpl.schemaID, 1)
        XCTAssertEqual(tmpl.version, 0)
        XCTAssertEqual(tmpl.blockLength, 42)
        XCTAssertEqual(tmpl.fields.map(\.name), ["order_id", "symbol", "price", "quantity", "side", "active", "weight", "score"])
        XCTAssertEqual(tmpl.fields.map(\.offset), [0, 8, 16, 24, 28, 29, 30, 38])
        XCTAssertEqual(tmpl.fields.map(\.encoding), [.uint64, .char, .int64, .uint32, .uint8, .uint8, .double, .float])
        XCTAssertEqual(tmpl.fields[1].size, 8, "(sbe.length) sizes the char field")
        XCTAssertEqual(tmpl.groups.count, 1)
        XCTAssertEqual(tmpl.groups[0].name, "fills")
        XCTAssertEqual(tmpl.groups[0].blockLength, 20)
        XCTAssertEqual(tmpl.groups[0].fields.map(\.offset), [0, 8, 12])
    }

    func testMarshalsTheCanonicalOrderToTheSharedBytes() throws {
        let tmpl = try XCTUnwrap(try SBE.templates(from: benchFile())["bench.v1.Order"])
        let values: [String: Any] = [
            "order_id": UInt64(1001), "symbol": "AAPL", "price": Int64(19150), "quantity": UInt32(100),
            "side": UInt64(1), "active": UInt64(1), "weight": Double(0.85), "score": Float(2.5),
            "fills": [
                ["fill_price": Int64(19155), "fill_qty": UInt32(25), "fill_id": UInt64(5001)],
                ["fill_price": Int64(19160), "fill_qty": UInt32(50), "fill_id": UInt64(5002)],
            ] as [[String: Any]],
        ]
        let data = try SBEMarshaller().marshal(values, template: tmpl)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        // protowire/testdata/sbe-bench.expected.hex
        XCTAssertEqual(hex, "2a00010001000000e9030000000000004141504c00000000ce4a000000000000640000000101333333333333eb3f0000204014000200d34a000000000000190000008913000000000000d84a000000000000320000008a13000000000000")
    }

    func testEncodingOverrideAndErrors() throws {
        var file = benchFile()
        file.messageType[0].field[3].options.Sbe_encoding = "uint8" // quantity
        let tmpl = try XCTUnwrap(try SBE.templates(from: file)["bench.v1.Order"])
        XCTAssertEqual(tmpl.fields[3].size, 1)
        XCTAssertEqual(tmpl.blockLength, 39)

        var noSchema = benchFile()
        noSchema.options.clearSbe_schemaID()
        XCTAssertThrowsError(try SBE.templates(from: noSchema)) { e in
            XCTAssertEqual(String(describing: e), "sbe: file sbe-bench.proto missing (sbe.schema_id) option")
        }

        var noLength = benchFile()
        noLength.messageType[0].field[1].options.clearSbe_length()
        XCTAssertThrowsError(try SBE.templates(from: noLength)) { e in
            XCTAssertEqual(String(describing: e), "sbe: field bench.v1.Order.symbol: string/bytes field requires (sbe.length) annotation")
        }

        var repeatedScalar = benchFile()
        repeatedScalar.messageType[0].field[3].label = .repeated
        XCTAssertThrowsError(try SBE.templates(from: repeatedScalar))
    }
}
