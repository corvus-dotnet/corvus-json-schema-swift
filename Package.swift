// swift-tools-version:5.9
import PackageDescription

// The corvus-json-schema C library, as the Clang module CCorvusJsonSchema: on Apple platforms the XCFramework attached
// to the C library's release; elsewhere the C library installed on the system, found through its pkg-config file
// (corvus-json-schema.pc, in the release's package for the platform).
#if canImport(Darwin)
let cLibrary: Target = .binaryTarget(
    name: "CCorvusJsonSchema",
    url: "https://github.com/corvus-dotnet/Corvus.JsonSchema/releases/download/capi-v0.1.3/CorvusJsonSchema.xcframework.zip",
    checksum: "1c8bec2a82635b39045a6b9e5ce2defb29cc060a1cfcfaa4b13854ac3ef0e8b1"
)
#else
let cLibrary: Target = .systemLibrary(
    name: "CCorvusJsonSchema",
    path: "Linux/CCorvusJsonSchema",
    pkgConfig: "corvus-json-schema"
)
#endif

let package = Package(
    name: "CorvusJsonSchema",
    platforms: [.macOS(.v10_15), .iOS(.v13)],
    products: [
        .library(name: "CorvusJsonSchema", targets: ["CorvusJsonSchema"]),
    ],
    targets: [
        cLibrary,
        .target(name: "CorvusJsonSchema", dependencies: ["CCorvusJsonSchema"]),
        .testTarget(name: "CorvusJsonSchemaTests", dependencies: ["CorvusJsonSchema"]),
    ]
)
