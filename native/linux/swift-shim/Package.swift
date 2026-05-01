// swift-tools-version: 6.0
import PackageDescription

// Linux-only dynamic-library shim around BurmeseIMECore. Loaded by
// `ibus-engine-myangler` via dlopen; exposes a flat C ABI declared in
// `native/linux/ibus-engine/src/ffi.h`.
//
// Build: `swift build -c release --product BurmeseIMEFFI` (with
// `-Xswiftc -static-stdlib` for distribution; see scripts/build-swift-shim.sh).
let package = Package(
    name: "BurmeseIMEFFI",
    products: [
        .library(
            name: "BurmeseIMEFFI",
            type: .dynamic,
            targets: ["BurmeseIMEFFI"]
        ),
    ],
    dependencies: [
        .package(path: "../../../Packages/BurmeseIMECore"),
    ],
    targets: [
        .target(
            name: "BurmeseIMEFFI",
            dependencies: [
                .product(name: "BurmeseIMECore", package: "BurmeseIMECore"),
            ]
        ),
    ]
)
