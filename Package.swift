// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TeoStackXt",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TeoStackCore", targets: ["TeoStackCore"]),
        .executable(name: "TeoStackXt", targets: ["TeoStackXt"]),
    ],
    targets: [
        // Libreria xxHash ufficiale (Cyan4973/xxHash v0.8.3, BSD-2) inclusa in sorgente.
        .target(
            name: "CXXHash",
            path: "Sources/CXXHash",
            exclude: ["LICENSE"],
            cSettings: [.unsafeFlags(["-O3"])]
        ),
        // Logica indipendente dall'interfaccia: hash, offload, verifica (compilabile anche su Linux per i test).
        .target(
            name: "TeoStackCore",
            dependencies: ["CXXHash"],
            path: "Sources/TeoStackCore"
        ),
        // App SwiftUI (solo macOS).
        .executableTarget(
            name: "TeoStackXt",
            dependencies: ["TeoStackCore"],
            path: "Sources/TeoStackXt"
        ),
        .testTarget(
            name: "TeoStackCoreTests",
            dependencies: ["TeoStackCore"],
            path: "Tests/TeoStackCoreTests"
        ),
    ]
)
