# CorvusJsonSchema for Swift

A JSON Schema evaluator for Swift (draft 4, 6, 7, 2019-09 and 2020-12), over the
[corvus-json-schema C library](https://github.com/corvus-dotnet/Corvus.JsonSchema/tree/main/src-rs/corvus-json-schema-capi),
itself over the [corvus-json-schema](https://crates.io/crates/corvus-json-schema) Rust crate, the Rust port of the
Corvus.Text.Json V5 standalone evaluator.

- **Conformant**: passes the JSON-Schema-Test-Suite (required, optional and `optional/format`, every draft) except
  `draft4/optional/zeroTerminatedFloats.json`, which the other Corvus evaluators also exclude (a JSON parser reads
  `1.0` as an integer).
- **Fast**: JSON text is parsed into per-thread buffers and validated in place; in the steady state a validation
  allocates nothing. On the sourcemeta jsonschema-benchmark corpora the C library parses and validates in about a
  quarter of the time of the Blaze C++ validator.
- **Platforms**: macOS 10.15 and iOS 13 or later (through an XCFramework), and Linux (with the C library installed).
  Swift 5.9 or later.

## Install

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/corvus-dotnet/corvus-json-schema-swift", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "CorvusJsonSchema", package: "corvus-json-schema-swift")]),
]
```

On Apple platforms that is all: SwiftPM downloads the C library's XCFramework from its release.

On Linux, install the C library first: download the package for your platform
(`corvus-json-schema-<version>-<target>.tar.gz`, glibc 2.17 or later, or musl) from the
[C library's release](https://github.com/corvus-dotnet/Corvus.JsonSchema/releases) that `Package.swift` names, and
make its pkg-config file and shared library findable:

```sh
tar -xzf corvus-json-schema-0.1.3-x86_64-unknown-linux-gnu.tar.gz -C /opt
export PKG_CONFIG_PATH=/opt/corvus-json-schema-0.1.3-x86_64-unknown-linux-gnu/lib/pkgconfig
export LD_LIBRARY_PATH=/opt/corvus-json-schema-0.1.3-x86_64-unknown-linux-gnu/lib
```

(or copy its `include` and `lib` into `/usr/local` and run `ldconfig`).

## Usage

```swift
import CorvusJsonSchema

let validator = try Validator(schema: #"""
    {"type": "object", "required": ["id"], "properties": {"id": {"type": "integer"}}}
    """#)
try validator.isValid(json: #"{"id": 3}"#)    // true
try validator.isValid(json: #"{"id": "3"}"#)  // false

let collector = Collector(level: .detailed)
try validator.evaluate(json: #"{"id": "3"}"#, collector: collector)  // false
for result in collector.results where !result.isMatch {
    print(result.instanceLocation, result.message)  // "/id The value was expected to be of type 'integer'"
}
```

`Validator(schema:options:)` compiles a schema from its JSON text (a `String` or UTF-8 `Data`), and
`Validator(schemaURI:options:)` the document at a URI, through the resolver. `Options`:

| Option | Default | Meaning |
| --- | --- | --- |
| `defaultDialect` | `.draft202012` | The dialect of a schema without `$schema`. |
| `assertFormat` | `nil` | Whether `format` is asserted; `nil` follows the schema's vocabularies. |
| `assertFormatInLegacyDrafts` | `false` | Assert `format` in drafts 4 to 7 when `assertFormat` is `nil`. |
| `assertContent` | `true` | Assert `contentEncoding` and `contentMediaType` in draft 7. |
| `baseURI` | `nil` | The schema's base URI, when it has no `$id`. |
| `entryPoint` | `nil` | A reference to the subschema to validate against, such as `"#/$defs/item"`. |
| `maxDepth` | `128` | The deepest the evaluator recurses in place before it throws `depthExceeded`. |
| `formats` | `[:]` | Custom formats: name to a closure that returns whether the string is valid. They run on whichever thread validates. |
| `resolver` | `nil` | A closure from an absolute URI to the document's JSON text, or `nil` when it has none. An error it throws is thrown by the compilation. |

A `Validator` is immutable and `Sendable`: share one between threads.

- `isValid(json:)` (a `String` or UTF-8 `Data`) and `isValid(_ document:)` return whether the JSON is valid,
  evaluating only as far as the answer needs. A `Document` holds JSON parsed once, to validate it more than once.
- `evaluate(json:collector:)` and `evaluate(_:collector:)` evaluate every keyword, replacing the collector's results
  with this evaluation's. `Collector(level:)` takes `.basic` (the default: the failures, without messages),
  `.detailed` (the failures, with messages) or `.verbose` (every result, and annotations); at every level the root's
  own result is the last row. `results` holds the rows, `annotationsJSON()` gives the annotations of a verbose
  evaluation as JSON text, and `clear()` empties it. A collector is used by one thread at a time.

Errors are `JSONSchemaError`: `invalidJSON` and `invalidUTF8` (with the byte offset), `compilationFailed`,
`depthExceeded`, `invalidArgument` and `internalError`. `Validator.libraryVersion` is the C library's version.

## Development

`swift test` runs the API tests and the JSON-Schema-Test-Suite (the `JSON-Schema-Test-Suite` submodule:
`git submodule update --init`, or `JSON_SCHEMA_TEST_SUITE`). On Linux it needs the C library, as above.

The C library and the evaluator are developed in
[Corvus.JsonSchema](https://github.com/corvus-dotnet/Corvus.JsonSchema). Each of its C library releases
(`capi-v<version>`) attaches `CorvusJsonSchema.xcframework.zip` and gives its SwiftPM checksum; to move to a new
release, update the `binaryTarget`'s URL and checksum in `Package.swift`, and tag this repository's release.

## License

Apache-2.0
