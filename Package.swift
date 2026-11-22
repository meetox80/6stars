// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "6stars",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "6stars", targets: ["SixStars"]),
        .executable(name: "rpftool", targets: ["rpftool"]),
    ],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(name: "RPFKit", dependencies: ["CZlib"]),
        .target(name: "CImGui", path: "Sources/CImGui", exclude: ["LICENSE.cimgui", "imgui/LICENSE.txt"],
                cxxSettings: [.define("IMGUI_DISABLE_OBSOLETE_FUNCTIONS")]),
        .executableTarget(name: "rpftool", dependencies: ["RPFKit"]),
        .executableTarget(name: "SixStars", dependencies: ["RPFKit", "CImGui"]),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
