// swift-tools-version:5.9
import PackageDescription

// The corvus-json-schema C library, as the Clang module CCorvusJsonSchema: on Apple platforms the XCFramework attached
// to the C library's release; elsewhere the C library installed on the system, found through its pkg-config file
// (corvus-json-schema.pc, in the release's package for the platform).
#if canImport(Darwin)
let cLibrary: Target = .binaryTarget(
    name: "CCorvusJsonSchema",
    url: "https://github.com/corvus-dotnet/Corvus.JsonSchema/releases/download/capi-v0.1.4/CorvusJsonSchema.xcframework.zip",
    checksum: "18ac0e866f1652b032f1de1c4578a65c23d5a48552ee65edde0d06a1adcc792d"
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
