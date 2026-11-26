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
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.5.0"),
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
        .testTarget(
            name: "StreamProtocolTests",
            dependencies: [
                "StreamProtocol",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Tests/StreamProtocolTests"
        ),
    ]
)
