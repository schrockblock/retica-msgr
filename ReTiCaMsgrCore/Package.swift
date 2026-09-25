// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReTiCaMsgrCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReTiCaMsgrCore", targets: ["ReTiCaMsgrCore"]),
    ],
    dependencies: [
        .package(path: "../../../pods/ReTiCA"),
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
                .product(name: "ReTiCANode", package: "ReTiCA"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ReTiCaMsgrCoreTests",
            dependencies: [
                "ReTiCaMsgrCore",
                .product(name: "ReTiCAInterfaces", package: "ReTiCA"),
                .product(name: "ReTiCATransport", package: "ReTiCA"),
            ]
        ),
    ]
)
