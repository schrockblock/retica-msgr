// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReTiCaMsgrCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReTiCaMsgrCore", targets: ["ReTiCaMsgrCore"]),
        // What the Notification Service Extension links: no TCA, no SQLite.
        .library(name: "ReTiCaMsgrPushService", targets: ["ReTiCaMsgrPushService"]),
    ],
    dependencies: [
        .package(path: "../../../pods/ReTiCA"),
        .package(path: "../../../pods/ReTiCAPush"),
        // Meshtastic radio support (spec 2026-10-16 §7 lane E): the app builds the session and the
        // scanner. Same checkout ReTiCA's `../MeshtasticKit` resolves to.
        .package(path: "../../../pods/MeshtasticKit"),
        // sharing-grdb was deprecated and replaced by sqlite-data (1.x+).
        // sharing-grdb 0.8.0 (latest) is incompatible with Swift 6.3 due to a
        // ScalarDatabaseFunction.invoke API break in swift-structured-queries 0.22:
        //   - structured-queries <=0.21: old [QueryBinding] API, but Swift 6.3 compat broken
        //   - structured-queries >=0.22: new inout QueryDecoder API, sharing-grdb uses old form
        // sqlite-data 1.x is the official successor that targets structured-queries >=0.34
        // (Swift 6.3 compatible). Product name changed from SharingGRDB to SQLiteData.
        .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "ReTiCaMsgrCore",
            dependencies: [
                "ReTiCaMsgrPushService",
                .product(name: "ReTiCANode", package: "ReTiCA"),
                .product(name: "ReTiCAKeychain", package: "ReTiCA"),
                .product(name: "ReTiCAMeshtasticLive", package: "ReTiCA"),
                .product(name: "MeshtasticKit", package: "MeshtasticKit"),
                .product(name: "ReTiCAPush", package: "ReTiCAPush"),
                .product(name: "ReTiCAPushCore", package: "ReTiCAPush"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            resources: [.process("Resources")]
        ),
        .target(
            name: "ReTiCaMsgrPushService",
            dependencies: [
                .product(name: "ReTiCAPushExtension", package: "ReTiCAPush"),
            ]
        ),
        .testTarget(
            name: "ReTiCaMsgrCoreTests",
            dependencies: [
                "ReTiCaMsgrCore",
                .product(name: "ReTiCAInterfaces", package: "ReTiCA"),
                .product(name: "ReTiCATransport", package: "ReTiCA"),
                .product(name: "ReTiCAKeychain", package: "ReTiCA"),
                .product(name: "ReTiCAPush", package: "ReTiCAPush"),
                .product(name: "ReTiCAPushCore", package: "ReTiCAPush"),
                .product(name: "MeshtasticKit", package: "MeshtasticKit"),
            ]
        ),
    ]
)
