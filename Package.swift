// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Kodau",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "KodauCore", targets: ["KodauCore"]),
        .executable(name: "Kodau", targets: ["KodauApp"]),
        .executable(name: "KodauIM", targets: ["KodauIM"])
    ],
    targets: [
        .target(
            name: "KodauCore",
            dependencies: [],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "KodauApp",
            dependencies: ["KodauCore"],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "KodauIM",
            dependencies: ["KodauCore"],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Carbon"),
                .linkedFramework("InputMethodKit")
            ]
        ),
        .testTarget(
            name: "KodauCoreTests",
            dependencies: ["KodauCore"]
        )
    ]
)
