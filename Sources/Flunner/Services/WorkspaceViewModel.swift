import AppKit
import Combine
import Foundation

@MainActor
final class WorkspaceViewModel: ObservableObject {
    static let maximumLogEntries = 10_000

    @Published private(set) var projectPath: String?
    @Published private(set) var projectName = "No Project"
    /// Toolchain of the open project: Flutter, or DartNative (driven through `dn`).
    @Published private(set) var projectToolchain: ProjectToolchain = .flutter
    /// Detected toolchain per recent project, for sidebar badges.
    @Published private(set) var projectToolchains: [String: ProjectToolchain] = [:]
    @Published private(set) var devices: [Device] = []
    @Published private(set) var emulators: [Device] = []
    @Published private(set) var launchConfigs: [LaunchConfig] = []
    @Published var selectedDeviceId: String?
    @Published var selectedLaunchConfigName: String?
    @Published private(set) var appState: AppState = .idle
    @Published private(set) var status = "Preparing Flutter tools…"
    @Published private(set) var logLines: [LogEntry] = []
    @Published private(set) var recentProjects: [RecentProject] = []
    @Published private(set) var liveRuns: [LiveRun] = []
    @Published private(set) var selectedLiveRunID: UUID?
    @Published private(set) var projectIcons: [String: NSImage] = [:]
    @Published var selection: WorkspaceSelection = .console
    @Published private(set) var selectedLogChannel: LogChannel = .console
    @Published private var searchTextByChannel: [LogChannel: String] = [
        .console: "",
        .output: "",
    ]
    @Published private var enabledLogTypesByChannel: [LogChannel: Set<LogEntryType>] = [
        .console: Set(LogEntryType.allCases),
        .output: Set(LogEntryType.allCases),
    ]
    @Published private(set) var isFlutterConsoleFilterEnabled = false
    @Published var isCleanConfirmationPresented = false
    @Published var lastValidationError: WorkspaceValidationError?
    @Published private(set) var isProjectMaintenanceRunning = false
    @Published private(set) var activeMaintenanceProjectPath: String?
    @Published private(set) var debugVmServiceUri: String?

    let terminalWorkspaces: TerminalWorkspaceManager
    let sdkInfoService = FlutterSDKInfoService()

    private let daemon: FlutterDaemon
    private let store: WorkspaceStore
    private let projectMaintenance: FlutterProjectMaintaining
    private let runnerFactory: @MainActor (String, String) -> FlutterRunner
    private var snapshot: WorkspaceSnapshot
    private var runnersByRunID: [UUID: FlutterRunner] = [:]
    private var runnerCancellablesByRunID: [UUID: Set<AnyCancellable>] = [:]
    private var projectStatuses: [String: String] = [:]
    private var runStatuses: [UUID: String] = [:]
    private var debugURIsByRunID: [UUID: String] = [:]
    private var daemonCancellables = Set<AnyCancellable>()
    private var logsByBuffer: [LogBufferKey: [LogEntry]] = [:]
    private var rolledOverLogKeys: Set<LogBufferKey> = []
    private var hasStartedSDKInfo = false

    private static let unscopedLogKey = "__flugger_unscoped__"
    private static let unscopedDeviceKey = "__flugger_unscoped_device__"

    private struct LogBufferKey: Hashable {
        let projectKey: String
        let channel: LogChannel
        let deviceId: String
    }

    init(
        store: WorkspaceStore = WorkspaceStore(),
        daemon: FlutterDaemon? = nil,
        projectMaintenance: FlutterProjectMaintaining? = nil,
        startDaemon: Bool = true,
        restoreLastProject: Bool = true,
        runnerFactory: @escaping @MainActor (String, String) -> FlutterRunner = { projectPath, deviceId in
            FlutterRunner(projectPath: projectPath, deviceId: deviceId)
        }
    ) {
        self.store = store
        self.daemon = daemon ?? FlutterDaemon()
        self.projectMaintenance = projectMaintenance ?? FlutterProjectMaintenanceService()
        self.runnerFactory = runnerFactory
        snapshot = (try? store.load()) ?? WorkspaceSnapshot()
        terminalWorkspaces = TerminalWorkspaceManager(projects: snapshot.recentProjects)
        recentProjects = snapshot.recentProjects
        preloadIcons(for: recentProjects)

        terminalWorkspaces.onSnapshotChange = { [weak self] projectPath, terminalSnapshot in
            self?.persistTerminalWorkspace(terminalSnapshot, for: projectPath)
        }

        bindDaemon()
        if restoreLastProject {
            migrateLegacyPreferences()

            if let savedPath = UserDefaultsStore.shared.lastProjectPath {
                try? openProject(at: savedPath, updateSelection: true, promoteInRecents: false)
            }
            if projectPath == nil {
                for project in recentProjects where FileManager.default.fileExists(atPath: project.path) {
                    do {
                        try openProject(at: project.path, updateSelection: true, promoteInRecents: false)
                        break
                    } catch {
                        continue
                    }
                }
            }
        }

        if startDaemon {
            self.daemon.start()
        } else {
            status = "Ready"
        }

        sdkInfoService.prepare(for: projectToolchain)
        hasStartedSDKInfo = true
        Task { await sdkInfoService.refresh() }
    }

    var selectedLiveRun: LiveRun? {
        guard let id = selectedLiveRunID else { return nil }
        return liveRuns.first { $0.id == id }
    }

    var liveRunForSelectedDevice: LiveRun? {
        guard let projectPath, let selectedDeviceId else { return nil }
        return liveRuns.first { $0.projectPath == projectPath && $0.deviceId == selectedDeviceId }
    }

    var currentProjectLiveRuns: [LiveRun] {
        guard let projectPath else { return [] }
        return liveRuns.filter { $0.projectPath == projectPath }
    }

    var isAppRunning: Bool {
        currentProjectLiveRuns.contains { $0.state.isRunning }
    }

    var canControl: Bool {
        selectedLiveRun?.state.canControl == true
    }

    var canStopSelectedRun: Bool {
        guard let run = selectedLiveRun else { return false }
        return run.state == .running || run.state == .starting
    }

    var canControlSelectedRun: Bool {
        selectedLiveRun?.state.canControl == true
    }

    var canRun: Bool {
        projectPath != nil
            && selectedDeviceId != nil
            && !isProjectMaintenanceRunning
            && liveRunForSelectedDevice == nil
    }
    var canPubGet: Bool {
        projectPath != nil && !isProjectMaintenanceRunning
    }

    var canCleanAndPubGet: Bool {
        projectPath != nil && !isAppRunning && !isProjectMaintenanceRunning
    }

    var canMaintainProject: Bool { canCleanAndPubGet }
    var isDaemonRunning: Bool { daemon.isRunning }
    var daemonState: DaemonState { daemon.state }
    var runningEmulatorIds: Set<String> { daemon.runningEmulatorIds }
    var iosEmulators: [Device] { emulators.filter { $0.platform.lowercased().contains("ios") } }
    var androidEmulators: [Device] { emulators.filter { $0.platform.lowercased().contains("android") } }
    var runningEmulators: [Device] { emulators.filter { isEmulatorRunning($0) } }
    var hasRunningProjects: Bool { liveRuns.contains { $0.state.isRunning } }
    var isTerminalAvailable: Bool {
        projectPath != nil
    }
    var isDevToolsAvailable: Bool { debugVmServiceUri != nil }
    var isWidgetPreviewerAvailable: Bool { projectPath != nil && projectToolchain.supportsWidgetPreviewer }
    var cliCommandGroups: [FlutterCLICommandGroup] { FlutterCLICommand.groups(for: projectToolchain) }
    var navigationSubtitle: String {
        guard let projectPath else { return "" }
        let path = projectPath.abbreviatingWithTildeInPath
        return projectToolchain == .dartNative ? "\(projectToolchain.displayName) · \(path)" : path
    }

    func toolchain(forProjectAt path: String) -> ProjectToolchain? {
        projectToolchains[path]
    }

    func liveRun(forDeviceId deviceId: String) -> LiveRun? {
        guard let projectPath else { return nil }
        return liveRuns.first { $0.projectPath == projectPath && $0.deviceId == deviceId }
    }

    func liveRuns(for projectPath: String) -> [LiveRun] {
        liveRuns.filter { $0.projectPath == projectPath }
    }

    func runState(for projectPath: String) -> AppState {
        guard let run = liveRuns.first(where: { $0.projectPath == projectPath }) else { return .idle }
        return run.state
    }

    func isProjectRunning(_ projectPath: String) -> Bool {
        liveRuns(for: projectPath).contains { $0.state.isRunning }
    }

    func selectLiveRun(_ id: UUID) {
        guard let run = liveRuns.first(where: { $0.id == id }) else { return }
        if run.projectPath != projectPath {
            selectWorkspace(.project(run.projectPath))
        }
        selectedDeviceId = run.deviceId
        UserDefaultsStore.shared.lastDeviceId = run.deviceId
        if let matching = launchConfigs.first(where: {
            $0.displayName == run.configurationName || $0.name == run.configurationName
        }) {
            selectedLaunchConfigName = matching.name
            UserDefaultsStore.shared.lastLaunchConfigName = matching.name
        }
        selectedLiveRunID = run.id
        updateCurrentProjectPreferences()
        refreshVisibleLogs()
        syncDerivedRunState()
    }

    var selectedDevice: Device? {
        devices.first { $0.id == selectedDeviceId }
    }

    var selectedLaunchConfig: LaunchConfig? {
        launchConfigs.first { $0.name == selectedLaunchConfigName }
    }

    var searchText: String {
        get { searchTextByChannel[selectedLogChannel] ?? "" }
        set { searchTextByChannel[selectedLogChannel] = newValue }
    }

    var enabledLogTypes: Set<LogEntryType> {
        enabledLogTypesByChannel[selectedLogChannel] ?? Set(LogEntryType.allCases)
    }

    var filteredLogs: [LogEntry] {
        ConsoleLogTools.filter(
            logLines,
            query: searchText,
            enabledTypes: enabledLogTypes,
            requiresFlutterTag: selectedLogChannel == .console && isFlutterConsoleFilterEnabled
        )
    }

    var isCurrentProjectMaintenanceRunning: Bool {
        isProjectMaintenanceRunning && activeMaintenanceProjectPath == projectPath
    }

    var runBlockReason: String? {
        if projectPath == nil { return "Choose a Flutter or DartNative project first." }
        if isProjectMaintenanceRunning { return "Project maintenance is in progress." }
        if selectedDeviceId == nil { return "Choose a connected device first." }
        if liveRunForSelectedDevice != nil { return "This device already has a running session." }
        return nil
    }

    var pubGetBlockReason: String? {
        if projectPath == nil { return "Choose a Flutter or DartNative project first." }
        if isProjectMaintenanceRunning { return "Project maintenance is already in progress." }
        return nil
    }

    var cleanAndPubGetBlockReason: String? {
        if projectPath == nil { return "Choose a Flutter or DartNative project first." }
        if isAppRunning { return "Stop all running sessions before cleaning." }
        if isProjectMaintenanceRunning { return "Project maintenance is already in progress." }
        return nil
    }

    var projectMaintenanceBlockReason: String? { cleanAndPubGetBlockReason }

    func selectWorkspace(_ newSelection: WorkspaceSelection) {
        selection = newSelection
        guard case let .project(path) = newSelection, path != projectPath else { return }
        do {
            try openProject(at: path, updateSelection: false, promoteInRecents: false)
        } catch {
            status = error.localizedDescription
            addLog(error.localizedDescription, type: .error)
        }
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose a Flutter or DartNative project folder"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                do {
                    try self?.openProject(at: url.path, updateSelection: true)
                } catch {
                    self?.status = error.localizedDescription
                    self?.addLog(error.localizedDescription, type: .error)
                }
            }
        }
    }

    func openProject(
        at rawPath: String,
        updateSelection: Bool = true,
        promoteInRecents: Bool = true
    ) throws {
        let path = URL(fileURLWithPath: rawPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let toolchain: ProjectToolchain
        do {
            toolchain = try Self.validateProject(at: path)
        } catch let error as WorkspaceValidationError {
            lastValidationError = error
            throw error
        }
        lastValidationError = nil

        let name = URL(fileURLWithPath: path).lastPathComponent
        let parsedConfigs = LaunchConfig.parse(from: path)
        let configs = parsedConfigs.isEmpty ? LaunchConfig.defaultConfigs() : parsedConfigs
        let existing = recentProjects.first { $0.path == path }

        projectPath = path
        projectName = name
        projectToolchain = toolchain
        projectToolchains[path] = toolchain
        launchConfigs = configs
        if hasStartedSDKInfo, sdkInfoService.toolchain != toolchain {
            sdkInfoService.prepare(for: toolchain)
            Task { await sdkInfoService.refresh() }
        }

        let preferredConfig = existing?.lastConfigurationName ?? UserDefaultsStore.shared.lastLaunchConfigName
        selectedLaunchConfigName = preferredConfig.flatMap { preferred in
            configs.contains { $0.name == preferred } ? preferred : nil
        } ?? configs.first?.name

        let preferredDevice = existing?.lastDeviceId ?? UserDefaultsStore.shared.lastDeviceId
        selectedDeviceId = preferredDevice.flatMap { preferred in
            devices.contains { $0.id == preferred } ? preferred : nil
        }

        UserDefaultsStore.shared.lastProjectPath = path
        UserDefaultsStore.shared.lastLaunchConfigName = selectedLaunchConfigName

        var project = RecentProject(
            path: path,
            displayName: name,
            lastOpenedAt: promoteInRecents ? .now : (existing?.lastOpenedAt ?? .now),
            lastDeviceId: selectedDeviceId,
            lastConfigurationName: selectedLaunchConfigName,
            terminalWorkspace: existing?.terminalWorkspace
        )
        if let existing {
            project.lastDeviceId = existing.lastDeviceId
            project.lastConfigurationName = selectedLaunchConfigName ?? existing.lastConfigurationName
        }
        try persistProject(project, promote: promoteInRecents)

        if updateSelection { selection = .project(path) }
        bindSelectedDeviceSession(fallbackStatus: projectStatuses[path] ?? "Ready to run \(name)")
        terminalWorkspaces.activateProject(path)
        let consoleKey = LogBufferKey(
            projectKey: path,
            channel: .console,
            deviceId: activeDeviceLogKey
        )
        if logsByBuffer[consoleKey]?.isEmpty ?? true {
            let kind = toolchain == .dartNative ? " (DartNative, using dn)" : ""
            addLog("Project: \(name)\(kind)", type: .command, projectPath: path)
        }

        refreshEmulators()

        if projectIcons[path] == nil {
            projectIcons[path] = FlutterAppIconService.extractIcon(from: path)
        }
    }

    func selectDevice(_ id: String?) {
        selectedDeviceId = id
        UserDefaultsStore.shared.lastDeviceId = id
        updateCurrentProjectPreferences()
        bindSelectedDeviceSession()
    }

    func selectConfiguration(_ name: String?) {
        selectedLaunchConfigName = name
        UserDefaultsStore.shared.lastLaunchConfigName = name
        updateCurrentProjectPreferences()
    }

    func removeRecentProject(_ project: RecentProject) {
        guard !isProjectRunning(project.path) else {
            status = "Stop \(project.displayName) before removing it from recents."
            return
        }
        do {
            try store.removeProject(path: project.path, from: &snapshot)
            recentProjects = snapshot.recentProjects
            terminalWorkspaces.removeProject(project.path)
            if selection == .project(project.path) { selection = .console }
        } catch {
            status = "Could not update recent projects: \(error.localizedDescription)"
        }
    }

    func clearRecentProjects() {
        guard !hasRunningProjects else {
            status = "Stop running projects before clearing recents."
            return
        }
        snapshot.recentProjects.removeAll()
        do {
            try store.save(snapshot)
            recentProjects = []
            terminalWorkspaces.retainProjects([])
            if case .project = selection { selection = .console }
        } catch {
            status = "Could not clear recent projects: \(error.localizedDescription)"
        }
    }

    func revealProject(_ project: RecentProject) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
    }

    func runApp() {
        guard canRun, let projectPath, let device = selectedDevice else { return }

        clearDeviceLogs(for: projectPath, deviceId: device.id)
        showLiveLogs(.console, for: projectPath)

        let configName = selectedLaunchConfig?.displayName ?? "Debug"
        let runID = UUID()
        let deviceId = device.id
        let liveRun = LiveRun(
            id: runID,
            projectPath: projectPath,
            projectName: projectName,
            deviceId: deviceId,
            deviceName: device.displayName,
            configurationName: configName,
            startedAt: .now,
            state: .idle
        )
        liveRuns.append(liveRun)
        selectedLiveRunID = runID

        let newRunner = runnerFactory(projectPath, deviceId)
        newRunner.toolchain = projectToolchain
        newRunner.onLogOutput = { [weak self] message, type in
            self?.addLog(message, type: type, projectPath: projectPath, deviceId: deviceId)
        }
        newRunner.onCompletion = { [weak self] outcome in
            self?.finalizeLiveRun(id: runID, outcome: outcome)
        }
        newRunner.onDebugServiceReady = { [weak self] uri in
            self?.debugURIsByRunID[runID] = uri
            self?.syncDerivedRunState()
        }
        newRunner.onDebugServiceLost = { [weak self] in
            self?.debugURIsByRunID[runID] = nil
            self?.syncDerivedRunState()
        }

        var cancellables = Set<AnyCancellable>()
        newRunner.$appState
            .sink { [weak self, weak newRunner] state in
                guard let self, let newRunner, self.runnersByRunID[runID] === newRunner else { return }
                self.updateLiveRunState(state, for: runID)
            }
            .store(in: &cancellables)
        newRunner.$status
            .sink { [weak self, weak newRunner] status in
                guard let self, let newRunner, self.runnersByRunID[runID] === newRunner else { return }
                self.runStatuses[runID] = status
                if self.selectedLiveRunID == runID { self.status = status }
            }
            .store(in: &cancellables)

        runnersByRunID[runID] = newRunner
        runnerCancellablesByRunID[runID] = cancellables
        selection = .project(projectPath)
        syncDerivedRunState()
        newRunner.start(with: selectedLaunchConfig)
    }

    func stopApp() {
        guard let run = selectedLiveRun,
              let runner = runnersByRunID[run.id] else { return }
        runner.stop()
    }

    func hotReload() {
        guard let run = selectedLiveRun,
              let projectPath,
              let runner = runnersByRunID[run.id] else { return }
        showLiveLogs(.console, for: projectPath)
        runner.hotReload()
    }

    func hotRestart() {
        guard let run = selectedLiveRun,
              let projectPath,
              let runner = runnersByRunID[run.id] else { return }
        clearDeviceLogs(for: projectPath, deviceId: run.deviceId)
        showLiveLogs(.console, for: projectPath)
        runner.hotRestart()
    }

    func requestCleanAndPubGet() {
        guard canCleanAndPubGet else { return }
        isCleanConfirmationPresented = true
    }

    func pubGet() {
        performProjectMaintenance(.pubGet)
    }

    func cleanAndPubGet() {
        isCleanConfirmationPresented = false
        performProjectMaintenance(.cleanAndPubGet)
    }

    func selectLogChannel(_ channel: LogChannel) {
        guard selectedLogChannel != channel else { return }
        selectedLogChannel = channel
        refreshVisibleLogs()
    }

    func clearLogs() {
        let key = activeLogBufferKey
        logsByBuffer[key] = []
        rolledOverLogKeys.remove(key)
        logLines = []
        let message = "\(selectedLogChannel.label) cleared"
        if let projectPath {
            updateStatus(message, for: projectPath)
        } else {
            status = message
        }
    }

    func toggleFilter(_ type: LogEntryType) {
        var enabledTypes = enabledLogTypes
        if enabledTypes.contains(type) {
            enabledTypes.remove(type)
        } else {
            enabledTypes.insert(type)
        }
        enabledLogTypesByChannel[selectedLogChannel] = enabledTypes
    }

    func toggleFlutterConsoleFilter() {
        isFlutterConsoleFilterEnabled.toggle()
    }

    func copyVisibleLogs() {
        let text = ConsoleLogTools.exportText(filteredLogs)
        guard !text.isEmpty else {
            status = "There is no visible output to copy."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Copied \(filteredLogs.count) \(selectedLogChannel.label.lowercased()) lines"
    }

    func exportVisibleLogs() {
        let entries = filteredLogs
        guard !entries.isEmpty else {
            status = "There is no visible output to export."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(projectName)-\(selectedLogChannel.rawValue).log"
        panel.prompt = "Export"
        let channelName = selectedLogChannel.label.lowercased()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let text = ConsoleLogTools.exportText(entries)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                Task { @MainActor in self?.status = "Exported \(entries.count) \(channelName) lines" }
            } catch {
                Task { @MainActor in self?.status = "Export failed: \(error.localizedDescription)" }
            }
        }
    }

    func reloadLaunchConfigs() {
        guard let projectPath else { return }
        let parsed = LaunchConfig.parse(from: projectPath)
        launchConfigs = parsed.isEmpty ? LaunchConfig.defaultConfigs() : parsed
        if let selected = selectedLaunchConfigName, !launchConfigs.contains(where: { $0.name == selected }) {
            selectedLaunchConfigName = launchConfigs.first?.name
        } else if selectedLaunchConfigName == nil {
            selectedLaunchConfigName = launchConfigs.first?.name
        }
    }

    func refreshDevices() { daemon.refreshDevices() }

    func isEmulatorRunning(_ device: Device) -> Bool {
        runningEmulatorIds.contains(device.id)
    }

    func launchEmulator(_ device: Device) {
        daemon.launchEmulator(device.emulatorId ?? device.id)
    }

    func killEmulator(_ device: Device) {
        guard isEmulatorRunning(device) else { return }
        daemon.killEmulator(device)
    }

    func killAllEmulators() {
        for device in runningEmulators {
            daemon.killEmulator(device)
        }
    }

    func refreshEmulators() { daemon.getEmulators() }

    func openDevTools() {
        guard let uri = debugVmServiceUri else { return }
        DevToolsLauncher.open(vmServiceUri: uri) { [weak self] message in
            self?.addLog(message, type: .info)
        }
    }

    func openDevTools(page: DevToolsPage) {
        guard let uri = debugVmServiceUri else { return }
        DevToolsLauncher.open(page: page, vmServiceUri: uri) { [weak self] message in
            self?.addLog(message, type: .info)
        }
    }

    func openWidgetPreviewer() {
        guard let projectPath else { return }
        WidgetPreviewerLauncher.open(projectPath: projectPath) { [weak self] message, type in
            self?.addLog(message, type: type)
        }
    }

    func runFlutterCommand(_ command: FlutterCLICommand) {
        guard let projectPath else { return }
        terminalWorkspaces.sendToActiveSession(
            command,
            in: projectPath,
            executable: projectToolchain.executable
        )
    }

    func openLink(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Opens Device Hub on Xcode 27+ (which replaced Simulator.app), or
    /// Simulator.app on older Xcode versions.
    func openiOSSimulator() {
        IOSSimulatorLauncher.open { [weak self] message, type in
            self?.addLog(message, type: type)
        }
    }

    func restartDaemon() { daemon.restart() }

    func toggleTerminal() {
        guard isTerminalAvailable, let projectPath else { return }
        terminalWorkspaces.toggle(for: projectPath)
    }

    func clearValidationError() {
        lastValidationError = nil
    }

    func retryDaemon() {
        status = "Restarting Flutter tools…"
        daemon.restart()
    }

    /// Validates a project folder and returns its toolchain (Flutter or DartNative).
    @discardableResult
    static func validateProject(at path: String, fileManager: FileManager = .default) throws -> ProjectToolchain {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceValidationError.missingDirectory
        }

        let pubspecPath = URL(fileURLWithPath: path).appendingPathComponent("pubspec.yaml").path
        guard fileManager.fileExists(atPath: pubspecPath) else {
            throw WorkspaceValidationError.missingPubspec
        }
        guard let contents = try? String(contentsOfFile: pubspecPath, encoding: .utf8) else {
            throw WorkspaceValidationError.unreadableProject
        }
        let hasDartNativeMarker = ProjectToolchain.dartNativeMarkerFiles.contains {
            fileManager.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent($0).path)
        }
        guard let toolchain = ProjectToolchain.detect(
            pubspec: contents,
            hasDartNativeMarkerFile: hasDartNativeMarker
        ) else {
            throw WorkspaceValidationError.notFlutterProject
        }
        return toolchain
    }

    private func bindDaemon() {
        daemon.$devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                guard let self else { return }
                self.devices = devices.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                if let selectedDeviceId = self.selectedDeviceId,
                   !devices.contains(where: { $0.id == selectedDeviceId }) {
                    self.selectedDeviceId = nil
                    self.bindSelectedDeviceSession()
                    self.status = "The selected device disconnected."
                } else if self.selectedDeviceId == nil,
                          let saved = UserDefaultsStore.shared.lastDeviceId,
                          devices.contains(where: { $0.id == saved }) {
                    self.selectedDeviceId = saved
                    self.bindSelectedDeviceSession()
                }
            }
            .store(in: &daemonCancellables)

        daemon.$emulators
            .receive(on: DispatchQueue.main)
            .sink { [weak self] emulators in
                self?.emulators = emulators.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            }
            .store(in: &daemonCancellables)

        daemon.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] daemonStatus in
                guard let self, !self.isAppRunning, !self.isProjectMaintenanceRunning else { return }
                self.status = daemonStatus
            }
            .store(in: &daemonCancellables)

        daemon.onLogOutput = { [weak self] message, type in
            self?.addLog(message, type: type)
        }
    }

    private func migrateLegacyPreferences() {
        guard recentProjects.isEmpty,
              let path = UserDefaultsStore.shared.lastProjectPath,
              FileManager.default.fileExists(atPath: path) else { return }
        let project = RecentProject(
            path: path,
            lastDeviceId: UserDefaultsStore.shared.lastDeviceId,
            lastConfigurationName: UserDefaultsStore.shared.lastLaunchConfigName
        )
        try? persistProject(project)
    }

    private func preloadIcons(for projects: [RecentProject]) {
        for project in projects where projectIcons[project.path] == nil {
            projectIcons[project.path] = FlutterAppIconService.extractIcon(from: project.path)
        }
        for project in projects where projectToolchains[project.path] == nil {
            if let toolchain = ProjectToolchain.detect(at: project.path) {
                projectToolchains[project.path] = toolchain
            }
        }
    }

    private func persistProject(_ project: RecentProject, promote: Bool = true) throws {
        if promote {
            _ = try store.upsert(project, in: &snapshot)
        } else {
            try store.updateProject(project, in: &snapshot)
        }
        recentProjects = snapshot.recentProjects
        terminalWorkspaces.retainProjects(Set(recentProjects.map(\.path)))
        preloadIcons(for: recentProjects)
    }

    private func persistTerminalWorkspace(
        _ terminalSnapshot: TerminalWorkspaceSnapshot,
        for projectPath: String
    ) {
        guard let index = snapshot.recentProjects.firstIndex(where: { $0.path == projectPath }) else { return }
        snapshot.recentProjects[index].terminalWorkspace = terminalSnapshot
        do {
            try store.updateProject(snapshot.recentProjects[index], in: &snapshot)
            recentProjects = snapshot.recentProjects
        } catch {
            status = "Could not save terminal layout: \(error.localizedDescription)"
        }
    }

    private func updateCurrentProjectPreferences() {
        guard let projectPath,
              var project = recentProjects.first(where: { $0.path == projectPath }) else { return }
        project.lastDeviceId = selectedDeviceId
        project.lastConfigurationName = selectedLaunchConfigName
        try? persistProject(project, promote: false)
    }

    private func finalizeLiveRun(id: UUID, outcome _: RunOutcome) {
        guard let index = liveRuns.firstIndex(where: { $0.id == id }) else { return }
        liveRuns.remove(at: index)
        runnersByRunID[id] = nil
        runnerCancellablesByRunID[id] = nil
        runStatuses[id] = nil
        debugURIsByRunID[id] = nil

        if selectedLiveRunID == id {
            selectedLiveRunID = nil
        }

        syncDerivedRunState()
    }

    private func updateLiveRunState(_ state: AppState, for id: UUID) {
        guard let index = liveRuns.firstIndex(where: { $0.id == id }) else { return }
        liveRuns[index].state = state
        if selectedLiveRunID == id {
            appState = state
            if state == .idle {
                status = "Ready to run \(projectName)"
            } else {
                status = runStatuses[id] ?? status
            }
        }
    }

    private func syncDerivedRunState(fallbackStatus: String? = nil) {
        guard let run = selectedLiveRun else {
            appState = .idle
            debugVmServiceUri = nil
            if let fallbackStatus {
                status = fallbackStatus
            } else if let projectPath {
                status = projectStatuses[projectPath] ?? "Ready to run \(projectName)"
            } else {
                status = "Ready"
            }
            return
        }

        appState = run.state
        status = runStatuses[run.id] ?? (run.state == .idle ? "Ready to run \(run.projectName)" : "Preparing run…")
        debugVmServiceUri = debugURIsByRunID[run.id]
    }

    private func performProjectMaintenance(_ operation: FlutterProjectMaintenanceOperation) {
        let canPerform = operation == .pubGet ? canPubGet : canCleanAndPubGet
        guard let projectPath, canPerform else {
            let reason = operation == .pubGet ? pubGetBlockReason : cleanAndPubGetBlockReason
            if let reason { status = reason }
            return
        }

        showLiveLogs(.output, for: projectPath)
        isProjectMaintenanceRunning = true
        activeMaintenanceProjectPath = projectPath
        updateStatus("Running \(operation.displayName)…", for: projectPath)
        let startedAt = Date.now.formatted(date: .abbreviated, time: .standard)
        let maintenanceDeviceId = selectedDeviceId ?? Self.unscopedDeviceKey
        addLog(
            "\(operation.displayName) — \(projectName) — \(startedAt)",
            type: .command,
            projectPath: projectPath,
            channel: .output,
            deviceId: maintenanceDeviceId
        )
        let started = projectMaintenance.run(
            operation,
            projectPath: projectPath,
            onOutput: { [weak self] message, type in
                self?.addLog(
                    message,
                    type: type,
                    projectPath: projectPath,
                    channel: .output,
                    deviceId: maintenanceDeviceId
                )
            },
            completion: { [weak self] outcome in
                guard let self else { return }
                self.isProjectMaintenanceRunning = false
                self.activeMaintenanceProjectPath = nil
                switch outcome {
                case .succeeded:
                    self.updateStatus("\(operation.displayName) completed", for: projectPath)
                    self.addLog(
                        "\(operation.displayName) completed",
                        type: .info,
                        projectPath: projectPath,
                        channel: .output,
                        deviceId: maintenanceDeviceId
                    )
                case let .failed(command, exitCode):
                    self.updateStatus("\(operation.displayName) failed", for: projectPath)
                    self.addLog(
                        "\(command) exited with code \(exitCode)",
                        type: .error,
                        projectPath: projectPath,
                        channel: .output,
                        deviceId: maintenanceDeviceId
                    )
                case let .launchFailed(message):
                    self.updateStatus("Could not start \(operation.displayName)", for: projectPath)
                    self.addLog(
                        message,
                        type: .error,
                        projectPath: projectPath,
                        channel: .output,
                        deviceId: maintenanceDeviceId
                    )
                }
            }
        )

        if !started {
            isProjectMaintenanceRunning = false
            activeMaintenanceProjectPath = nil
            updateStatus("Project maintenance is already in progress.", for: projectPath)
            addLog(
                "Project maintenance is already in progress.",
                type: .error,
                projectPath: projectPath,
                channel: .output,
                deviceId: maintenanceDeviceId
            )
        }
    }

    private func updateStatus(_ newStatus: String, for projectPath: String) {
        projectStatuses[projectPath] = newStatus
        if self.projectPath == projectPath {
            status = newStatus
        }
    }

    private func bindSelectedDeviceSession(fallbackStatus: String? = nil) {
        selectedLiveRunID = liveRunForSelectedDevice?.id
        refreshVisibleLogs()
        syncDerivedRunState(fallbackStatus: fallbackStatus)
    }

    private func showLiveLogs(_ channel: LogChannel, for projectPath: String) {
        selection = .project(projectPath)
        selectLogChannel(channel)
    }

    private func clearDeviceLogs(for projectPath: String, deviceId: String) {
        for channel in LogChannel.allCases {
            let key = LogBufferKey(projectKey: projectPath, channel: channel, deviceId: deviceId)
            logsByBuffer[key] = []
            rolledOverLogKeys.remove(key)
        }
        refreshVisibleLogs()
    }

    func addLog(
        _ message: String,
        type: LogEntryType = .info,
        projectPath targetProjectPath: String? = nil,
        channel: LogChannel = .console,
        deviceId: String? = nil
    ) {
        let key = LogBufferKey(
            projectKey: targetProjectPath ?? activeProjectLogKey,
            channel: channel,
            deviceId: deviceId ?? activeDeviceLogKey
        )
        var entries = logsByBuffer[key] ?? []

        if entries.count >= Self.maximumLogEntries {
            entries.removeFirst(entries.count - Self.maximumLogEntries + 1)
            if !rolledOverLogKeys.contains(key) {
                rolledOverLogKeys.insert(key)
                entries.append(LogEntry(text: rolloverMessage(for: key), type: .info))
                if entries.count >= Self.maximumLogEntries { entries.removeFirst() }
            }
        }
        entries.append(LogEntry(text: message, type: type))
        logsByBuffer[key] = entries
        trimLogBuffersToGlobalLimit()

        refreshVisibleLogs()
    }

    private var activeProjectLogKey: String {
        projectPath ?? Self.unscopedLogKey
    }

    private var activeDeviceLogKey: String {
        selectedDeviceId ?? Self.unscopedDeviceKey
    }

    private var activeLogBufferKey: LogBufferKey {
        LogBufferKey(
            projectKey: activeProjectLogKey,
            channel: selectedLogChannel,
            deviceId: activeDeviceLogKey
        )
    }

    private func refreshVisibleLogs() {
        logLines = logsByBuffer[activeLogBufferKey] ?? []
    }

    private func trimLogBuffersToGlobalLimit() {
        var affectedKeys: Set<LogBufferKey> = []

        while totalLogCount > Self.maximumLogEntries, let key = oldestLogKey {
            logsByBuffer[key]?.removeFirst()
            affectedKeys.insert(key)
        }

        for key in affectedKeys where !rolledOverLogKeys.contains(key) {
            rolledOverLogKeys.insert(key)
            logsByBuffer[key, default: []].append(
                LogEntry(text: rolloverMessage(for: key), type: .info)
            )
        }

        while totalLogCount > Self.maximumLogEntries, let key = oldestLogKey {
            logsByBuffer[key]?.removeFirst()
        }
    }

    private var totalLogCount: Int {
        logsByBuffer.values.reduce(0) { $0 + $1.count }
    }

    private var oldestLogKey: LogBufferKey? {
        logsByBuffer
            .compactMap { key, entries in entries.first.map { (key, $0.timestamp) } }
            .min { $0.1 < $1.1 }?
            .0
    }

    private func rolloverMessage(for key: LogBufferKey) -> String {
        "Older \(key.channel.label.lowercased()) output was removed after reaching 10,000 lines."
    }
}
