import XCTest
@testable import Protowire

final class SBETests: XCTestCase {
    func testSBERoundTrip() throws {
        // Define a template for an Order message.
        // uint64 order_id = 1; (offset 0, size 8)
        // char symbol[8] = 2; (offset 8, size 8)
        // uint32 price = 3; (offset 16, size 4)
        let tmpl = SBE.MessageTemplate(
            templateID: 1, schemaID: 1, version: 0,
            blockLength: 20,
            fields: [
                SBE.FieldTemplate(name: "order_id", offset: 0, size: 8, encoding: .uint64),
                SBE.FieldTemplate(name: "symbol", offset: 8, size: 8, encoding: .char),
                SBE.FieldTemplate(name: "price", offset: 16, size: 4, encoding: .uint32)
            ]
        )
        
        let values: [String: Any] = [
            "order_id": UInt64(12345),
            "symbol": "AAPL",
            "price": UInt32(15000)
        ]
        
        let marshaller = SBEMarshaller()
        let data = try marshaller.marshal(values, template: tmpl)
        
        XCTAssertEqual(data.count, SBE.headerSize + 20)
        
        let unmarshaller = SBEUnmarshaller()
        let got = try unmarshaller.unmarshal(data, template: tmpl)
        
        XCTAssertEqual(got["order_id"] as? UInt64, 12345)
        XCTAssertEqual(got["symbol"] as? String, "AAPL")
        XCTAssertEqual(got["price"] as? UInt32, 15000)
    }

    func testSBEGroups() throws {
        // Message with a repeating group.
        // Root block: uint32 msg_id (offset 0, size 4)
        // Group "entries": uint64 id (offset 0), uint32 val (offset 8). BlockLen 12.
        let groupTmpl = SBE.GroupTemplate(
            name: "entries", blockLength: 12,
            fields: [
                SBE.FieldTemplate(name: "id", offset: 0, size: 8, encoding: .uint64),
                SBE.FieldTemplate(name: "val", offset: 8, size: 4, encoding: .uint32)
            ]
        )
        let tmpl = SBE.MessageTemplate(
            templateID: 2, schemaID: 1, version: 0,
            blockLength: 4,
            fields: [SBE.FieldTemplate(name: "msg_id", offset: 0, size: 4, encoding: .uint32)],
            groups: [groupTmpl]
        )
        
        let values: [String: Any] = [
            "msg_id": UInt32(1),
            "entries": [
                ["id": UInt64(10), "val": UInt32(100)],
                ["id": UInt64(20), "val": UInt32(200)]
            ]
        ]
        
        let marshaller = SBEMarshaller()
        let data = try marshaller.marshal(values, template: tmpl)
        
        let unmarshaller = SBEUnmarshaller()
        let got = try unmarshaller.unmarshal(data, template: tmpl)
        
        XCTAssertEqual(got["msg_id"] as? UInt32, 1)
        let gotEntries = got["entries"] as? [[String: Any]]
        XCTAssertEqual(gotEntries?.count, 2)
        XCTAssertEqual(gotEntries?[0]["id"] as? UInt64, 10)
        XCTAssertEqual(gotEntries?[1]["val"] as? UInt32, 200)
    }

    func testSBEView() throws {
        let tmpl = SBE.MessageTemplate(
            templateID: 1, schemaID: 1, version: 0,
            blockLength: 20,
            fields: [
                SBE.FieldTemplate(name: "order_id", offset: 0, size: 8, encoding: .uint64),
                SBE.FieldTemplate(name: "symbol", offset: 8, size: 8, encoding: .char),
                SBE.FieldTemplate(name: "price", offset: 16, size: 4, encoding: .uint32)
            ],
            groups: [
                SBE.GroupTemplate(name: "fills", blockLength: 12, fields: [
                    SBE.FieldTemplate(name: "id", offset: 0, size: 8, encoding: .uint64),
                    SBE.FieldTemplate(name: "val", offset: 8, size: 4, encoding: .uint32)
                ])
            ]
        )
        
        let values: [String: Any] = [
            "order_id": UInt64(12345),
            "symbol": "AAPL",
            "price": UInt32(15000),
            "fills": [
                ["id": UInt64(1), "val": UInt32(100)],
                ["id": UInt64(2), "val": UInt32(200)]
            ]
        ]
        
        let data = try SBEMarshaller().marshal(values, template: tmpl)
        let view = try SBE.View(data: data, template: tmpl)
        
        XCTAssertEqual(view.uint("order_id"), 12345)
        XCTAssertEqual(view.string("symbol"), "AAPL")
        XCTAssertEqual(view.uint("price"), 15000)
        
        let fills = view.group("fills")
        XCTAssertEqual(fills.countEntries, 2)
        XCTAssertEqual(fills.entry(0).uint("id"), 1)
        XCTAssertEqual(fills.entry(1).uint("val"), 200)
    }
}
