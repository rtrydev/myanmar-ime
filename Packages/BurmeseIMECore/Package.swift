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
        .target(
            name: "BurmeseIMETestSupport",
            dependencies: ["BurmeseIMECore"]
        ),
        .executableTarget(
            name: "LexiconBuilder",
            dependencies: ["BurmeseIMECore"]
        ),
        .executableTarget(
            name: "BurmeseBench",
            dependencies: ["BurmeseIMECore", "BurmeseIMETestSupport"]
        ),
        .executableTarget(
            name: "TestRunner",
            dependencies: ["BurmeseIMECore", "BurmeseIMETestSupport"],
            path: "Tests/TestRunner"
        ),
        .testTarget(
            name: "BurmeseIMECoreTests",
            dependencies: ["BurmeseIMECore", "BurmeseIMETestSupport"]
        ),
    ]
)
