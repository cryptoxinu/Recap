// swift-tools-version: 6.0
import PackageDescription

// CallBrain core engine as a headless, testable SwiftPM library.
// The macOS SwiftUI app target (signing, entitlements, app bundle) is added in an
// Xcode project later (Phase 1 UI); all logic lives here so it can `swift build` +
// `swift test` from the CLI with no Xcode/UI ceremony.
//
// Platform floor is .macOS(.v14) for the pure-logic core (it uses no macOS-26-only
// APIs). The app target will raise to macOS 26. External deps (GRDB, WhisperKit,
// FluidAudio, swift-embeddings, swift-subprocess, Sparkle) are added per-phase in
// docs/PHASE-PLAN.md so each addition is independently auditable.
let package = Package(
    name: "CallBrain",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CallBrainCore", targets: ["CallBrainCore"]),
        .executable(name: "CallBrainApp", targets: ["CallBrainApp"]),
    ],
    dependencies: [
        // SQLite (WAL + FTS5) source of truth. sqlite-vec/usearch graduate later; the V1 vector
        // lane stores embeddings as BLOBs and does exact brute-force cosine in Swift (docs §0 D5/D6).
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Native Swift ZIP reading for .docx (Google Meet "Notes by Gemini") — replaces the python extract.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "CallBrainCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "CallBrainApp",
            dependencies: ["CallBrainCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "cbseed",   // dev tool: ingest a file into a store path (for populating the app to verify UI)
            dependencies: ["CallBrainCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CallBrainCoreTests",
            dependencies: ["CallBrainCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
