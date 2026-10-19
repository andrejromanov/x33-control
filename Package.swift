// swift-tools-version:5.9
// Optional: open in Xcode or build with `swift build` on a toolchain whose
// SwiftPM works. The Makefile builds with plain swiftc and needs only the
// Command Line Tools.
import PackageDescription

let package = Package(
    name: "X33Control",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "X33Control",
            path: "Sources/X33Control",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
    ]
)
