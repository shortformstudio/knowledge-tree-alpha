// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KnowledgeCompiler",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "KnowledgeCompiler",
            path: "Sources/KnowledgeCompiler",
            resources: [
                .copy("Resources/trunk.html"),
                .copy("Resources/three.min.js"),
                .copy("Resources/stealth_cli.py"),
            ]
        )
    ]
)
