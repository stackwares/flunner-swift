// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "SimulatorKeyboard",
    platforms: [.macOS("15.0")],
    products: [.library(name: "SimulatorKeyboard", targets: ["SimulatorKeyboard"])],
    targets: [
        .target(name: "CoreDeviceKeyboard", linkerSettings: [.linkedFramework("Foundation")]),
        .target(name: "SimulatorKeyboard", dependencies: ["CoreDeviceKeyboard"],
                resources: [.copy("LICENSE"), .copy("NOTICE")])
    ]
)
