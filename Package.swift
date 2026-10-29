// swift-tools-version:5.10
// NX Hub: a library and launcher for the Mac apps nxnative builds (github.com/seedds/nxnative).
// Build the app with scripts/build_app.sh; `swift build` alone makes only the executable.
import PackageDescription

let package = Package(
    name: "NXHub",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NXHub",
            path: "Sources/NXHub"
        )
    ]
)
