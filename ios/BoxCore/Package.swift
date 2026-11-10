// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BoxCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TorrentKit", targets: ["TorrentKit"]),
        .library(name: "ArchiveKit", targets: ["ArchiveKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/tsolomko/SWCompression.git", from: "4.9.1"),
        .package(url: "https://github.com/mtgto/Unrar.swift.git", from: "0.5.4"),
        // 7-Zip SDK (LZMA/LZMA2/BCJ/AES). Pinned by revision (tag 1.5.0) because it uses unsafeFlags.
        .package(url: "https://github.com/OlehKulykov/PLzmaSDK.git", revision: "d42ec415ffa0fa45bafd09b9e36e7bf8dfc6c136"),
    ],
    targets: [
        .target(
            name: "TorrentKit",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "ArchiveKit",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "SWCompression", package: "SWCompression"),
                .product(name: "Unrar", package: "Unrar.swift"),
                .product(name: "PLzmaSDK", package: "PLzmaSDK"),
            ]
        ),
        // Command-line harness used to exercise the engine outside of iOS (CI / Linux).
        .executableTarget(
            name: "boxcli",
            dependencies: ["TorrentKit", "ArchiveKit"]
        ),
        .testTarget(
            name: "TorrentKitTests",
            dependencies: ["TorrentKit", "ArchiveKit"]
        ),
    ]
)
