// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Findora",
    defaultLocalization: "de",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PrivateDocSearchCore", targets: ["PrivateDocSearchCore"]),
        .executable(name: "Findora", targets: ["PrivateDocSearchApp"])
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
            name: "PrivateDocSearchCore",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision")
            ]
        ),
        .target(
            name: "PrivateDocSearchMLX",
            dependencies: [
                "PrivateDocSearchCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ]
        ),
        .executableTarget(
            name: "PrivateDocSearchApp",
            dependencies: ["PrivateDocSearchCore", "PrivateDocSearchMLX"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "PrivateDocSearchCoreTests",
            dependencies: ["PrivateDocSearchCore", "PrivateDocSearchMLX"]
        )
    ]
)
