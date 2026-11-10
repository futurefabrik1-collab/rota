// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Rota",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Rota", path: "Sources/Rota",
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("PDFKit")])
    ]
)
