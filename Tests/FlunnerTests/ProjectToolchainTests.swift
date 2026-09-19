import XCTest
@testable import Flunner

final class ProjectToolchainTests: XCTestCase {
    private let dartNativePubspec = """
    name: dartnative_starter
    environment:
      sdk: '>=3.5.0 <4.0.0'

    dependencies:
      dartnative: ^1.0.0
      dartnative_ios: ^1.0.0
      dartnative_android: ^1.0.0

    dartnative:
      assets:
        - assets/logo.png
    """

    func testFlutterPubspecIsFlutter() {
        XCTAssertEqual(ProjectToolchain.detect(pubspec: "name: demo\nflutter:\n  uses-material-design: true\n"), .flutter)
    }

    func testDartNativeDependencyIsDartNative() {
        XCTAssertEqual(ProjectToolchain.detect(pubspec: dartNativePubspec), .dartNative)
    }

    func testDartNativeWinsOverACopiedFlutterSection() {
        let pubspec = dartNativePubspec + "\nflutter:\n  uses-material-design: true\n"
        XCTAssertEqual(ProjectToolchain.detect(pubspec: pubspec), .dartNative)
    }

    func testCommentedDartNativeDependencyDoesNotCount() {
        let pubspec = "name: demo\ndependencies:\n  # dartnative: ^1.0.0\nflutter:\n"
        XCTAssertEqual(ProjectToolchain.detect(pubspec: pubspec), .flutter)
    }

    func testUnrelatedDartNativePackageNameDoesNotCount() {
        // `dart_native` is an unrelated pub.dev package.
        let pubspec = "name: demo\ndependencies:\n  dart_native: ^0.7.0\nflutter:\n"
        XCTAssertEqual(ProjectToolchain.detect(pubspec: pubspec), .flutter)
    }

    func testMarkerFileMakesProjectDartNative() {
        XCTAssertEqual(ProjectToolchain.detect(pubspec: "name: demo\n", hasDartNativeMarkerFile: true), .dartNative)
    }

    func testPlainDartPackageIsNeither() {
        XCTAssertNil(ProjectToolchain.detect(pubspec: "name: tool\ndependencies:\n  args: ^2.0.0\n"))
    }

    func testExecutables() {
        XCTAssertEqual(ProjectToolchain.flutter.executable, "flutter")
        XCTAssertEqual(ProjectToolchain.dartNative.executable, "dn")
    }

    func testDartNativeCommandsLeaveOutWebAndDesktopBuilds() {
        let names = FlutterCLICommand.groups(for: .dartNative).flatMap(\.commands).map(\.name)
        XCTAssertTrue(names.contains("Pub Get"))
        XCTAssertTrue(names.contains("Build IPA"))
        XCTAssertFalse(names.contains("Build Web"))
        XCTAssertFalse(names.contains("Build macOS"))
        XCTAssertEqual(
            FlutterCLICommand.groups(for: .flutter).flatMap(\.commands).map(\.name),
            FlutterCLICommand.groups.flatMap(\.commands).map(\.name)
        )
    }

    @MainActor
    func testValidationAcceptsDartNativeProject() throws {
        let project = try makeProject(pubspec: dartNativePubspec)
        defer { try? FileManager.default.removeItem(at: project) }

        XCTAssertEqual(try WorkspaceViewModel.validateProject(at: project.path), .dartNative)
        XCTAssertEqual(ProjectToolchain.detect(at: project.path), .dartNative)
    }

    @MainActor
    func testValidationDetectsDartNativeFromLockFile() throws {
        let project = try makeProject(pubspec: "name: demo\n")
        defer { try? FileManager.default.removeItem(at: project) }
        try "".write(to: project.appendingPathComponent("dn_plugins.lock"), atomically: true, encoding: .utf8)

        XCTAssertEqual(try WorkspaceViewModel.validateProject(at: project.path), .dartNative)
    }

    @MainActor
    func testValidationStillRejectsPlainDartPackage() throws {
        let project = try makeProject(pubspec: "name: tool\n")
        defer { try? FileManager.default.removeItem(at: project) }

        XCTAssertThrowsError(try WorkspaceViewModel.validateProject(at: project.path)) { error in
            XCTAssertEqual(error as? WorkspaceValidationError, .notFlutterProject)
        }
    }

    @MainActor
    func testOpeningDartNativeProjectSwitchesCommandsToDn() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlunnerToolchain-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("NativeApp", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try dartNativePubspec.write(to: project.appendingPathComponent("pubspec.yaml"), atomically: true, encoding: .utf8)

        let viewModel = WorkspaceViewModel(
            store: WorkspaceStore(directoryURL: root.appendingPathComponent("Data", isDirectory: true)),
            daemon: FlutterDaemon(),
            startDaemon: false,
            restoreLastProject: false
        )
        try viewModel.openProject(at: project.path)

        XCTAssertEqual(viewModel.projectToolchain, .dartNative)
        XCTAssertEqual(viewModel.toolchain(forProjectAt: viewModel.projectPath ?? ""), .dartNative)
        XCTAssertFalse(viewModel.isWidgetPreviewerAvailable)
        XCTAssertTrue(viewModel.navigationSubtitle.hasPrefix("DartNative · "))
        XCTAssertFalse(viewModel.cliCommandGroups.flatMap(\.commands).contains { $0.name == "Build Web" })
        XCTAssertEqual(viewModel.sdkInfoService.toolchain, .dartNative)
    }

    private func makeProject(pubspec: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlunnerToolchain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try pubspec.write(to: directory.appendingPathComponent("pubspec.yaml"), atomically: true, encoding: .utf8)
        return directory
    }
}
