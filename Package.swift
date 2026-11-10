// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FileWheel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "FileWheel", path: "Sources/FileWheel",
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("PDFKit")])
    ]
)
