// swift-tools-version: 5.9
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "CFScanner",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .iOSApplication(
            name: "CFScanner",
            targets: ["AppModule"],
            displayVersion: "1.0",
            bundleVersion: "1",
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeLeft,
                .landscapeRight
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "Sources"
        )
    ]
)
