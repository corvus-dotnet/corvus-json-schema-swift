import CCorvusJsonSchema
import Foundation

/// A JSON Schema dialect.
public enum Dialect: Sendable {
    case draft4
    case draft6
    case draft7
    case draft201909
    case draft202012

    var cValue: cjs_dialect {
        switch self {
        case .draft4: return cjs_dialect(CJS_DRAFT4)
        case .draft6: return cjs_dialect(CJS_DRAFT6)
        case .draft7: return cjs_dialect(CJS_DRAFT7)
        case .draft201909: return cjs_dialect(CJS_DRAFT201909)
        case .draft202012: return cjs_dialect(CJS_DRAFT202012)
        }
    }
}

/// How a schema is compiled.
public struct Options: Sendable {
    /// The dialect of schemas without `$schema`.
    public var defaultDialect: Dialect = .draft202012
    /// Whether `format` is asserted; `nil` follows the schema's vocabularies (the 2020-12 format-assertion vocabulary
    /// asserts, everything else annotates).
    public var assertFormat: Bool?
    /// With `assertFormat` left `nil`, assert `format` in drafts 4 to 7 too.
    public var assertFormatInLegacyDrafts = false
    /// Assert `contentEncoding` and `contentMediaType` in draft 7, the only draft that asserts them.
    public var assertContent = true
    /// The base URI of the root schema document, when it has no `$id`.
    public var baseURI: String?
    /// A reference, relative to the root, to evaluate from, such as "#/$defs/item".
    public var entryPoint: String?
    /// The maximum depth of in-place recursion on a cycle before evaluation is abandoned (`DepthExceeded`).
    public var maxDepth: UInt32 = 128
    /// Custom format assertions, by format name: whether the string (or, for a number, its JSON text) is valid. They
    /// run during validation, on whichever thread validates.
    public var formats: [String: @Sendable (String) -> Bool] = [:]
    /// The resolver for documents other than the standard metaschemas: for an absolute URI, the document's JSON text,
    /// or `nil` for an unknown document. It runs during compilation; an error it throws is thrown by the compilation.
    public var resolver: (@Sendable (String) throws -> String?)?

    public init(
        defaultDialect: Dialect = .draft202012,
        assertFormat: Bool? = nil,
        assertFormatInLegacyDrafts: Bool = false,
        assertContent: Bool = true,
        baseURI: String? = nil,
        entryPoint: String? = nil,
        maxDepth: UInt32 = 128,
        formats: [String: @Sendable (String) -> Bool] = [:],
        resolver: (@Sendable (String) throws -> String?)? = nil
    ) {
        self.defaultDialect = defaultDialect
        self.assertFormat = assertFormat
        self.assertFormatInLegacyDrafts = assertFormatInLegacyDrafts
        self.assertContent = assertContent
        self.baseURI = baseURI
        self.entryPoint = entryPoint
        self.maxDepth = maxDepth
        self.formats = formats
        self.resolver = resolver
    }

    /// Sets the C options; returns the resolver's box, which holds the error a Swift resolver threw.
    func apply(to options: OpaquePointer) throws -> ResolverBox? {
        try check(cjs_options_set_default_dialect(options, defaultDialect.cValue))
        let tristate = assertFormat.map { $0 ? CJS_TRUE : CJS_FALSE } ?? CJS_DEFAULT
        try check(cjs_options_set_assert_format(options, cjs_tristate(tristate)))
        try check(cjs_options_set_assert_format_in_legacy_drafts(options, assertFormatInLegacyDrafts))
        try check(cjs_options_set_assert_content(options, assertContent))
        if var baseURI {
            try check(baseURI.withUTF8 { cjs_options_set_base_uri(options, pointer($0), $0.count) })
        }
        if var entryPoint {
            try check(entryPoint.withUTF8 { cjs_options_set_entry_point(options, pointer($0), $0.count) })
        }
        try check(cjs_options_set_max_depth(options, maxDepth))
        for (name, format) in formats {
            var name = name
            // The box is released when the options and every validator compiled with them have been freed.
            let box = Unmanaged.passRetained(FormatBox(format)).toOpaque()
            try check(name.withUTF8 {
                cjs_options_add_format(options, pointer($0), $0.count, formatTrampoline, box, releaseBox)
            })
        }
        guard let resolver else {
            return nil
        }
        let box = ResolverBox(resolver)
        try check(cjs_options_set_resolver(options, resolveTrampoline, Unmanaged.passRetained(box).toOpaque(), releaseBox))
        return box
    }
}

final class FormatBox {
    let format: @Sendable (String) -> Bool

    init(_ format: @escaping @Sendable (String) -> Bool) {
        self.format = format
    }
}

/// A resolver, and the first error it threw (resolvers run on the compiling thread, during one compilation).
final class ResolverBox {
    let resolve: @Sendable (String) throws -> String?
    private var error: Error?

    init(_ resolve: @escaping @Sendable (String) throws -> String?) {
        self.resolve = resolve
    }

    func record(_ error: Error) {
        if self.error == nil {
            self.error = error
        }
    }

    func takeError() -> Error? {
        defer { error = nil }
        return error
    }
}

private let formatTrampoline: cjs_format_fn = { userData, value, length in
    let box = Unmanaged<FormatBox>.fromOpaque(userData!).takeUnretainedValue()
    let text = String(decoding: UnsafeRawBufferPointer(start: value, count: length), as: UTF8.self)
    return box.format(text)
}

private let resolveTrampoline: cjs_resolve_fn = { userData, uri, length, out in
    let box = Unmanaged<ResolverBox>.fromOpaque(userData!).takeUnretainedValue()
    let uri = String(decoding: UnsafeRawBufferPointer(start: uri, count: length), as: UTF8.self)
    do {
        guard var document = try box.resolve(uri) else {
            return cjs_status(CJS_OK)
        }
        return document.withUTF8 { cjs_resolved_set_json(out, pointer($0), $0.count) }
    } catch {
        box.record(error)
        var message = "the resolver failed for \(uri): \(error)"
        _ = message.withUTF8 { cjs_resolved_set_error(out, pointer($0), $0.count) }
        return cjs_status(CJS_COMPILATION_FAILED)
    }
}

private let releaseBox: cjs_free_fn = { userData in
    Unmanaged<AnyObject>.fromOpaque(userData!).release()
}
