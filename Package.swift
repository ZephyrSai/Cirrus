// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Cirrus",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // The shared engine, used by the Mac app here and by the iPhone/iPad app in ios/.
        .library(name: "CirrusCore", targets: ["CirrusCore"]),
    ],
    targets: [
        .target(name: "CirrusCore", path: "Sources/CirrusCore", swiftSettings: v5),
        .executableTarget(name: "Cirrus", dependencies: ["CirrusCore"], path: "Sources/Cirrus", swiftSettings: v5),
        .testTarget(name: "CirrusCoreTests", dependencies: ["CirrusCore"], path: "Tests/CirrusCoreTests",
                    resources: [.copy("Fixtures")], swiftSettings: v5),
    ]
)
