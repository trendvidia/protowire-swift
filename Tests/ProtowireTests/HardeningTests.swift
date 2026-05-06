import XCTest
@testable import Protowire

/// Regression tests for the HARDENING.md decoder-safety contract. These are
/// the inputs the cross-port adversarial corpus surfaces; once the conformance
/// gate flips to required this file plus the corpus run together.
final class HardeningTests: XCTestCase {

    // Mirrors the corpus's adversarial.v1.Tree.
    final class Tree: Codable {
        var child: Tree?
        var label: String?
        enum CodingKeys: Int, CodingKey { case child = 1, label = 2 }
    }

    struct StringHolder: Codable {
        var value: String?
        enum CodingKeys: Int, CodingKey { case value = 1 }
    }

    // MARK: - PXF nesting depth

    func testPXFRejectsNestingOverLimit() throws {
        // 200 levels of `child{...}` exceeds MaxNestingDepth=100.
        var s = "@type adversarial.v1.Tree\n"
        for _ in 0..<200 { s += "child{" }
        for _ in 0..<200 { s += "}" }

        let dec = PXFDecoder()
        XCTAssertThrowsError(try dec.decode(Tree.self, from: Data(s.utf8))) { err in
            guard case DecoderError.nestingDepthExceeded = err else {
                return XCTFail("expected nestingDepthExceeded, got \(err)")
            }
        }
    }

    func testPXFAcceptsNestingAtBaseline() throws {
        // 10 levels is well below the limit and must round-trip.
        var s = "@type adversarial.v1.Tree\n"
        for _ in 0..<10 { s += "child{" }
        for _ in 0..<10 { s += "}" }
        XCTAssertNoThrow(try PXFDecoder().decode(Tree.self, from: Data(s.utf8)))
    }

    // MARK: - PXF UTF-8 strictness

    func testPXFRejectsInvalidUTF8InStringLiteral() {
        // \xFF\xFE is not valid UTF-8; per HARDENING.md § UTF-8 the lossy
        // U+FFFD substitution path is forbidden.
        let s = "@type adversarial.v1.StringHolder\nvalue = \"\\xFF\\xFE\"\n"
        XCTAssertThrowsError(try PXFDecoder().decode(StringHolder.self, from: Data(s.utf8)))
    }

    // MARK: - PB nesting depth

    func testPBRejectsSubmessageNestingOverLimit() throws {
        // Build N nested length-delimited Tree submessages: tag=1 wire=2.
        var data = Data()
        for _ in 0..<200 {
            // length placeholder filled below
            data = encodeLenDelim(field: 1, payload: data)
        }
        XCTAssertThrowsError(try PBDecoder().decode(Tree.self, from: data)) { err in
            guard case DecoderError.nestingDepthExceeded = err else {
                return XCTFail("expected nestingDepthExceeded, got \(err)")
            }
        }
    }

    // MARK: - PB length-prefix bounds

    func testPBRejectsTruncatedLengthPrefix() {
        // tag=1 (string), declared length = 100, no payload.
        let data = Data([0x0a, 0x64])
        XCTAssertThrowsError(try PBDecoder().decode(StringHolder.self, from: data))
    }

    func testPBRejectsLengthPrefixOverflow() {
        // tag=1, length = 2^64-1 (max 10-byte varint). Pre-fix this trapped
        // on the `Int(_:)` conversion; post-fix it must surface as a clean error.
        let data = Data([0x0a, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01])
        XCTAssertThrowsError(try PBDecoder().decode(StringHolder.self, from: data))
    }

    // MARK: - helpers

    /// Wraps `payload` as a length-delimited field with tag=`field` (wire=2).
    private func encodeLenDelim(field: Int, payload: Data) -> Data {
        var out = Data()
        Protowire.appendTag(&out, number: Int32(field), type: .bytes)
        Protowire.appendBytes(&out, payload)
        return out
    }
}
