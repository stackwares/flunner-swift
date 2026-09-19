import AppKit
import Foundation

/// Opens the iOS simulator UI for the active Xcode.
///
/// Xcode 27 no longer ships `Contents/Developer/Applications/Simulator.app`; the
/// simulator UI moved into Device Hub at `Contents/Applications/DeviceHub.app`
/// (bundle id `com.apple.dt.Devices`), so `open -a Simulator` fails there.
/// Device Hub is preferred when present, with Simulator.app kept for Xcode 26
/// and earlier.
enum IOSSimulatorLauncher {
    static let deviceHubBundleID = "com.apple.dt.Devices"
    static let simulatorBundleID = "com.apple.iphonesimulator"

    struct App: Equatable {
        let url: URL
        let isDeviceHub: Bool

        var displayName: String { isDeviceHub ? "Device Hub" : "Simulator" }
    }

    /// Candidate bundles for a developer directory such as
    /// `/Applications/Xcode.app/Contents/Developer`, most preferred first.
    static func candidates(developerDir: String) -> [App] {
        let developerURL = URL(fileURLWithPath: developerDir)
        return [
            App(
                url: developerURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("Applications")
                    .appendingPathComponent("DeviceHub.app"),
                isDeviceHub: true
            ),
            App(
                url: developerURL
                    .appendingPathComponent("Applications")
                    .appendingPathComponent("Simulator.app"),
                isDeviceHub: false
            ),
        ]
    }

    /// Resolves the simulator UI to open. Falls back to LaunchServices lookups by
    /// bundle id when `xcode-select` points somewhere unexpected.
    static func resolve(
        developerDir: String?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        applicationURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    ) -> App? {
        if let developerDir, !developerDir.isEmpty,
           let app = candidates(developerDir: developerDir).first(where: { fileExists($0.url.path) }) {
            return app
        }
        if let url = applicationURL(deviceHubBundleID) {
            return App(url: url, isDeviceHub: true)
        }
        if let url = applicationURL(simulatorBundleID) {
            return App(url: url, isDeviceHub: false)
        }
        return nil
    }

    /// The active developer directory: `DEVELOPER_DIR`, else `xcode-select -p`.
    static func activeDeveloperDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let fromEnvironment = environment["DEVELOPER_DIR"], !fromEnvironment.isEmpty {
            return fromEnvironment
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    /// Opens Device Hub (Xcode 27+) or Simulator.app. Returns the app that was
    /// asked to open, or nil when neither could be found.
    @discardableResult
    static func open(onLog: ((String, LogEntryType) -> Void)? = nil) -> App? {
        guard let app = resolve(developerDir: activeDeveloperDirectory()) else {
            onLog?("Could not find Device Hub or Simulator.app. Is Xcode installed and selected with xcode-select?", .error)
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", app.url.path]
        do {
            try process.run()
            onLog?("Opening \(app.displayName)", .info)
            return app
        } catch {
            onLog?("Failed to open \(app.displayName): \(error.localizedDescription)", .error)
            return nil
        }
    }
}
