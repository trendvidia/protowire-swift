// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import Foundation
import SwiftProtobuf
import XCTest
@testable import Protowire

/// Compares this port with what protowire-go did to the spec corpus.
///
/// `testdata/conformance/reference.jsonl` is written by `conformance/refgen`,
/// which runs every document through the reference. A disagreement fails
/// unless `ledger.json` names it, and a ledger entry that no longer disagrees
/// fails too, so the ledger can only shrink. See `conformance/README.md`.
final class ConformanceTests: XCTestCase {
    private struct Record: Decodable {
        var suite: String
        var file: String
        var input: String
        var message: String?
        var parse: String
        var parse_error: String?
        var decode: String
        var decode_error: String?
        var pb: [String]?
        var text: [String]?
        var format: String?

        var id: String { "\(suite)/\(file)" }
    }

    /// Reads nothing, so a decode runs the schema checks and no Swift type.
    private struct Anything: Decodable {
        init(from decoder: Decoder) throws {}
    }

    /// The spec tests' resolver: the message named after the URL's last "/".
    private struct Resolver: PXF.TypeResolver {
        let annotations: PXF.Annotations
        func resolve(typeURL: String) -> Decodable.Type? {
            let name = typeURL.split(separator: "/").last.map(String.init) ?? typeURL
            return annotations.message(name) == nil ? nil : Anything.self
        }
    }

    private static let root = Bundle.module.resourceURL!.appendingPathComponent("testdata/conformance")

    private static let records: [Record] = {
        let text = try! String(contentsOf: root.appendingPathComponent("reference.jsonl"), encoding: .utf8)
        return text.split(separator: "\n").map {
            try! JSONDecoder().decode(Record.self, from: Data($0.utf8))
        }
    }()

    private static let ledger: [String: [String: String]] = {
        let data = try! Data(contentsOf: root.appendingPathComponent("ledger.json"))
        return try! JSONDecoder().decode([String: [String: String]].self, from: data)
    }()

    private static var schemas: [String: PXF.Annotations] = [:]

    private static func schema(_ suite: String) throws -> PXF.Annotations {
        if let s = schemas[suite] { return s }
        let data = try Data(contentsOf: root.appendingPathComponent("descriptors/\(suite).binpb"))
        let set = try Google_Protobuf_FileDescriptorSet(serializedBytes: data, extensions: Pxf_Annotations_Extensions)
        let s = PXF.Annotations(descriptorSet: set)
        schemas[suite] = s
        return s
    }

    private func input(_ r: Record) throws -> Data {
        try Data(contentsOf: Self.root.appendingPathComponent("corpus/\(r.suite)/\(r.file)"))
    }

    /// What one document did on one leg.
    private enum Outcome {
        /// The leg does not apply to this document.
        case skipped
        case matched
        case diverged(String)
    }

    /// Compares one leg. `compared` counts the documents the leg really ran
    /// on, as the positive marker that it ran: a skipped document is not one.
    private func run(leg: String, expectedAtLeast: Int, _ compare: (Record) throws -> Outcome) throws {
        let ledger = Self.ledger[leg] ?? [:]
        var compared = 0
        var actual: [String: String] = [:]
        for r in Self.records {
            switch try compare(r) {
            case .skipped:
                continue
            case .matched:
                compared += 1
            case .diverged(let d):
                compared += 1
                actual[r.id] = d
            }
        }
        XCTAssertGreaterThanOrEqual(compared, expectedAtLeast, "\(leg): too few documents compared")
        for (id, d) in actual.sorted(by: { $0.key < $1.key }) where ledger[id] == nil {
            XCTFail("\(leg): \(id): \(d)")
        }
        for id in ledger.keys.sorted() where actual[id] == nil {
            XCTFail("\(leg): \(id) now matches the reference; remove it from ledger.json (\(ledger[id]!))")
        }
        print("conformance \(leg): compared \(compared), ledger \(ledger.count), diverging \(actual.count)")
        if let dir = ProcessInfo.processInfo.environment["CONFORMANCE_ACTUAL"] {
            let lines = actual.sorted(by: { $0.key < $1.key }).map { "\($0.key)\t\($0.value)" }.joined(separator: "\n")
            try Data(lines.utf8).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(leg).tsv"))
        }
    }

    func testCorpusIsPresent() throws {
        XCTAssertEqual(Self.records.count, 252)
        for r in Self.records {
            XCTAssertTrue(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("corpus/\(r.suite)/\(r.file)").path), r.id)
        }
    }

    /// The schema-less parse: the same accept or reject as `pxf.Parse`.
    func testParseVerdicts() throws {
        try run(leg: "parse", expectedAtLeast: 181) { r in
            guard r.input == "pxf" else { return .skipped }
            let data = try input(r)
            do {
                _ = try PXF.Parser(input: data).parseDocument()
                return r.parse == "accept" ? .matched : .diverged("accepted; reference: \(r.parse_error ?? "")")
            } catch {
                return r.parse == "reject" ? .matched : .diverged("rejected: \(error)")
            }
        }
    }

    /// The schema-bound decode: the same accept or reject as the reference's
    /// `UnmarshalDescriptor`, or `BindRow` for a dataset's rows.
    func testDecodeVerdicts() throws {
        try run(leg: "decode", expectedAtLeast: 169) { r in
            guard r.input == "pxf", !r.decode.isEmpty, let message = r.message else { return .skipped }
            let data = try input(r)
            let annotations = try Self.schema(r.suite)
            do {
                let doc = try PXF.Parser(input: data).parseDocument()
                let decoder = PXFDecoder(annotations: annotations, rootMessage: message)
                decoder.typeResolver = Resolver(annotations: annotations)
                if doc.datasets.isEmpty {
                    _ = try decoder.decode(Anything.self, from: data)
                } else {
                    for dataset in doc.datasets { _ = try decoder.decodeRows(Anything.self, of: dataset) }
                }
                return r.decode == "accept" ? .matched : .diverged("accepted; reference: \(r.decode_error ?? "")")
            } catch {
                return r.decode == "reject" ? .matched : .diverged("rejected: \(error)")
            }
        }
    }

    /// The schema-bound decode's bytes, against the reference's deterministic
    /// marshal of the message it decoded.
    func testBoundBytes() throws {
        try run(leg: "pb", expectedAtLeast: 98) { r in
            guard r.input == "pxf", r.decode == "accept", let message = r.message, let want = r.pb else { return .skipped }
            let data = try input(r)
            let annotations = try Self.schema(r.suite)
            let decoder = PXFDecoder(annotations: annotations, rootMessage: message)
            decoder.typeResolver = Resolver(annotations: annotations)
            var bound: [PXF.BoundMessage] = []
            do {
                let doc = try PXF.Parser(input: data).parseDocument()
                if doc.datasets.isEmpty {
                    _ = try decoder.decode(Anything.self, from: data)
                    bound = decoder.lastBound.map { [$0] } ?? []
                } else {
                    for dataset in doc.datasets {
                        _ = try decoder.decodeRows(Anything.self, of: dataset)
                        bound += decoder.lastBoundRows
                    }
                }
            } catch {
                return .diverged("did not decode: \(error)")
            }
            let got = bound.map { $0.serialized().map { String(format: "%02x", $0) }.joined() }
            return got == want ? .matched : .diverged("bytes differ: got \(got), want \(want)")
        }
    }

    /// The marshaller: `PXFEncoder` over the bound message, against the
    /// reference's text, the goldens of testdata/text among them.
    func testMarshalledText() throws {
        try run(leg: "text", expectedAtLeast: 167) { r in
            guard r.decode == "accept", let message = r.message, let want = r.text else { return .skipped }
            let annotations = try Self.schema(r.suite)
            var bound: [PXF.BoundMessage] = []
            let data = try input(r)
            if r.input == "pb" {
                bound = [try PXF.BoundMessage(reading: data, message: message, annotations: annotations)]
            } else {
                let decoder = PXFDecoder(annotations: annotations, rootMessage: message)
                decoder.typeResolver = Resolver(annotations: annotations)
                guard let doc = try? PXF.Parser(input: data).parseDocument() else { return .diverged("did not parse") }
                if doc.datasets.isEmpty {
                    guard (try? decoder.decode(Anything.self, from: data)) != nil, let m = decoder.lastBound else { return .diverged("did not decode") }
                    bound = [m]
                } else {
                    for dataset in doc.datasets {
                        guard (try? decoder.decodeRows(Anything.self, of: dataset)) != nil else { return .diverged("did not decode") }
                        bound += decoder.lastBoundRows
                    }
                }
            }
            let got = try bound.map { message -> String in
                let encoder = PXFEncoder(annotations: annotations, rootMessage: message.name)
                return try encoder.encode(PXF.BoundText(message: message, annotations: annotations))
            }
            return got == want ? .matched : .diverged("text differs: got \(got), want \(want)")
        }
    }

    /// `pxf fmt` without a schema: the same text as `pxf.FormatDocument`.
    func testFormat() throws {
        try run(leg: "format", expectedAtLeast: 157) { r in
            guard r.input == "pxf", let want = r.format else { return .skipped }
            guard let doc = try? PXF.Parser(input: try input(r)).parseDocument() else {
                return .diverged("did not parse")
            }
            let got = PXF.Format.formatDocument(doc)
            return got == want ? .matched : .diverged("formatted differently")
        }
    }
}
