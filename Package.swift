// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Purgatorio",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "Purgatorio",
            targets: ["Purgatorio"]
        )
    ],
    targets: [
        .target(
            name: "Purgatorio",
            path: "Purgatorio",
            resources: [
                .process("Metal/Shredder.metal")
            ],
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        )
    ]
)
