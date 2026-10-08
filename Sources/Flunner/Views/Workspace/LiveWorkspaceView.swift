import SwiftUI

struct LiveWorkspaceView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @ObservedObject var sourceControlViewModel: SourceControlViewModel
    @ObservedObject private var terminalWorkspaces: TerminalWorkspaceManager
    @Binding var isSourceControlSheetPresented: Bool
    @ObservedObject var deviceHub: DeviceHubService
    @ObservedObject var deviceBrowser: DeviceHubWebSession
    @Binding var isDevicePreviewVisible: Bool
    @State private var showingConfigEditor = false
    @State private var devicePaneID = UUID()

    init(viewModel: WorkspaceViewModel, sourceControlViewModel: SourceControlViewModel, isSourceControlSheetPresented: Binding<Bool>, deviceHub: DeviceHubService, deviceBrowser: DeviceHubWebSession, isDevicePreviewVisible: Binding<Bool>) {
        self.viewModel = viewModel
        self.sourceControlViewModel = sourceControlViewModel
        self._isSourceControlSheetPresented = isSourceControlSheetPresented
        self.deviceHub = deviceHub
        self.deviceBrowser = deviceBrowser
        self._isDevicePreviewVisible = isDevicePreviewVisible
        terminalWorkspaces = viewModel.terminalWorkspaces
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                SetupBar(viewModel: viewModel, showingConfigEditor: $showingConfigEditor)
                Divider().overlay(WorkbenchColor.divider)

                if isDevicePreviewVisible {
                    if geometry.size.width >= 860 {
                        HSplitView {
                            consoleAndTerminal(availableHeight: geometry.size.height)
                                .frame(minWidth: 520)
                            DevicePreviewPane(hub: deviceHub, browser: deviceBrowser, isVisible: $isDevicePreviewVisible)
                                .frame(minWidth: 320, idealWidth: 400, maxWidth: 700)
                        }
                    } else {
                        VSplitView {
                            DevicePreviewPane(hub: deviceHub, browser: deviceBrowser, isVisible: $isDevicePreviewVisible)
                                .frame(minHeight: 200, idealHeight: geometry.size.height * 0.55)
                            GeometryReader { consoleGeometry in
                                consoleAndTerminal(availableHeight: consoleGeometry.size.height + 88)
                            }
                            .frame(minHeight: terminalWorkspaces.isVisible(for: viewModel.projectPath) ? 360 : 180)
                        }
                    }
                } else {
                    consoleAndTerminal(availableHeight: geometry.size.height)
                }

                WorkbenchStatusBar(
                    viewModel: viewModel,
                    sourceControlViewModel: sourceControlViewModel,
                    isSourceControlSheetPresented: $isSourceControlSheetPresented
                )
            }
            .background(WorkbenchColor.background)
        }
        .accessibilityIdentifier("consoleWorkspace")
        .onAppear { if isDevicePreviewVisible { deviceHub.openPane(devicePaneID) } }
        .onChange(of: isDevicePreviewVisible) { _, visible in
            if visible { deviceHub.openPane(devicePaneID) }
            else { deviceBrowser.reset(); deviceHub.closePane(devicePaneID) }
        }
        .onDisappear { deviceBrowser.reset(); deviceHub.closePane(devicePaneID) }
        .sheet(isPresented: $showingConfigEditor) {
            if let projectPath = viewModel.projectPath {
                LaunchConfigEditorSheet(
                    projectPath: projectPath,
                    initialConfigs: viewModel.launchConfigs,
                    onSave: { viewModel.reloadLaunchConfigs() }
                )
            }
        }
    }

    private func consoleAndTerminal(availableHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            ConsoleToolbar(viewModel: viewModel)
                .frame(minHeight: isDevicePreviewVisible ? 48 : nil)
                .background(WorkbenchColor.surface)
            Divider().overlay(WorkbenchColor.divider)
            ConsolePanel(viewModel: viewModel)
                .frame(minHeight: 136)
            if let projectPath = viewModel.projectPath,
               viewModel.isTerminalAvailable,
               terminalWorkspaces.isVisible(for: projectPath) {
                let paneHeight = clampedPaneHeight(terminalWorkspaces.snapshot(for: projectPath).paneHeight, availableHeight: availableHeight)
                TerminalResizeDivider(
                    currentHeight: paneHeight,
                    onChange: { proposedHeight in
                        terminalWorkspaces.updatePaneHeight(clampedPaneHeight(proposedHeight, availableHeight: availableHeight), for: projectPath, persist: false)
                    },
                    onEnd: { terminalWorkspaces.persistPaneHeight(for: projectPath) }
                )
                TerminalPaneView(manager: terminalWorkspaces, projectPath: projectPath)
                    .frame(height: CGFloat(paneHeight))
            }
        }
        .frame(minHeight: 180)
    }

    private func clampedPaneHeight(_ height: Double, availableHeight: CGFloat) -> Double {
        let reservedHeight = 60.0 + 44.0 + 180.0 + 8.0
        let maximumHeight = max(
            TerminalWorkspaceSnapshot.minimumPaneHeight,
            Double(availableHeight) - reservedHeight
        )
        return min(maximumHeight, max(TerminalWorkspaceSnapshot.minimumPaneHeight, height))
    }
}

private struct SetupBar: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @Binding var showingConfigEditor: Bool

    var body: some View {
        HStack(spacing: WorkbenchSpacing.compact) {
            deviceMenu
            configurationMenu
            Spacer(minLength: WorkbenchSpacing.small)
            RunControlCluster(viewModel: viewModel)
        }
        .padding(.horizontal, WorkbenchSpacing.medium)
        .padding(.vertical, 2)
        .background(WorkbenchColor.surface)
    }

    @ViewBuilder
    private var deviceMenu: some View {
        let title = viewModel.selectedDevice?.displayName ?? (viewModel.devices.isEmpty ? "No devices" : "Choose device")
        WorkbenchMenu(
            title: "Device",
            value: title,
            systemImage: viewModel.selectedDevice?.systemImage ?? "display",
            maxWidth: 200,
            runState: viewModel.liveRunForSelectedDevice?.state
        ) {
            deviceMenuContent
        }
    }

    @ViewBuilder
    private var deviceMenuContent: some View {
        if viewModel.devices.isEmpty {
            Text("No connected devices")
        }
        ForEach(viewModel.devices) { device in
            Button {
                viewModel.selectDevice(device.id)
            } label: {
                HStack {
                    if viewModel.selectedDevice?.id == device.id {
                        Label(device.displayName, systemImage: "checkmark")
                    } else {
                        Label(device.displayName, systemImage: device.systemImage)
                    }
                    if let run = viewModel.liveRun(forDeviceId: device.id) {
                        Spacer(minLength: WorkbenchSpacing.small)
                        WorkbenchRunStateDot(state: run.state)
                    }
                }
            }
            .accessibilityValue(viewModel.liveRun(forDeviceId: device.id)?.state.isRunning == true ? "Running" : "")
        }
        Divider()
        if !viewModel.runningEmulators.isEmpty {
            Button("Kill All Simulators", systemImage: "xmark.circle") {
                viewModel.killAllEmulators()
            }
            Divider()
        }
        Button("Open iOS Simulator", systemImage: "iphone") {
            viewModel.openiOSSimulator()
        }
        Menu {
            if viewModel.androidEmulators.isEmpty {
                Button("Refresh Emulator List") {
                    viewModel.refreshEmulators()
                }
            }
            ForEach(viewModel.androidEmulators) { device in
                if viewModel.isEmulatorRunning(device) {
                    Button("Kill \(device.name)") {
                        viewModel.killEmulator(device)
                    }
                } else {
                    Button(device.name) {
                            viewModel.launchEmulator(device)
                        }
                }
            }
        } label: {
            Label("Open Android Emulator", systemImage: "rectangle.landscape.rotate")
        }
        Divider()
        Button("Refresh Devices", systemImage: "arrow.clockwise") {
            viewModel.refreshDevices()
        }
    }

    @ViewBuilder
    private var configurationMenu: some View {
        let title = viewModel.selectedLaunchConfig?.displayName ?? "No configuration"
        WorkbenchMenu(title: "Configuration", value: title, systemImage: "slider.horizontal.3") {
            configurationMenuContent
        }
        .disabled(viewModel.launchConfigs.isEmpty)
    }

    @ViewBuilder
    private var configurationMenuContent: some View {
        ForEach(viewModel.launchConfigs) { config in
            Button {
                viewModel.selectConfiguration(config.name)
            } label: {
                if viewModel.selectedLaunchConfig?.name == config.name {
                    Label(config.displayName, systemImage: "checkmark")
                } else {
                    Text(config.displayName)
                }
            }
        }
        Divider()
        Button("Edit Configurations…", systemImage: "slider.horizontal.2.gobackward") {
            showingConfigEditor = true
        }
        .disabled(viewModel.projectPath == nil)
    }
}

private struct WorkbenchMenu<Content: View>: View {
    let title: String
    let value: String
    let systemImage: String
    var maxWidth: CGFloat = 240
    var runState: AppState?
    @ViewBuilder let content: Content

    init(
        title: String,
        value: String,
        systemImage: String,
        maxWidth: CGFloat = 240,
        runState: AppState? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.maxWidth = maxWidth
        self.runState = runState
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: WorkbenchSpacing.small) {
                Image(systemName: systemImage)
                    .foregroundStyle(WorkbenchColor.textSecondary.opacity(0.78))
                Text(value)
                    .workbenchFont(.body, weight: .medium)
                    .foregroundStyle(WorkbenchColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let runState {
                    WorkbenchRunStateDot(state: runState)
                }
                Image(systemName: "chevron.down")
                    .workbenchFont(.caption)
                    .foregroundStyle(WorkbenchColor.textSecondary.opacity(0.7))
            }
            .frame(minWidth: 164, maxWidth: maxWidth, minHeight: 44, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .help("\(title): \(value)")
        .accessibilityLabel("\(title): \(value)")
        .accessibilityValue(runState?.isRunning == true ? "Running" : "")
    }
}

private struct RunControlCluster: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @EnvironmentObject private var keyboardShortcuts: KeyboardShortcutStore

    var body: some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            Button(action: viewModel.requestCleanAndPubGet) {
                Label("Clean + Pub Get", systemImage: "eraser.fill").labelStyle(.iconOnly)
            }
            .buttonStyle(WorkbenchIconButtonStyle(color: WorkbenchColor.textSecondary))
            .disabled(!viewModel.canCleanAndPubGet)
            .workbenchTooltip(viewModel.cleanAndPubGetBlockReason ?? actionHelp("Clean + Pub Get", action: .cleanAndPubGet))
            .accessibilityLabel("Clean and Pub Get")

            Button(action: viewModel.pubGet) {
                Label("Pub Get", systemImage: "shippingbox.fill").labelStyle(.iconOnly)
            }
            .buttonStyle(WorkbenchIconButtonStyle(color: WorkbenchColor.textSecondary))
            .disabled(!viewModel.canPubGet)
            .workbenchTooltip(viewModel.pubGetBlockReason ?? actionHelp("Pub Get", action: .pubGet))
            .accessibilityLabel("Pub Get")

            Divider()
                .frame(height: 16)
                .padding(.horizontal, WorkbenchSpacing.xs)

            Button(action: viewModel.hotReload) {
                Label("Hot Reload", systemImage: "bolt.fill").labelStyle(.iconOnly)
            }
            .buttonStyle(WorkbenchIconButtonStyle(color: WorkbenchColor.warning))
            .disabled(!viewModel.canControlSelectedRun)
            .workbenchTooltip(actionHelp("Hot Reload", action: .hotReload))
            .accessibilityLabel("Hot Reload")

            Button(action: viewModel.hotRestart) {
                Label("Hot Restart", systemImage: "arrow.triangle.2.circlepath").labelStyle(.iconOnly)
            }
            .buttonStyle(WorkbenchIconButtonStyle(color: WorkbenchColor.info))
            .disabled(!viewModel.canControlSelectedRun)
            .workbenchTooltip(actionHelp("Hot Restart", action: .hotRestart))
            .accessibilityLabel("Hot Restart")

            if viewModel.selectedLiveRun != nil {
                Button(action: viewModel.stopApp) {
                    Label(viewModel.selectedLiveRun?.state == .stopping ? "Stopping…" : "Stop", systemImage: "stop.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(WorkbenchIconButtonStyle(color: WorkbenchColor.error))
                .disabled(!viewModel.canStopSelectedRun)
                .workbenchTooltip(actionHelp("Stop", action: .stop))
                .accessibilityLabel(viewModel.selectedLiveRun?.state == .stopping ? "Stopping" : "Stop")
            }

            Button(action: viewModel.runApp) {
                Label("Run", systemImage: "play.fill").labelStyle(.iconOnly)
            }
            .buttonStyle(WorkbenchIconButtonStyle(color: WorkbenchColor.success))
            .disabled(!viewModel.canRun)
            .workbenchTooltip(viewModel.runBlockReason ?? actionHelp("Run", action: .run))
            .accessibilityLabel("Run")
        }
    }

    private func actionHelp(_ title: String, action: WorkbenchAction) -> String {
        "\(title) (\(keyboardShortcuts.binding(for: action).displayName))"
    }
}
