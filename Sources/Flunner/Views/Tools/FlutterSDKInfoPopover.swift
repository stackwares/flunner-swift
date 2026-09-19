import SwiftUI

struct FlutterSDKInfoPopover: View {
    @ObservedObject var service: FlutterSDKInfoService
    var onOpenLink: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if service.isLoading {
                loadingView
            } else if let error = service.errorMessage {
                errorView(error)
            } else if let info = service.sdkInfo {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        headerSection(info)
                        Divider().padding(.vertical, WorkbenchSpacing.small)
                        pathSection(info)
                        Divider().padding(.vertical, WorkbenchSpacing.small)
                        doctorSection(info)
                        Divider().padding(.vertical, WorkbenchSpacing.small)
                        linksSection
                    }
                    .padding(WorkbenchSpacing.medium)
                }
            } else {
                emptyView
            }
        }
        .frame(width: 440, height: 520)
        .background(WorkbenchColor.background)
        .task {
            if service.sdkInfo == nil {
                await service.refresh()
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: WorkbenchSpacing.medium) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Gathering \(service.toolchain.displayName) SDK info…")
                .workbenchFont(.body)
                .foregroundStyle(WorkbenchColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: WorkbenchSpacing.medium) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(WorkbenchColor.warning)
            Text("Could not load SDK info")
                .workbenchFont(.heading)
                .foregroundStyle(WorkbenchColor.textPrimary)
            Text(message)
                .workbenchFont(.body)
                .foregroundStyle(WorkbenchColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await service.refresh() }
            }
            .buttonStyle(.borderedProminent)
            .tint(WorkbenchColor.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: WorkbenchSpacing.medium) {
            Image(systemName: "gearshape")
                .font(.title)
                .foregroundStyle(WorkbenchColor.textSecondary)
            Text("No SDK info available")
                .workbenchFont(.heading)
                .foregroundStyle(WorkbenchColor.textPrimary)
            Button("Load SDK Info") {
                Task { await service.refresh() }
            }
            .buttonStyle(.borderedProminent)
            .tint(WorkbenchColor.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func headerSection(_ info: FlutterSDKInfo) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                Text(service.toolchain.displayName)
                    .workbenchFont(.display)
                    .foregroundStyle(WorkbenchColor.textPrimary)
                Text(info.flutterVersion)
                    .workbenchFont(.caption, design: .monospaced)
                    .foregroundStyle(WorkbenchColor.textSecondary)
            }
            Spacer()
            ChannelBadge(channel: info.channel)
            Button {
                Task { await service.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .workbenchFont(.body)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(WorkbenchColor.textSecondary)
            .accessibilityLabel("Refresh SDK info")
            .disabled(service.isLoading)
        }
    }

    private func pathSection(_ info: FlutterSDKInfo) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.small) {
            SectionHeader(title: "SDK Path", systemImage: "folder")

            Text(info.flutterPath)
                .workbenchFont(.caption, design: .monospaced)
                .foregroundStyle(WorkbenchColor.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, WorkbenchSpacing.small)
                .padding(.vertical, WorkbenchSpacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: WorkbenchRadius.small)
                        .fill(WorkbenchColor.surface)
                )

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: info.flutterPath)])
            } label: {
                Label("Reveal in Finder", systemImage: "arrow.forward.circle")
                    .workbenchFont(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(WorkbenchColor.accent)
            .padding(.top, WorkbenchSpacing.xs)
            .accessibilityLabel("Reveal \(service.toolchain.displayName) SDK in Finder")

            HStack(spacing: WorkbenchSpacing.medium) {
                LabeledInfo(label: "Dart", value: info.dartVersion)
                if let engineRev = info.engineRevision {
                    LabeledInfo(label: "Engine", value: String(engineRev.prefix(10)))
                }
            }
            .padding(.top, WorkbenchSpacing.small)
        }
    }

    private func doctorSection(_ info: FlutterSDKInfo) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.small) {
            SectionHeader(
                title: "Doctor",
                systemImage: "stethoscope",
                trailing: Text("\(info.doctorCategories.count) checks")
                    .workbenchFont(.caption)
                    .foregroundStyle(WorkbenchColor.textSecondary)
            )

            ForEach(info.doctorCategories) { category in
                DoctorCategoryRow(category: category)
            }
        }
    }

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.small) {
            SectionHeader(title: "Useful Links", systemImage: "link")

            HStack(spacing: WorkbenchSpacing.small) {
                LinkButton(title: "DartPad", url: "https://dartpad.dev", systemImage: "play.rectangle", onOpenLink: onOpenLink)
                LinkButton(title: "Pub.dev", url: "https://pub.dev", systemImage: "shippingbox", onOpenLink: onOpenLink)
                LinkButton(title: "\(service.toolchain.displayName) Docs", url: service.toolchain.docsURL, systemImage: "book", onOpenLink: onOpenLink)
                LinkButton(title: "Dart Docs", url: "https://dart.dev/guides", systemImage: "books.vertical", onOpenLink: onOpenLink)
            }
        }
    }
}

private struct ChannelBadge: View {
    let channel: String

    var body: some View {
        Text(channel)
            .workbenchFont(.caption, weight: .semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, WorkbenchSpacing.small)
            .padding(.vertical, 3)
            .background(WorkbenchColor.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SectionHeader: View {
    let title: String
    let systemImage: String
    var trailing: AnyView? = nil

    init(title: String, systemImage: String, trailing: some View = EmptyView()) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = AnyView(trailing)
    }

    var body: some View {
        HStack(spacing: WorkbenchSpacing.small) {
            Image(systemName: systemImage)
                .foregroundStyle(WorkbenchColor.textSecondary)
                .frame(width: 16)
            Text(title)
                .workbenchFont(.heading)
                .foregroundStyle(WorkbenchColor.textPrimary)
            Spacer()
            trailing
        }
    }
}

private struct LabeledInfo: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .workbenchFont(.caption)
                .foregroundStyle(WorkbenchColor.textSecondary)
            Text(value)
                .workbenchFont(.caption, design: .monospaced)
                .foregroundStyle(WorkbenchColor.textPrimary)
        }
    }
}

private struct DoctorCategoryRow: View {
    let category: DoctorCategory
    @State private var isExpanded = false

    var statusIcon: String {
        switch category.status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    var statusColor: Color {
        switch category.status {
        case .ok: WorkbenchColor.success
        case .warning: WorkbenchColor.warning
        case .error: WorkbenchColor.error
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: WorkbenchSpacing.small) {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                        .frame(width: 16)
                    Text(category.name)
                        .workbenchFont(.body)
                        .foregroundStyle(WorkbenchColor.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if !category.details.isEmpty {
                        Image(systemName: "chevron.right")
                            .workbenchFont(.caption)
                            .foregroundStyle(WorkbenchColor.textSecondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded && !category.details.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(category.details.enumerated()), id: \.offset) { _, detail in
                        Text(detail)
                            .workbenchFont(.caption, design: .monospaced)
                            .foregroundStyle(WorkbenchColor.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 24)
                .padding(.top, WorkbenchSpacing.xs)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct LinkButton: View {
    let title: String
    let url: String
    let systemImage: String
    let onOpenLink: (URL) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            onOpenLink(URL(string: url)!)
        } label: {
            VStack(spacing: WorkbenchSpacing.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                    .foregroundStyle(WorkbenchColor.accent)
                Text(title)
                    .workbenchFont(.caption)
                    .foregroundStyle(WorkbenchColor.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, WorkbenchSpacing.small)
            .background(
                RoundedRectangle(cornerRadius: WorkbenchRadius.small)
                    .fill(isHovered ? WorkbenchColor.surface : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel("Open \(title)")
        .accessibilityHint("Opens \(url) in your default browser")
    }
}
