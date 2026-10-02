import CorvusJsonSchema
import Dispatch
import Foundation
import XCTest

final class APITests: XCTestCase {
    let person = #"""
        {"type": "object", "required": ["name"],
         "properties": {"name": {"type": "string"}, "age": {"type": "integer", "minimum": 0}}}
        """#

    func testValidatesJSONText() throws {
        let validator = try Validator(schema: person)
        XCTAssertTrue(try validator.isValid(json: #"{"name": "Ada", "age": 36}"#))
        XCTAssertFalse(try validator.isValid(json: #"{"name": "Ada", "age": -1}"#))
        XCTAssertFalse(try validator.isValid(json: #"{"age": 1}"#))
        XCTAssertTrue(try validator.isValid(json: Data(#"{"name": "Ada"}"#.utf8)))
        XCTAssertTrue(try Validator(schema: Data(person.utf8)).isValid(json: #"{"name": "Ada"}"#))
    }

    func testDocuments() throws {
        let validator = try Validator(schema: person)
        let valid = try Document(json: #"{"name": "Ada"}"#)
        let invalid = try Document(json: Data(#"{"name": 1}"#.utf8))
        XCTAssertTrue(try validator.isValid(valid))
        XCTAssertFalse(try validator.isValid(invalid))
        XCTAssertTrue(try validator.isValid(valid), "a document can be validated again")
    }

    func testErrors() throws {
        let validator = try Validator(schema: person)
        XCTAssertThrowsError(try validator.isValid(json: #"{"name": "#)) { error in
            guard case JSONSchemaError.invalidJSON(_, let offset) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(offset, 9)
        }
        XCTAssertThrowsError(try validator.isValid(json: Data([0x22, 0xff, 0x22]))) { error in
            guard case JSONSchemaError.invalidUTF8 = error else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertThrowsError(try Validator(schema: "{")) { error in
            guard case JSONSchemaError.invalidJSON = error else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertThrowsError(try Validator(schema: #"{"$ref": "https://example.com/none"}"#)) { error in
            guard case JSONSchemaError.compilationFailed(let message) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(message.contains("https://example.com/none"), message)
        }
        XCTAssertThrowsError(try Validator(schema: #"{"pattern": "("}"#)) { error in
            guard case JSONSchemaError.compilationFailed = error else {
                return XCTFail("\(error)")
            }
        }
        let looping = try Validator(schema: ##"{"$ref": "#"}"##, options: Options(maxDepth: 8))
        XCTAssertThrowsError(try looping.isValid(json: "1")) { error in
            guard case JSONSchemaError.depthExceeded = error else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertThrowsError(try Document(json: "[1,")) { error in
            guard case JSONSchemaError.invalidJSON = error else {
                return XCTFail("\(error)")
            }
        }
    }

    func testOptions() throws {
        XCTAssertFalse(
            try Validator(schema: #"{"maximum": 3, "exclusiveMaximum": true}"#, options: Options(defaultDialect: .draft4))
                .isValid(json: "3"))
        XCTAssertTrue(try Validator(schema: #"{"format": "email"}"#).isValid(json: #""nope""#))
        XCTAssertFalse(try Validator(schema: #"{"format": "email"}"#, options: Options(assertFormat: true)).isValid(json: #""nope""#))
        XCTAssertFalse(
            try Validator(
                schema: #"{"$schema": "http://json-schema.org/draft-07/schema#", "format": "email"}"#,
                options: Options(assertFormatInLegacyDrafts: true)
            ).isValid(json: #""nope""#))
        XCTAssertTrue(
            try Validator(
                schema: #"{"$ref": "item", "$defs": {"item": {"$id": "item", "type": "string"}}}"#,
                options: Options(baseURI: "https://example.com/root")
            ).isValid(json: #""a""#))
        XCTAssertFalse(
            try Validator(
                schema: #"{"$defs": {"item": {"type": "string"}}}"#, options: Options(entryPoint: "#/$defs/item")
            ).isValid(json: "1"))
    }

    func testFormats() throws {
        let even = try Validator(
            schema: #"{"format": "even"}"#,
            options: Options(assertFormat: true, formats: ["even": { $0.count % 2 == 0 }]))
        XCTAssertTrue(try even.isValid(json: #""ab""#))
        XCTAssertFalse(try even.isValid(json: #""abc""#))
        XCTAssertTrue(try even.isValid(json: "1"), "formats apply to strings")
    }

    func testResolver() throws {
        let remote = try Validator(
            schema: #"{"$ref": "https://example.com/positive"}"#,
            options: Options(resolver: { $0 == "https://example.com/positive" ? #"{"minimum": 1}"# : nil }))
        XCTAssertFalse(try remote.isValid(json: "0"))
        XCTAssertTrue(try remote.isValid(json: "1"))

        let byURI = try Validator(
            schemaURI: "https://example.com/string",
            options: Options(resolver: { _ in #"{"type": "string"}"# }))
        XCTAssertTrue(try byURI.isValid(json: #""a""#))

        struct Unreachable: Error, Equatable {}
        XCTAssertThrowsError(
            try Validator(schema: #"{"$ref": "https://example.com/x"}"#, options: Options(resolver: { _ in throw Unreachable() }))
        ) { error in
            XCTAssertEqual(error as? Unreachable, Unreachable(), "the resolver's own error")
        }
        XCTAssertThrowsError(
            try Validator(schema: #"{"$ref": "https://example.com/x"}"#, options: Options(resolver: { _ in "{" }))
        ) { error in
            guard case JSONSchemaError.compilationFailed = error else {
                return XCTFail("\(error)")
            }
        }
    }

    func testCollectors() throws {
        let validator = try Validator(schema: person)
        let detailed = Collector(level: .detailed)
        XCTAssertFalse(try validator.evaluate(json: #"{"name": 1}"#, collector: detailed))
        let rows = detailed.results
        XCTAssertTrue(rows.contains { !$0.isMatch && $0.instanceLocation == "/name" && !$0.message.isEmpty })
        XCTAssertEqual(rows.last?.instanceLocation, "", "the root's own result is the last row")

        let basic = Collector()
        XCTAssertTrue(try validator.evaluate(json: #"{"name": "Ada"}"#, collector: basic))
        XCTAssertTrue(basic.results.allSatisfy { $0.isMatch }, "no failures")
        basic.clear()
        XCTAssertEqual(basic.results, [])

        let verbose = Collector(level: .verbose)
        let titled = try Validator(schema: #"{"title": "T", "properties": {"a": {"title": "A"}}}"#)
        try titled.evaluate(Document(json: #"{"a": 1}"#), collector: verbose)
        let annotations = try JSONSerialization.jsonObject(with: Data(try verbose.annotationsJSON().utf8)) as? [String: Any]
        let a = (annotations?["/a"] as? [String: Any])?["title"] as? [String: Any]
        XCTAssertEqual(a?["#/properties/a"] as? String, "A")
        try titled.evaluate(json: Data("{}".utf8), collector: verbose)
        XCTAssertFalse(verbose.results.isEmpty)
    }

    func testThreadsShareAValidator() throws {
        let validator = try Validator(
            schema: person, options: Options(assertFormat: true, formats: ["x": { _ in true }]))
        let failures = Counter()
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            for j in 0..<500 {
                let valid = (i + j) % 2 == 0
                let json = valid ? #"{"name": "Ada"}"# : #"{"name": 1}"#
                if (try? validator.isValid(json: json)) != valid {
                    failures.increment()
                }
            }
        }
        XCTAssertEqual(failures.value, 0)
    }

    func testLibraryVersion() {
        XCTAssertNotNil(Validator.libraryVersion.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
