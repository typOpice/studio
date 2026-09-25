// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Studio",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "StudioApp", targets: ["StudioApp"]),
        .executable(name: "StudioClient", targets: ["StudioClient"])
    ],
    targets: [
        // Wren 0.4.0, vendored verbatim under Sources/CWren (MIT) — the secondary language.
        .target(
            name: "CWren",
            path: "Sources/CWren",
            exclude: ["LICENSE-wren.txt", "README-vendored.md"],
            cSettings: [
                .headerSearchPath("."),
                .define("WREN_OPT_META", to: "1"),
                .define("WREN_OPT_RANDOM", to: "1")
            ]
        ),
        // Luau 0.640, vendored verbatim under Sources/CLuau/luau (MIT), plus a small
        // C-linkage shim so Swift can drive it without C++ interop.
        .target(
            name: "CLuau",
            path: "Sources/CLuau",
            exclude: ["LICENSE-luau.txt", "README-vendored.md"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("luau/VM/include"),
                .headerSearchPath("luau/VM/src"),
                .headerSearchPath("luau/Compiler/include"),
                .headerSearchPath("luau/Compiler/src"),
                .headerSearchPath("luau/Ast/include"),
                .headerSearchPath("luau/Common/include"),
                .unsafeFlags(["-std=c++17"])
            ]
        ),
        // Jolt Physics 5.6.0, vendored verbatim under Sources/CJolt/Jolt (MIT), plus a
        // C-linkage shim. CPU rigid bodies only: the GPU compute backends are left out.
        .target(
            name: "CJolt",
            path: "Sources/CJolt",
            exclude: [
                "LICENSE-jolt.txt", "README-vendored.md",
                "Jolt/Jolt.cmake", "Jolt/Jolt.natvis", "Jolt/Shaders",
                "Jolt/Compute/MTL", "Jolt/Compute/VK", "Jolt/Compute/DX12",
                "Jolt/Physics/Collision/Shape/TaperedCapsuleShape.gliffy"
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("."),
                .unsafeFlags(["-std=c++17", "-O2", "-Wno-everything"])
            ]
        ),
        // Everything shared by the editor and the play client: model, renderer,
        // physics and both UIs. The executables are thin entry points.
        .target(
            name: "StudioKit",
            dependencies: ["CLuau", "CWren", "CJolt"],
            path: "Sources/StudioKit",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        ),
        .executableTarget(
            name: "StudioApp",
            dependencies: ["StudioKit"],
            path: "Sources/StudioApp",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        ),
        .executableTarget(
            name: "StudioClient",
            dependencies: ["StudioKit"],
            path: "Sources/StudioClient",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        )
    ]
)
