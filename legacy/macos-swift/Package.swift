// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OllamaGUI",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OllamaGUI", targets: ["OllamaGUI"]),
        .library(name: "OllamaKit", targets: ["OllamaKit"]),
    ],
    targets: [
        // Networking layer: Ollama REST API, registry update checks and the ollama.com library.
        .target(name: "OllamaKit"),
        // The SwiftUI macOS app.
        .executableTarget(name: "OllamaGUI", dependencies: ["OllamaKit"]),
        .testTarget(name: "OllamaKitTests", dependencies: ["OllamaKit"]),
    ]
)
