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

    /// A `not` that leads back to the schema it is in recurses in place like any other applicator, and stops at the
    /// maximum depth. The C library before 0.1.3 evaluated `not` around the depth guard, so the first of these
    /// schemas overflowed the stack, which ends the process.
    func testNotOnAnInPlaceCycleStopsAtTheMaximumDepth() throws {
        let schemas = [
            ##"{"not": {"$ref": "#"}}"##,
            ##"{"not": {"not": {"$ref": "#"}}}"##,
            ##"{"allOf": [{"not": {"$ref": "#"}}]}"##,
            ##"{"$defs": {"loop": {"allOf": [{"$ref": "#/$defs/loop"}]}}, "not": {"$ref": "#/$defs/loop"}}"##,
        ]
        for schema in schemas {
            let validator = try Validator(schema: schema, options: Options(maxDepth: 16))
            for instance in ["1", ##"{"a": 1}"##] {
                XCTAssertThrowsError(try validator.isValid(json: instance), schema) { error in
                    guard case JSONSchemaError.depthExceeded = error else {
                        return XCTFail("\(schema): \(error)")
                    }
                }
            }
        }
    }

    /// A pattern whose class has a member outside ASCII (U+00E9). The C library before 0.1.2 kept the class as bits
    /// for ASCII characters and read that member as two of them (C and a closing parenthesis), so it gave the wrong
    /// answers here.
    func testPatternClassWithAMemberOutsideASCII() throws {
        let validator = try Validator(schema: #"{"pattern": "^(?=[^é]+$)(?=(.*\\w)).+$"}"#)
        XCTAssertTrue(try validator.isValid(json: #""C1""#))
        XCTAssertTrue(try validator.isValid(json: #"")a""#))
        XCTAssertFalse(try validator.isValid(json: #""é1""#))
        XCTAssertFalse(try validator.isValid(json: #""---""#))
    }

    /// A pattern that backtracks without end on `neverAnswered`.
    let neverAnswers = #"^(?:(a+)\\1*)+$"#
    let neverAnswered = String(repeating: "a", count: 60) + "b"

    /// A match that reaches its limit throws, and is never an answer. The C library before 0.1.4 had no limit, and
    /// such a match did not end.
    func testAMatchThatReachesItsLimitThrows() throws {
        let validator = try Validator(
            schema: #"{"pattern": "\#(neverAnswers)"}"#, options: Options(patternMatchLimit: 0.05))
        let document = try Document(json: #""\#(neverAnswered)""#)
        let collector = Collector()
        let checks: [() throws -> Bool] = [
            { try validator.isValid(json: #""\#(self.neverAnswered)""#) },
            { try validator.isValid(document) },
            { try validator.evaluate(document, collector: collector) },
        ]
        for check in checks {
            let start = DispatchTime.now().uptimeNanoseconds
            XCTAssertThrowsError(try check()) { error in
                guard case JSONSchemaError.patternMatchLimit(let message) = error else {
                    return XCTFail("\(error)")
                }
                XCTAssertTrue(message.contains("50ms"), message)
            }
            let took = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            XCTAssertGreaterThanOrEqual(took, 0.04)
            XCTAssertLessThan(took, 20)
        }
        XCTAssertTrue(try validator.isValid(json: #""aaaa""#))
        XCTAssertFalse(try validator.isValid(json: #""b""#))
    }

    /// The default is one second, and `nil`, zero or less turns the limit off: the match runs to its end.
    func testTheDefaultMatchLimitIsOneSecondAndCanBeTurnedOff() throws {
        XCTAssertEqual(Options.defaultPatternMatchLimit, 1)
        XCTAssertEqual(Options().patternMatchLimit, 1)
        let validator = try Validator(schema: #"{"patternProperties": {"\#(neverAnswers)": {"type": "integer"}}}"#)
        let start = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(try validator.isValid(json: #"{"\#(neverAnswered)": 1}"#)) { error in
            guard case JSONSchemaError.patternMatchLimit(let message) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(message.contains("1s"), message)
        }
        let took = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        XCTAssertGreaterThanOrEqual(took, 0.9)
        XCTAssertLessThan(took, 21)
        for off: TimeInterval? in [nil, 0, -1] {
            let unlimited = try Validator(
                schema: #"{"pattern": "\#(neverAnswers)"}"#, options: Options(patternMatchLimit: off))
            XCTAssertFalse(try unlimited.isValid(json: #""\#(String(repeating: "a", count: 14))b""#))
        }
    }

    /// A match whose backtracking reaches its memory limit throws the same error.
    func testAMatchThatReachesItsMemoryLimitThrows() throws {
        let validator = try Validator(schema: #"{"pattern": "(?:a?){2147483647}"}"#)
        XCTAssertThrowsError(try validator.isValid(json: #""""#)) { error in
            guard case JSONSchemaError.patternMatchLimit(let message) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(message.contains("1,048,576 backtracking entries"), message)
        }
    }

    /// A pattern over a limit of size is refused as too large, and not as not valid.
    func testAPatternOverALimitOfSizeIsNotAnInvalidPattern() throws {
        func nest(_ depth: Int) -> String {
            String(repeating: "(?:", count: depth) + "a" + String(repeating: ")", count: depth)
        }
        let limits = [
            (String(repeating: "a", count: 16_384), String(repeating: "a", count: 16_385),
             "the pattern has a size of more than 1048576 bytes when it is read"),
            (nest(999), nest(1000), "the groups of the pattern nest more than 1000 deep"),
        ]
        for (at, over, reason) in limits {
            _ = try Validator(schema: #"{"pattern": "\#(at)"}"#)
            for schema in [#"{"pattern": "\#(over)"}"#, #"{"patternProperties": {"\#(over)": true}}"#] {
                XCTAssertThrowsError(try Validator(schema: schema)) { error in
                    guard case JSONSchemaError.patternTooLarge(let message) = error else {
                        return XCTFail("\(error)")
                    }
                    XCTAssertTrue(
                        message.hasSuffix("is too large to read as an ECMA-262 regular expression: \(reason)."), message)
                    XCTAssertFalse(message.lowercased().contains("invalid"), message)
                    XCTAssertLessThan(message.count, 400)
                }
            }
        }
        XCTAssertThrowsError(try Validator(schema: #"{"pattern": "a**"}"#)) { error in
            guard case JSONSchemaError.compilationFailed(let message) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(message.hasPrefix("Invalid regular expression"), message)
        }
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
