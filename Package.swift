// swift-tools-version:5.9
import PackageDescription

// libmtp is passed by its full path rather than as "-lmtp": its file name
// (libmtp.9.dylib) does not follow the convention the linker expects. The
// rpaths let it be found at run time, both in the development tree and once
// the binary is distributed beside its dylibs.
//
// Each rpath is a depth, counted from the binary up to the repository root,
// and the depth depends on where SwiftPM puts its output: .build/<config>/,
// .build/<triple>/<config>/, and since Xcode 27 .build/out/Products/<Config>/.
// All of them are listed; an rpath that leads nowhere is simply skipped.
let mtpLinkage: [LinkerSetting] = [
    .unsafeFlags([
        "Vendor/libmtp.9.dylib",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../Vendor",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../Vendor",
        // Test bundles: the binary sits three levels further down, inside
        // <name>.xctest/Contents/MacOS.
        "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../../Vendor",
        "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../../../Vendor",
        "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../../../../Vendor",
    ])
]

let package = Package(
    name: "BrailliantConnect",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "brailliant", targets: ["brailliant"]),
        .library(name: "BrailliantKit", targets: ["BrailliantKit"]),
    ],
    targets: [
        .systemLibrary(name: "CMTP", path: "Sources/CMTP"),
        .target(name: "BrailliantKit", dependencies: ["CMTP"]),
        .executableTarget(
            name: "brailliant",
            dependencies: ["BrailliantKit"],
            linkerSettings: mtpLinkage
        ),
        .testTarget(
            name: "BrailliantKitTests",
            dependencies: ["BrailliantKit"],
            linkerSettings: mtpLinkage
        ),
    ]
)
