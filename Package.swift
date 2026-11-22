// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GestureTab",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GestureTab", targets: ["GestureTab"])
    ],
    targets: [
        .executableTarget(
            name: "GestureTab",
            path: "Sources/GestureTab",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreGraphics")
            ]
        )
    ]
)
