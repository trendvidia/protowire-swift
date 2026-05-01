import XCTest
@testable import Protowire

final class EnvelopeTests: XCTestCase {
    func testBinaryRoundTrip_OK() throws {
        let orig = Envelope.ok(status: 200, data: Data([0xDE, 0xAD, 0xBE, 0xEF]))

        let data = try PBEncoder().encode(orig)
        let got = try PBDecoder().decode(Envelope.self, from: data)

        XCTAssertEqual(orig, got)
        XCTAssertTrue(got.isOK)
    }

    func testBinaryRoundTrip_TransportErr() throws {
        let orig = Envelope.transportErr("connection refused")

        let data = try PBEncoder().encode(orig)
        let got = try PBDecoder().decode(Envelope.self, from: data)

        XCTAssertEqual(orig, got)
        XCTAssertTrue(got.isTransportError)
    }

    func testBinaryRoundTrip_AppError_WithFieldsAndMetadata() throws {
        var ae = AppError(code: "INSUFFICIENT_FUNDS", message: "balance too low", args: ["$3.50", "$10.00"])
        ae.withField(field: "amount", code: "MIN_VALUE", message: "below minimum", args: "10.00")
        ae.withField(field: "currency", code: "INVALID", message: "unsupported currency")
        ae.withMeta(key: "request_id", value: "req-123")
        ae.withMeta(key: "retry_after", value: "30")
        
        let orig = Envelope(status: 402, error: ae)

        let data = try PBEncoder().encode(orig)
        let got = try PBDecoder().decode(Envelope.self, from: data)

        XCTAssertEqual(orig, got)
        XCTAssertTrue(got.isAppError)
        XCTAssertEqual(got.errorCode, "INSUFFICIENT_FUNDS")
        XCTAssertEqual(got.error?.details?.count, 2)
        XCTAssertEqual(got.error?.metadata?["request_id"], "req-123")
    }
}
