// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BurmeseIMECore",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "BurmeseIMECore",
            targets: ["BurmeseIMECore"]
        ),
    ],
    targets: [
        .target(
            name: "BurmeseIMECore",
            exclude: ["LanguageModel/FORMAT.md"],
            resources: [.process("Data/NumberMeasureWords.tsv")]
        ),
        .executableTarget(
            name: "LexiconBuilder",
            dependencies: ["BurmeseIMECore"]
        ),
        .executableTarget(
            name: "TestRunner",
            dependencies: ["BurmeseIMECore"],
            path: "Tests/TestRunner"
        ),
        .testTarget(
            name: "BurmeseIMECoreTests",
            dependencies: ["BurmeseIMECore"]
        ),
    ]
)
