// swift-tools-version:5.9
import PackageDescription

// libmtp est fournie par son chemin complet plutôt que par « -lmtp » : son nom
// de fichier (libmtp.9.dylib) ne suit pas la convention attendue par le linker.
// Les rpath permettent de la retrouver à l'exécution, aussi bien dans l'arbre
// de développement qu'une fois le binaire distribué à côté de ses dylibs.
let mtpLinkage: [LinkerSetting] = [
    .unsafeFlags([
        "Vendor/libmtp.9.dylib",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../Vendor",
        // Bundles de test : leur profondeur varie selon que SwiftPM place la
        // sortie dans .build/debug/ ou .build/<triple>/debug/. Les deux
        // variantes sont couvertes, un rpath inutile étant simplement ignoré.
        "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../../Vendor",
        "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../../../Vendor",
    ])
]

let package = Package(
    name: "BrailliantConnect",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "bc", targets: ["bc"]),
        .library(name: "BrailliantKit", targets: ["BrailliantKit"]),
    ],
    targets: [
        .systemLibrary(name: "CMTP", path: "Sources/CMTP"),
        .target(name: "BrailliantKit", dependencies: ["CMTP"]),
        .executableTarget(
            name: "bc",
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
