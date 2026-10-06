// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lumen",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Lumen", targets: ["Lumen"]),
    ],
    targets: [
        .target(
            name: "CMpv",
            path: "Sources/CMpv",
            cSettings: [.define("GL_SILENCE_DEPRECATION")]
        ),
        .executableTarget(
            name: "Lumen",
            dependencies: ["CMpv"],
            path: "Sources/Lumen",
            resources: [.copy("Resources/official-addons.json")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("OpenGL"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("AVKit"),
                // libmpv is dlopen'ed via @rpath: the app bundle's Frameworks folder first,
                // then an installed Stremio.app (which ships libmpv and its dependencies).
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/Applications/Stremio.app/Contents/MacOS",
                ]),
            ]
        ),
        .testTarget(
            name: "LumenTests",
            dependencies: ["Lumen"],
            path: "Tests/LumenTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
