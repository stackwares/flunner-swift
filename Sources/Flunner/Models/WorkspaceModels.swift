import Foundation

struct RecentProject: Codable, Hashable, Identifiable {
    var id: String { path }

    let path: String
    let displayName: String
    var lastOpenedAt: Date
    var lastDeviceId: String?
    var lastConfigurationName: String?
    var terminalWorkspace: TerminalWorkspaceSnapshot?

    init(
        path: String,
        displayName: String? = nil,
        lastOpenedAt: Date = .now,
        lastDeviceId: String? = nil,
        lastConfigurationName: String? = nil,
        terminalWorkspace: TerminalWorkspaceSnapshot? = nil
    ) {
        let canonicalPath = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        self.path = canonicalPath
        self.displayName = displayName ?? URL(fileURLWithPath: canonicalPath).lastPathComponent
        self.lastOpenedAt = lastOpenedAt
        self.lastDeviceId = lastDeviceId
        self.lastConfigurationName = lastConfigurationName
        self.terminalWorkspace = terminalWorkspace
    }
}

struct TerminalTabSnapshot: Codable, Hashable, Identifiable {
    let id: UUID
    var title: String

    init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
    }
}

struct TerminalWorkspaceSnapshot: Codable, Hashable {
    static let defaultPaneHeight = 260.0
    static let minimumPaneHeight = 160.0

    var isVisible: Bool
    var paneHeight: Double
    var tabs: [TerminalTabSnapshot]
    var selectedTabID: UUID?

    init(
        isVisible: Bool = false,
        paneHeight: Double = defaultPaneHeight,
        tabs: [TerminalTabSnapshot] = [],
        selectedTabID: UUID? = nil
    ) {
        self.isVisible = isVisible
        self.paneHeight = max(Self.minimumPaneHeight, paneHeight)
        self.tabs = tabs
        self.selectedTabID = tabs.contains(where: { $0.id == selectedTabID })
            ? selectedTabID
            : tabs.first?.id
    }
}

enum RunOutcome: String, Codable, CaseIterable, Hashable {
    case ended
    case stoppedByUser
    case failed
    case interrupted

    var label: String {
        switch self {
        case .ended: "Ended"
        case .stoppedByUser: "Stopped"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        }
    }

    var systemImage: String {
        switch self {
        case .ended: "checkmark.circle.fill"
        case .stoppedByUser: "stop.circle.fill"
        case .failed: "xmark.circle.fill"
        case .interrupted: "exclamationmark.circle.fill"
        }
    }
}

struct LiveRun: Identifiable, Equatable {
    let id: UUID
    let projectPath: String
    let projectName: String
    let deviceId: String
    let deviceName: String
    let configurationName: String
    let startedAt: Date
    var state: AppState
}

enum WorkspaceSelection: Hashable {
    case console
    case project(String)
}

enum WorkspaceValidationError: LocalizedError, Equatable {
    case missingDirectory
    case missingPubspec
    case notFlutterProject
    case unreadableProject

    var errorDescription: String? {
        switch self {
        case .missingDirectory: "The project folder no longer exists."
        case .missingPubspec: "This folder does not contain pubspec.yaml."
        case .notFlutterProject: "The selected folder is not a Flutter or DartNative project."
        case .unreadableProject: "Flunner could not read this project."
        }
    }
}

struct FlutterCLICommandGroup: Identifiable {
    let id = UUID()
    let name: String
    let commands: [FlutterCLICommand]
}

struct FlutterCLICommand: Identifiable {
    let id = UUID()
    let name: String
    let systemImage: String
    let arguments: [String]

    static let groups: [FlutterCLICommandGroup] = [
        FlutterCLICommandGroup(name: "Dependencies", commands: [
            FlutterCLICommand(name: "Pub Get", systemImage: "arrow.down.doc", arguments: ["pub", "get"]),
            FlutterCLICommand(name: "Pub Upgrade", systemImage: "arrow.up.doc", arguments: ["pub", "upgrade"]),
            FlutterCLICommand(name: "Pub Outdated", systemImage: "clock.arrow.circlepath", arguments: ["pub", "outdated"]),
        ]),
        FlutterCLICommandGroup(name: "Tools", commands: [
            FlutterCLICommand(name: "Devices", systemImage: "laptopcomputer.and.iphone", arguments: ["devices"]),
            FlutterCLICommand(name: "Emulators", systemImage: "rectangle.on.rectangle", arguments: ["emulators"]),
            FlutterCLICommand(name: "Logs", systemImage: "text.alignleft", arguments: ["logs"]),
        ]),
        FlutterCLICommandGroup(name: "Analysis & Testing", commands: [
            FlutterCLICommand(name: "Analyze", systemImage: "magnifyingglass.circle", arguments: ["analyze"]),
            FlutterCLICommand(name: "Test", systemImage: "checklist", arguments: ["test"]),
            FlutterCLICommand(name: "Drive", systemImage: "car", arguments: ["drive"]),
        ]),
        FlutterCLICommandGroup(name: "Build", commands: [
            FlutterCLICommand(name: "Build APK", systemImage: "android", arguments: ["build", "apk"]),
            FlutterCLICommand(name: "Build App Bundle", systemImage: "archivebox", arguments: ["build", "appbundle"]),
            FlutterCLICommand(name: "Build IPA", systemImage: "apple.logo", arguments: ["build", "ipa"]),
            FlutterCLICommand(name: "Build Web", systemImage: "globe", arguments: ["build", "web"]),
            FlutterCLICommand(name: "Build macOS", systemImage: "macbook", arguments: ["build", "macos"]),
            FlutterCLICommand(name: "Build Windows", systemImage: "pc", arguments: ["build", "windows"]),
            FlutterCLICommand(name: "Build Linux", systemImage: "terminal", arguments: ["build", "linux"]),
        ]),
        FlutterCLICommandGroup(name: "SDK", commands: [
            FlutterCLICommand(name: "Flutter Upgrade", systemImage: "arrow.triangle.2.circlepath", arguments: ["upgrade"]),
        ]),
    ]

    /// Commands for DartNative projects, sent through `dn`. DartNative targets
    /// iOS and Android only, so web and desktop builds are left out.
    static let dartNativeGroups: [FlutterCLICommandGroup] = [
        FlutterCLICommandGroup(name: "Dependencies", commands: [
            FlutterCLICommand(name: "Pub Get", systemImage: "arrow.down.doc", arguments: ["pub", "get"]),
            FlutterCLICommand(name: "Pub Upgrade", systemImage: "arrow.up.doc", arguments: ["pub", "upgrade"]),
            FlutterCLICommand(name: "Pub Outdated", systemImage: "clock.arrow.circlepath", arguments: ["pub", "outdated"]),
        ]),
        FlutterCLICommandGroup(name: "Tools", commands: [
            FlutterCLICommand(name: "Devices", systemImage: "laptopcomputer.and.iphone", arguments: ["devices"]),
            FlutterCLICommand(name: "Emulators", systemImage: "rectangle.on.rectangle", arguments: ["emulators"]),
            FlutterCLICommand(name: "Logs", systemImage: "text.alignleft", arguments: ["logs"]),
            FlutterCLICommand(name: "Doctor", systemImage: "stethoscope", arguments: ["doctor"]),
        ]),
        FlutterCLICommandGroup(name: "Analysis & Testing", commands: [
            FlutterCLICommand(name: "Analyze", systemImage: "magnifyingglass.circle", arguments: ["analyze"]),
            FlutterCLICommand(name: "Test", systemImage: "checklist", arguments: ["test"]),
        ]),
        FlutterCLICommandGroup(name: "Build", commands: [
            FlutterCLICommand(name: "Build APK", systemImage: "android", arguments: ["build", "apk"]),
            FlutterCLICommand(name: "Build App Bundle", systemImage: "archivebox", arguments: ["build", "appbundle"]),
            FlutterCLICommand(name: "Build IPA", systemImage: "apple.logo", arguments: ["build", "ipa"]),
        ]),
        FlutterCLICommandGroup(name: "SDK", commands: [
            FlutterCLICommand(name: "DartNative Upgrade", systemImage: "arrow.triangle.2.circlepath", arguments: ["upgrade"]),
        ]),
    ]

    static func groups(for toolchain: ProjectToolchain) -> [FlutterCLICommandGroup] {
        switch toolchain {
        case .flutter: Self.groups
        case .dartNative: Self.dartNativeGroups
        }
    }
}
