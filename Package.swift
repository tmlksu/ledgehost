// swift-tools-version: 5.9
import PackageDescription

// ledgehost — a Linux host speaking the wire protocol of the upstream
// desktop-streaming client (tag v0.6.2; see Vendor/VENDORED.md).
//
// Layout:
// - Vendor/StreamProtocol: the upstream protocol module, vendored
//   pristine plus a small Linux patch series. RemoteTLS.swift is
//   excluded (Network.framework) and replaced by a NIO module later.
// - Sources/SillLinuxShims: PBKDF2 + CSPRNG shims the vendored code
//   needs on Linux, kept outside the vendored tree.
let package = Package(
    name: "ledgehost",
    products: [
        .library(name: "StreamProtocol", targets: ["StreamProtocol"]),
        .executable(name: "tls-spike", targets: ["tls-spike"]),
        .executable(name: "ledgehostd", targets: ["ledgehostd"]),
        .executable(name: "ledgehost-probe", targets: ["ledgehost-probe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.70.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    ],
    targets: [
        .target(
            name: "SillLinuxShims",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            path: "Sources/SillLinuxShims"
        ),
        .target(
            name: "StreamProtocol",
            dependencies: [
                "SillLinuxShims",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Vendor/StreamProtocol",
            exclude: ["RemoteTLS.swift"]
        ),
        .executableTarget(
            name: "tls-spike",
            dependencies: [
                "StreamProtocol",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOTLS", package: "swift-nio"),
            ],
            path: "Sources/tls-spike"
        ),
        .target(
            name: "LedgehostCore",
            dependencies: [
                "StreamProtocol",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/LedgehostCore"
        ),
        .executableTarget(
            name: "ledgehostd",
            dependencies: [
                "LedgehostCore",
                "StreamProtocol",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOTLS", package: "swift-nio"),
            ],
            path: "Sources/ledgehostd"
        ),
        .executableTarget(
            name: "ledgehost-probe",
            dependencies: [
                "LedgehostCore",
                "StreamProtocol",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOTLS", package: "swift-nio"),
            ],
            path: "Sources/ledgehost-probe"
        ),
        .testTarget(
            name: "StreamProtocolTests",
            dependencies: [
                "StreamProtocol",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Tests/StreamProtocolTests"
        ),
        .testTarget(
            name: "LedgehostCoreTests",
            dependencies: [
                "LedgehostCore",
                "StreamProtocol",
            ],
            path: "Tests/LedgehostCoreTests"
        ),
    ]
)
