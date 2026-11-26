// swift-tools-version: 6.2
import PackageDescription

// SmithCore: everything that doesn't need a screen — parsing the Chronicles
// export, the privacy filters, the day overview, the persona and the Claude
// client. Kept in a package so `swift test` runs it fast on the Mac.
let package = Package(
    name: "SmithCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "SmithCore", targets: ["SmithCore"])],
    targets: [
        .target(name: "SmithCore"),
        .testTarget(
            name: "SmithCoreTests",
            dependencies: ["SmithCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
