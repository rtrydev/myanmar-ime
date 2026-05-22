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
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .apt(["libsqlite3-dev"]),
                .brew(["sqlite3"])
            ]
        ),
        .target(
            name: "BurmeseIMECore",
            dependencies: [
                .target(name: "CSQLite", condition: .when(platforms: [.linux, .windows]))
            ],
            exclude: ["LanguageModel/FORMAT.md"],
            resources: [.process("Data/NumberMeasureWords.tsv")]
        ),
        .target(
            name: "BurmeseIMETestSupport",
            dependencies: [
                "BurmeseIMECore",
                .target(name: "CSQLite", condition: .when(platforms: [.linux, .windows]))
            ]
        ),
        .executableTarget(
            name: "LexiconBuilder",
            dependencies: [
                "BurmeseIMECore",
                .target(name: "CSQLite", condition: .when(platforms: [.linux, .windows]))
            ]
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
