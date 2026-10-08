import SwiftUI

extension Notification.Name {
    static let toggleDevicePreview = Notification.Name("toggleDevicePreview")
}

struct DevicePreviewPane: View {
    @ObservedObject var hub: DeviceHubService
    @ObservedObject var browser: DeviceHubWebSession
    @Binding var isVisible: Bool
    @State private var webError: String?
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: WorkbenchSpacing.small) {
                Image(systemName: "iphone.gen3")
                    .foregroundStyle(WorkbenchColor.textSecondary)
                Text("Device preview").workbenchFont(.body, weight: .semibold)
                Spacer(minLength: 0)
                Button {
                    webError = nil
                    if case .ready = hub.state { browser.reload() }
                    else { hub.reconnect() }
                } label: { Image(systemName: "arrow.clockwise") }
                .disabled(hub.state == .installing || hub.state == .starting)
                .help("Reload device preview")
                .accessibilityLabel("Reload device preview")

                Button { isExpanded = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .disabled(!isReady)
                    .help("Expand device preview")
                    .accessibilityLabel("Expand device preview")
                Button { isVisible = false } label: { Image(systemName: "xmark") }
                    .help("Hide device preview")
                    .accessibilityLabel("Hide device preview")
            }
            .buttonStyle(PreviewControlStyle())
            .foregroundStyle(WorkbenchColor.textPrimary)
            .padding(.horizontal, WorkbenchSpacing.medium)
            .frame(height: 48)
            .background(WorkbenchColor.surface)

            Group {
                switch hub.state {
                case .ready(let url):
                    if let webError {
                        message(title: "Preview disconnected", detail: webError, retry: true)
                    } else if isExpanded {
                        message(title: "Preview expanded", detail: "Your device is open in the larger view.")
                    } else {
                        DeviceHubWebView(url: url, session: browser, onError: { webError = $0 })
                            .accessibilityIdentifier("deviceHubWebView")
                    }
                case .installing:
                    message(title: "Preparing device preview", detail: "Downloading the preview engine. This only happens once.", progress: true)
                case .starting:
                    message(title: "Connecting to your devices", detail: "Your simulators and emulators will appear here.", progress: true)
                case .failed(let error):
                    message(title: "Device preview is unavailable", detail: error, retry: true)
                case .idle:
                    message(title: "Device preview", detail: "Opening your local devices…", progress: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: WorkbenchSpacing.small) {
                Text("Tap, swipe & type").workbenchFont(.caption)
                Spacer(minLength: 0)
                Text("iOS + Android").workbenchFont(.caption)
            }
            .foregroundStyle(WorkbenchColor.textSecondary)
            .padding(.horizontal, WorkbenchSpacing.medium)
            .padding(.vertical, WorkbenchSpacing.small)
            .background(WorkbenchColor.surface)
        }
        .background(WorkbenchColor.background)
        .accessibilityIdentifier("devicePreviewPane")
        .sheet(isPresented: $isExpanded) {
            if case .ready(let url) = hub.state {
                VStack(spacing: 0) {
                    HStack {
                        Text("Devices").workbenchFont(.heading)
                        Spacer()
                        Button("Done") { isExpanded = false }.keyboardShortcut(.cancelAction)
                    }
                    .padding(WorkbenchSpacing.medium)
                    if let webError {
                        message(title: "Preview disconnected", detail: webError, retry: true)
                    } else {
                        DeviceHubWebView(url: url, session: browser, compact: false, onError: { webError = $0 })
                    }
                }
                .frame(minWidth: 820, minHeight: 600)
                .background(WorkbenchColor.surface)
            }
        }
    }

    private var isReady: Bool { if case .ready = hub.state { return true }; return false }

    private func message(title: String, detail: String, progress: Bool = false, retry: Bool = false) -> some View {
        ScrollView {
            VStack(spacing: WorkbenchSpacing.medium) {
                if progress { ProgressView().controlSize(.small) }
                Text(title).workbenchFont(.heading).foregroundStyle(WorkbenchColor.textPrimary)
                Text(detail).workbenchFont(.body).foregroundStyle(WorkbenchColor.textSecondary)
                    .textSelection(.enabled)
                if retry {
                    Button("Reconnect") {
                        webError = nil
                        hub.reconnect()
                    }
                    .controlSize(.large)
                }
            }
            .multilineTextAlignment(.center)
            .padding(WorkbenchSpacing.large)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
    }
}

private struct PreviewControlStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .foregroundStyle(isEnabled ? WorkbenchColor.textPrimary : WorkbenchColor.textSecondary.opacity(0.5))
            .background(configuration.isPressed ? WorkbenchColor.textSecondary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }
}
