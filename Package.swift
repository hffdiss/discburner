// swift-tools-version:5.4
import PackageDescription

let package = Package(
    name: "DiscBurner",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .library(name: "DiscBurnKit", targets: ["DiscBurnKit"]),
        .executable(name: "discburn", targets: ["discburn"]),
        .executable(name: "DiscBurner", targets: ["DiscBurnerApp"]),
        .executable(name: "discburn-selftest", targets: ["DiscBurnSelfTest"]),
    ],
    targets: [
        .target(
            name: "DiscBurnKit",
            path: "Sources/DiscBurnKit"
        ),
        .executableTarget(
            name: "discburn",
            dependencies: ["DiscBurnKit"],
            path: "Sources/discburn"
        ),
        .executableTarget(
            name: "DiscBurnerApp",
            dependencies: ["DiscBurnKit"],
            path: "Sources/DiscBurnerApp"
        ),
        .executableTarget(
            name: "DiscBurnSelfTest",
            dependencies: ["DiscBurnKit"],
            path: "Sources/DiscBurnSelfTest"
        ),
    ]
)
