// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RollcallCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "RollcallCore", targets: ["RollcallCore"])],
    targets: [
        .target(name: "RollcallCore", path: "FreeRollcall/Core"),
        .testTarget(name: "RollcallCoreTests", dependencies: ["RollcallCore"], path: "CoreTests")
    ],
    swiftLanguageModes: [.v5]
)
