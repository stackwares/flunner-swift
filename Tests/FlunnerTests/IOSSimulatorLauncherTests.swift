import XCTest
@testable import Flunner

final class IOSSimulatorLauncherTests: XCTestCase {
    private let developerDir = "/Applications/Xcode.app/Contents/Developer"

    func testPrefersDeviceHubOnXcode27() {
        let app = IOSSimulatorLauncher.resolve(
            developerDir: developerDir,
            fileExists: { $0 == "/Applications/Xcode.app/Contents/Applications/DeviceHub.app" },
            applicationURL: { _ in nil }
        )
        XCTAssertEqual(app?.url.path, "/Applications/Xcode.app/Contents/Applications/DeviceHub.app")
        XCTAssertEqual(app?.isDeviceHub, true)
        XCTAssertEqual(app?.displayName, "Device Hub")
    }

    func testFallsBackToSimulatorAppOnOlderXcode() {
        let app = IOSSimulatorLauncher.resolve(
            developerDir: developerDir,
            fileExists: { $0 == "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app" },
            applicationURL: { _ in nil }
        )
        XCTAssertEqual(app?.url.path, "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app")
        XCTAssertEqual(app?.isDeviceHub, false)
    }

    func testFallsBackToLaunchServicesLookup() {
        let deviceHub = URL(fileURLWithPath: "/Applications/Xcode-beta.app/Contents/Applications/DeviceHub.app")
        let app = IOSSimulatorLauncher.resolve(
            developerDir: nil,
            fileExists: { _ in false },
            applicationURL: { $0 == IOSSimulatorLauncher.deviceHubBundleID ? deviceHub : nil }
        )
        XCTAssertEqual(app, IOSSimulatorLauncher.App(url: deviceHub, isDeviceHub: true))
    }

    func testReturnsNilWithoutXcode() {
        XCTAssertNil(IOSSimulatorLauncher.resolve(
            developerDir: developerDir,
            fileExists: { _ in false },
            applicationURL: { _ in nil }
        ))
    }

    func testDeveloperDirEnvironmentWins() {
        XCTAssertEqual(
            IOSSimulatorLauncher.activeDeveloperDirectory(environment: ["DEVELOPER_DIR": "/opt/Xcode.app/Contents/Developer"]),
            "/opt/Xcode.app/Contents/Developer"
        )
    }
}
