// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Volumio",
    platforms: [.macOS("14.4")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Volumio",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Volumio",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
