// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FountainCoreMIDIBridge",
    platforms: [ .macOS(.v13) ],
    products: [ .executable(name: "FountainCoreMIDIBridge", targets: ["FountainCoreMIDIBridge"]) ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.58.0")
    ],
    targets: [
        .executableTarget(
            name: "FountainCoreMIDIBridge",
            dependencies: [ .product(name: "NIO", package: "swift-nio"), .product(name: "NIOHTTP1", package: "swift-nio") ],
            path: "Sources/FountainCoreMIDIBridge"
        )
    ]
)
