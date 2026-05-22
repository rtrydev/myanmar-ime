// swift-tools-version: 6.0
import PackageDescription

// Windows-only dynamic-library shim around BurmeseIMECore. Loaded by
// the planned TSF text service DLL via LoadLibraryW + GetProcAddress
// (or the import lib produced alongside the .dll); exposes the same
// flat C ABI as the Linux shim, declared in
// `native/linux/ibus-engine/src/ffi.h`. The three .swift files in
// Sources/BurmeseIMEFFI/ are copied verbatim from
// `native/linux/swift-shim/Sources/BurmeseIMEFFI/` — they are pure
// Foundation + @_cdecl and have no platform-specific dependencies.
// Keep both shims byte-identical so the FFI contract cannot drift.
//
// Build (from this directory):
//   swift build -c release --product BurmeseIMEFFI
//
// The release build emits BurmeseIMEFFI.dll and the import lib
// BurmeseIMEFFI.lib next to it. Unlike Linux, Swift on Windows does
// not currently support -static-stdlib for distribution, so the MSI
// installer must redistribute the Swift runtime DLLs from
// `%LOCALAPPDATA%\Programs\Swift\Runtimes\<version>\` alongside the
// TIP. See CLAUDE.md "Native Shells -> Windows" for the broader
// architecture.
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
            ],
            linkerSettings: [
                // Promote the @_cdecl symbols into the DLL export
                // table. SwiftPM's Windows linker auto-exports
                // Swift-mangled names but not the plain C names;
                // BurmeseIMEFFI.def at the package root enumerates
                // them explicitly. See that file for the why.
                .unsafeFlags(["-Xlinker", "/DEF:BurmeseIMEFFI.def"]),
            ]
        ),
    ]
)
