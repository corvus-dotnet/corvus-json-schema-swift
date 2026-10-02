import CorvusJsonSchema
import Foundation
import XCTest

/// The JSON-Schema-Test-Suite (the JSON-Schema-Test-Suite submodule, or JSON_SCHEMA_TEST_SUITE): every case as JSON
/// text, as a parsed document, and at the verbose level through a collector, which must give the same verdict. The
/// schemas and instances are cut from the files as they are written (JSONSerialization would rewrite numbers such as
/// 1.0). Remote references are served by a resolver over the suite's remotes.
final class SuiteTests: XCTestCase {
    static let drafts: [(String, Dialect)] = [
        ("draft4", .draft4), ("draft6", .draft6), ("draft7", .draft7),
        ("draft2019-09", .draft201909), ("draft2020-12", .draft202012),
    ]
    // As the other runners: a JSON parser cannot tell 1.0 from 1 here (draft 4 does not count 1.0 as an integer).
    static let excluded: Set<String> = ["draft4/optional/zeroTerminatedFloats.json"]

    func testJSONSchemaTestSuite() throws {
        let root = ProcessInfo.processInfo.environment["JSON_SCHEMA_TEST_SUITE"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("JSON-Schema-Test-Suite")
        let tests = root.appendingPathComponent("tests")
        guard FileManager.default.fileExists(atPath: tests.path) else {
            throw XCTSkip("JSON-Schema-Test-Suite not found at \(root.path)")
        }
        let remotes = root.appendingPathComponent("remotes")
        let resolver: @Sendable (String) throws -> String? = { uri in
            let prefix = "http://localhost:1234/"
            guard uri.hasPrefix(prefix) else {
                return nil
            }
            return try? String(contentsOf: remotes.appendingPathComponent(String(uri.dropFirst(prefix.count))), encoding: .utf8)
        }

        var total = 0
        var failures: [String] = []
        for (draft, dialect) in Self.drafts {
            let directory = tests.appendingPathComponent(draft)
            var files = try jsonFiles(directory).map { ($0, false) }
            files += try jsonFiles(directory.appendingPathComponent("optional")).map { ($0, false) }
            files += try jsonFiles(directory.appendingPathComponent("optional/format")).map { ($0, true) }
            for (file, assertFormat) in files {
                let label = String(file.path.dropFirst(tests.path.count + 1))
                if Self.excluded.contains(label) {
                    continue
                }
                var json = RawJSON(try Data(contentsOf: file))
                for group in try json.groups() {
                    let validator: Validator
                    do {
                        validator = try Validator(
                            schema: group.schema,
                            options: Options(defaultDialect: dialect, assertFormat: assertFormat ? true : nil, resolver: resolver))
                    } catch {
                        failures.append("\(label) [\(group.description)]: \(error)")
                        continue
                    }
                    for test in group.tests {
                        total += 1
                        let what = "\(label) [\(group.description)] \(test.description)"
                        if assertFormat && what.lowercased().contains("leap second") {
                            continue
                        }
                        do {
                            let text = try validator.isValid(json: test.data)
                            let document = try validator.isValid(Document(json: test.data))
                            let collected = try validator.evaluate(json: test.data, collector: Collector(level: .verbose))
                            if (text, document, collected) != (test.valid, test.valid, test.valid) {
                                failures.append("\(what): expected \(test.valid), got \(text) \(document) \(collected)")
                            }
                        } catch {
                            failures.append("\(what): \(error)")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(total, 7000)
        XCTAssertTrue(failures.isEmpty, "\(failures.count) of \(total) failed:\n" + failures.prefix(40).joined(separator: "\n"))
        print("\(total) cases: every one as JSON text, as a document and through a collector")
    }

    private func jsonFiles(_ directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// A test file's groups, with each schema and instance as the JSON text the file holds.
struct RawJSON {
    struct Group {
        var description: String
        var schema: String
        var tests: [Test]
    }

    struct Test {
        var description: String
        var data: String
        var valid: Bool
    }

    let bytes: [UInt8]
    var i = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    mutating func groups() throws -> [Group] {
        var groups: [Group] = []
        try array { json in
            var group = Group(description: "", schema: "", tests: [])
            try json.object { json, key in
                switch key {
                case "description": group.description = try json.string()
                case "schema": group.schema = try json.raw()
                case "tests":
                    try json.array { json in
                        var test = Test(description: "", data: "", valid: false)
                        try json.object { json, key in
                            switch key {
                            case "description": test.description = try json.string()
                            case "data": test.data = try json.raw()
                            case "valid": test.valid = try json.raw() == "true"
                            default: _ = try json.raw()
                            }
                        }
                        group.tests.append(test)
                    }
                default: _ = try json.raw()
                }
            }
            groups.append(group)
        }
        return groups
    }

    struct Malformed: Error {}

    private mutating func space() {
        while i < bytes.count, [0x20, 0x0a, 0x0d, 0x09].contains(bytes[i]) {
            i += 1
        }
    }

    private mutating func expect(_ byte: UInt8) throws {
        space()
        guard i < bytes.count, bytes[i] == byte else {
            throw Malformed()
        }
        i += 1
    }

    private mutating func peek(_ byte: UInt8) -> Bool {
        space()
        return i < bytes.count && bytes[i] == byte
    }

    private mutating func array(_ item: (inout RawJSON) throws -> Void) throws {
        try expect(0x5b)
        if peek(0x5d) {
            i += 1
            return
        }
        repeat {
            try item(&self)
        } while try comma(or: 0x5d)
    }

    private mutating func object(_ member: (inout RawJSON, String) throws -> Void) throws {
        try expect(0x7b)
        if peek(0x7d) {
            i += 1
            return
        }
        repeat {
            let key = try string()
            try expect(0x3a)
            try member(&self, key)
        } while try comma(or: 0x7d)
    }

    private mutating func comma(or close: UInt8) throws -> Bool {
        space()
        guard i < bytes.count else {
            throw Malformed()
        }
        i += 1
        if bytes[i - 1] == 0x2c {
            return true
        }
        guard bytes[i - 1] == close else {
            throw Malformed()
        }
        return false
    }

    private mutating func string() throws -> String {
        let text = try raw()
        guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) as? String else {
            throw Malformed()
        }
        return value
    }

    /// The next value's JSON text.
    private mutating func raw() throws -> String {
        space()
        let start = i
        try skip()
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }

    private mutating func skip() throws {
        space()
        guard i < bytes.count else {
            throw Malformed()
        }
        switch bytes[i] {
        case 0x7b: try object { json, _ in try json.skip() }
        case 0x5b: try array { json in try json.skip() }
        case 0x22:
            i += 1
            while i < bytes.count, bytes[i] != 0x22 {
                i += bytes[i] == 0x5c ? 2 : 1
            }
            i += 1
        default:
            while i < bytes.count, ![0x2c, 0x5d, 0x7d, 0x20, 0x0a, 0x0d, 0x09].contains(bytes[i]) {
                i += 1
            }
        }
    }
}
