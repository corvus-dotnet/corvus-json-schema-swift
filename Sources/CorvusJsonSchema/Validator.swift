import CCorvusJsonSchema
import Foundation

/// A compiled JSON Schema: immutable, and safe to use from any number of threads at once.
///
/// ```swift
/// let validator = try Validator(schema: #"{"type": "object", "required": ["id"]}"#)
/// try validator.isValid(json: #"{"id": 3}"#)  // true
/// ```
public final class Validator: @unchecked Sendable {
    let handle: OpaquePointer

    /// Compiles a schema from its JSON text.
    public init(schema: String, options: Options = Options()) throws {
        handle = try Self.compile(options) { cOptions, out in
            var schema = schema
            return schema.withUTF8 { cjs_compile(pointer($0), $0.count, cOptions, out) }
        }
    }

    /// Compiles a schema from its JSON text, as UTF-8 bytes.
    public init(schema: Data, options: Options = Options()) throws {
        handle = try Self.compile(options) { cOptions, out in
            schema.withUnsafeBytes { cjs_compile(pointer($0), $0.count, cOptions, out) }
        }
    }

    /// Compiles the schema document at an absolute URI, fetched through the options' resolver (or one of the standard
    /// metaschemas).
    public init(schemaURI: String, options: Options = Options()) throws {
        handle = try Self.compile(options) { cOptions, out in
            var uri = schemaURI
            return uri.withUTF8 { cjs_compile_uri(pointer($0), $0.count, cOptions, out) }
        }
    }

    deinit {
        cjs_validator_free(handle)
    }

    /// Whether the JSON text is valid. The text is parsed into per-thread buffers and evaluated in place: in the
    /// steady state this allocates nothing.
    public func isValid(json: String) throws -> Bool {
        var json = json
        return try json.withUTF8 { text in
            try validity { cjs_validator_validate_json(handle, pointer(text), text.count, $0) }
        }
    }

    /// Whether the JSON text, as UTF-8 bytes, is valid.
    public func isValid(json: Data) throws -> Bool {
        try json.withUnsafeBytes { text in
            try validity { cjs_validator_validate_json(handle, pointer(text), text.count, $0) }
        }
    }

    /// Whether the parsed document is valid (to validate the same JSON more than once).
    public func isValid(_ document: Document) throws -> Bool {
        try validity { cjs_validator_validate_document(handle, document.handle, $0) }
    }

    /// Evaluates the JSON text into the collector, replacing its results (every keyword is evaluated and reported at
    /// the collector's level). Returns whether the JSON is valid.
    @discardableResult
    public func evaluate(json: String, collector: Collector) throws -> Bool {
        var json = json
        return try json.withUTF8 { text in
            try validity { cjs_validator_evaluate_json(handle, pointer(text), text.count, collector.handle, $0) }
        }
    }

    /// Evaluates the JSON text, as UTF-8 bytes, into the collector.
    @discardableResult
    public func evaluate(json: Data, collector: Collector) throws -> Bool {
        try json.withUnsafeBytes { text in
            try validity { cjs_validator_evaluate_json(handle, pointer(text), text.count, collector.handle, $0) }
        }
    }

    /// Evaluates the parsed document into the collector.
    @discardableResult
    public func evaluate(_ document: Document, collector: Collector) throws -> Bool {
        try validity { cjs_validator_evaluate_document(handle, document.handle, collector.handle, $0) }
    }

    /// The version of the corvus-json-schema C library, such as "0.1.1".
    public static var libraryVersion: String {
        string(cjs_version_string())
    }

    private func validity(_ call: (UnsafeMutablePointer<Bool>) -> cjs_status) throws -> Bool {
        var valid = false
        try check(call(&valid))
        return valid
    }

    private static func compile(
        _ options: Options,
        _ call: (OpaquePointer, UnsafeMutablePointer<OpaquePointer?>) -> cjs_status
    ) throws -> OpaquePointer {
        guard let cOptions = cjs_options_new() else {
            throw JSONSchemaError.internalError("the options could not be created")
        }
        defer { cjs_options_free(cOptions) }
        let resolver = try options.apply(to: cOptions)
        var out: OpaquePointer?
        let status = call(cOptions, &out)
        // A resolver's own error is thrown as it is.
        if let error = resolver?.takeError() {
            throw error
        }
        try check(status)
        guard let out else {
            throw JSONSchemaError.internalError("compilation succeeded without a validator")
        }
        return out
    }
}

/// A parsed JSON document, to validate the same JSON more than once without parsing it again. Immutable, and safe to
/// share between threads.
public final class Document: @unchecked Sendable {
    let handle: OpaquePointer

    /// Parses JSON text (copied).
    public init(json: String) throws {
        var json = json
        handle = try json.withUTF8 { text in try Self.parse(UnsafeRawBufferPointer(text)) }
    }

    /// Parses JSON text, as UTF-8 bytes (copied).
    public init(json: Data) throws {
        handle = try json.withUnsafeBytes { text in try Self.parse(text) }
    }

    deinit {
        cjs_document_free(handle)
    }

    private static func parse(_ text: UnsafeRawBufferPointer) throws -> OpaquePointer {
        var out: OpaquePointer?
        try check(cjs_document_parse(pointer(text), text.count, &out))
        guard let out else {
            throw JSONSchemaError.internalError("parsing succeeded without a document")
        }
        return out
    }
}

/// How much a `Collector` records. At every level the root's own result is the last row.
public enum ResultsLevel: Sendable {
    /// The failures, without messages (the lowest overhead).
    case basic
    /// The failures, with messages.
    case detailed
    /// Every result, passing and failing, with messages, and annotations.
    case verbose

    var cValue: cjs_results_level {
        switch self {
        case .basic: return cjs_results_level(CJS_BASIC)
        case .detailed: return cjs_results_level(CJS_DETAILED)
        case .verbose: return cjs_results_level(CJS_VERBOSE)
        }
    }
}

/// One result row of an evaluation.
public struct SchemaResult: Sendable, Hashable {
    /// Whether the keyword or subschema matched.
    public var isMatch: Bool
    /// The message (empty at `.basic`, or when the keyword has none; raw JSON for an annotation row).
    public var message: String
    /// The path of keywords from the root schema, such as "/properties/name/type".
    public var evaluationLocation: String
    /// The JSON pointer of the evaluated schema or keyword within its document.
    public var schemaLocation: String
    /// The JSON pointer of the evaluated value, such as "/name".
    public var instanceLocation: String

    public init(
        isMatch: Bool, message: String, evaluationLocation: String, schemaLocation: String, instanceLocation: String
    ) {
        self.isMatch = isMatch
        self.message = message
        self.evaluationLocation = evaluationLocation
        self.schemaLocation = schemaLocation
        self.instanceLocation = instanceLocation
    }
}

/// The results of the latest evaluation into it. Used by one thread at a time.
public final class Collector {
    let handle: OpaquePointer

    /// A collector recording at the level.
    public init(level: ResultsLevel = .basic) {
        // cjs_collector_new fails only for a level out of range.
        handle = cjs_collector_new(level.cValue)!
    }

    deinit {
        cjs_collector_free(handle)
    }

    /// The result rows, in the order the evaluation committed them.
    public var results: [SchemaResult] {
        (0..<cjs_collector_count(handle)).map { i in
            SchemaResult(
                isMatch: cjs_collector_is_match(handle, i),
                message: string(cjs_collector_message(handle, i)),
                evaluationLocation: string(cjs_collector_evaluation_location(handle, i)),
                schemaLocation: string(cjs_collector_schema_location(handle, i)),
                instanceLocation: string(cjs_collector_instance_location(handle, i))
            )
        }
    }

    /// The annotations of a `.verbose` evaluation as JSON text, grouped by instance location, keyword and schema
    /// location: `{"/name": {"title": {"#/properties/name": "Name"}}}`.
    public func annotationsJSON() throws -> String {
        var out = cjs_str(ptr: nil, len: 0)
        try check(cjs_collector_annotations_json(handle, &out))
        return string(out)
    }

    /// Removes the results.
    public func clear() {
        cjs_collector_clear(handle)
    }
}

// Where a buffer's bytes start, for the C functions (which take NULL for no bytes).
func pointer(_ buffer: UnsafeRawBufferPointer) -> UnsafePointer<CChar>? {
    buffer.baseAddress?.assumingMemoryBound(to: CChar.self)
}

func pointer(_ buffer: UnsafeBufferPointer<UInt8>) -> UnsafePointer<CChar>? {
    pointer(UnsafeRawBufferPointer(buffer))
}

func string(_ s: cjs_str) -> String {
    guard let ptr = s.ptr, s.len > 0 else {
        return ""
    }
    return String(decoding: UnsafeRawBufferPointer(start: ptr, count: s.len), as: UTF8.self)
}
