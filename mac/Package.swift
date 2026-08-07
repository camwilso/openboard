// swift-tools-version: 6.0
import PackageDescription

/*
 SwiftPM rather than an .xcodeproj, deliberately.

 Xcode is not installed on this machine — only the Command Line Tools — so
 `xcodebuild` is unavailable. SwiftUI, AppKit and IOKit all build fine against the
 CLT SDK, and the .app bundle is assembled by tools/build-app.sh, which is the same
 approach the Node version already proved out. A SwiftPM package also opens directly
 in Xcode if it is ever installed, so this costs nothing later.

 The consequence to know about: no asset catalogs (actool is an Xcode tool). The
 keycap artwork is therefore compiled *into* the binary as vector path data rather
 than shipped as image resources — see KeycapCatalog.swift.
 */
let package = Package(
    name: "OpenBoard",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that can be reasoned about without a pad attached: states,
        // eligibility, the board's physical layout, calibration, the keycap catalog.
        // Kept separate so it can be tested — the device layer cannot be.
        .target(name: "OpenBoardKit"),

        .executableTarget(
            name: "OpenBoard",
            dependencies: ["OpenBoardKit"]
        ),

        // A plain executable, not a .testTarget: XCTest ships only with Xcode, and
        // the Command Line Tools' Testing.framework is missing lib_TestingInterop
        // so anything built against swift-testing will not load. Run with:
        //   swift run OpenBoardTests
        // The shim Claude Code hooks actually invoke. Forwards stdin to the app's
        // socket and exits — it must never block or fail a session.
        .executableTarget(
            name: "openboard-hook",
            dependencies: []
        ),

        // Renders the app icon from the keycap catalog. There is no asset catalog
        // here (actool is Xcode-only), so the icon is generated at build time.
        .executableTarget(
            name: "openboard-icon",
            dependencies: ["OpenBoardKit"]
        ),

        // Hardware diagnostic. The IOKit layer cannot be unit-tested, so this is how
        // it gets exercised against a real pad.
        .executableTarget(
            name: "openboard-probe",
            dependencies: ["OpenBoardKit"]
        ),

        .executableTarget(
            name: "OpenBoardTests",
            dependencies: ["OpenBoardKit"]
        ),
    ]
)
