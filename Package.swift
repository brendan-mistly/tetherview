// swift-tools-version:5.9
// The protocol core is a plain Swift package so it can be unit-tested with
// `swift test` on macOS or Linux. The iPhone app (App/) compiles these same
// sources directly; see project.yml.
import PackageDescription

let package = Package(
    name: "TetherviewCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "TetherviewCore", targets: ["TetherviewCore"]),
    ],
    targets: [
        .target(name: "TetherviewCore", path: "Sources/TetherviewCore"),
        .testTarget(name: "TetherviewCoreTests", dependencies: ["TetherviewCore"],
                    path: "Tests/TetherviewCoreTests"),
    ]
)
