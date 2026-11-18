// swift-tools-version: 6.0
// The app's recipe: what it's called, which Mac it needs, what code it uses.
import PackageDescription

let package = Package(
    name: "ReadAloud",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Ingredient: FluidAudio, the on-device voice engine.
        // Pinned to an exact commit on its main branch (has the Apple M5 fixes #1137 and #1160).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "16780f04d2ece24f67d0fc00efccd0296491c1a8")
    ],
    targets: [
        // Shared code used by both the app and the probe (text preparation).
        .target(name: "ReadAloudCore", path: "Sources/ReadAloudCore"),
        // The app.
        .executableTarget(
            name: "ReadAloud",
            dependencies: ["ReadAloudCore", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/ReadAloud"
        ),
        // Developer tool for testing how text is split and how joins sound. Not shipped.
        .executableTarget(
            name: "Probe",
            dependencies: ["ReadAloudCore", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Probe"
        ),
        // Developer tool for testing screen reading (OCR) on an image. Not shipped.
        .executableTarget(name: "OCRProbe", dependencies: ["ReadAloudCore"], path: "Sources/OCRProbe"),
    ],
    swiftLanguageModes: [.v5]
)
