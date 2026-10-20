// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TeoStackXt",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TeoStackCore", targets: ["TeoStackCore"]),
        .executable(name: "TeoStackXt", targets: ["TeoStackXt"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Libreria xxHash ufficiale (Cyan4973/xxHash v0.8.3, BSD-2) inclusa in sorgente.
        .target(
            name: "CXXHash",
            path: "Sources/CXXHash",
            exclude: ["LICENSE"],
            cSettings: [.unsafeFlags(["-O3"])]
        ),
        // Solo Linux (test in ambienti senza macOS): completa il SQLite di sistema di Ubuntu. Inattivo su macOS.
        .target(name: "CSQLiteLinuxShim", path: "Sources/CSQLiteLinuxShim"),
        // Logica indipendente dall'interfaccia: hash, offload, verifica (compilabile anche su Linux per i test).
        .target(
            name: "TeoStackCore",
            dependencies: [
                "CXXHash",
                .product(name: "GRDB", package: "GRDB.swift"),
                .target(name: "CSQLiteLinuxShim", condition: .when(platforms: [.linux])),
            ],
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
            path: "Tests/TeoStackCoreTests",
            exclude: ["Fixtures"]
        ),
    ]
)
