// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Islet",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Islet", targets: ["Islet"])
    ],
    dependencies: [
        // Sparkle (MIT): signed in-app updates.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        // Pure, UI-free logic: stream decoding, lyrics, lookups, palettes.
        .target(name: "IsletCore", path: "Sources/IsletCore"),
        // The menu-bar app: island, full-screen player, lock screen.
        .executableTarget(
            name: "Islet",
            dependencies: ["IsletCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Islet",
            // Sparkle.framework ships inside the app bundle.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "IsletCoreTests",
            dependencies: ["IsletCore"],
            path: "Tests/IsletCoreTests"
        ),
    ]
)
