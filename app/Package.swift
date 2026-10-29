// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SNotes",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SamsungNotesKit", targets: ["SamsungNotesKit"]),
        .executable(name: "snotes-probe", targets: ["snotes-probe"]),
        .executable(name: "SNotes", targets: ["SNotes"]),
    ],
    targets: [
        .target(name: "SamsungNotesKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "snotes-probe", dependencies: ["SamsungNotesKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "SNotes", dependencies: ["SamsungNotesKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "SamsungNotesKitTests",
            dependencies: ["SamsungNotesKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
