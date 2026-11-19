// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ScaleNCrop",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "ScaleNCrop", targets: ["ScaleNCrop"]),
    ],
    targets: [
        .target(
            name: "ScaleNCropCore",
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Vision"),
            ]
        ),
        .executableTarget(
            name: "ScaleNCrop",
            dependencies: ["ScaleNCropCore"],
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "ScaleNCropCoreTests",
            dependencies: ["ScaleNCropCore"]
        ),
    ]
)
