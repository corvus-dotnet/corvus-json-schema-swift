// swift-tools-version:5.9
import PackageDescription

// The corvus-json-schema C library, as the Clang module CCorvusJsonSchema: on Apple platforms the XCFramework attached
// to the C library's release; elsewhere the C library installed on the system, found through its pkg-config file
// (corvus-json-schema.pc, in the release's package for the platform).
#if canImport(Darwin)
let cLibrary: Target = .binaryTarget(
    name: "CCorvusJsonSchema",
    url: "https://github.com/corvus-dotnet/Corvus.JsonSchema/releases/download/capi-v0.1.2/CorvusJsonSchema.xcframework.zip",
    checksum: "f14152293aee6f528879e208dfd4df5b136283f3662783c646f57895444cf6a9"
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
