// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Findora",
    defaultLocalization: "de",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FindoraCore", targets: ["FindoraCore"]),
        .executable(name: "Findora", targets: ["FindoraApp"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm",
            exact: "3.31.3"
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift",
            exact: "0.31.3"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers",
            from: "1.3.0"
        )
    ],
    targets: [
        .target(
            name: "FindoraCore",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision")
            ]
        ),
        .target(
            name: "FindoraMLX",
            dependencies: [
                "FindoraCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ]
        ),
        .executableTarget(
            name: "FindoraApp",
            dependencies: ["FindoraCore", "FindoraMLX"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "FindoraCoreTests",
            dependencies: ["FindoraCore", "FindoraMLX"]
        )
    ]
)
