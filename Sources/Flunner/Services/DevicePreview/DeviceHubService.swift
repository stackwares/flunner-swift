import AppKit
import Foundation

/// Owns only Flunner's localhost server. Devices and shared simulator helpers
/// keep running when the pane is closed.
@MainActor
final class DeviceHubService: ObservableObject {
    enum State: Equatable {
        case idle
        case installing
        case starting
        case ready(URL)
        case failed(String)
    }

    static let version = "0.12.0"
    @Published private(set) var state: State = .idle
    private var startup: Task<Void, Never>?
    private var process: Process?
    private var generation = UUID()
    private var paneOwners: Set<UUID> = []
    private let directory: URL
    private let serverLogName = "server-\(UUID().uuidString).log"

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Flunner/DeviceHub/\(Self.version)", isDirectory: true)
    }

    func openPane(_ id: UUID) {
        paneOwners.insert(id)
        start()
    }

    func closePane(_ id: UUID) {
        paneOwners.remove(id)
        if paneOwners.isEmpty { stop() }
    }

    func start() {
        guard startup == nil, process == nil else { return }
        let run = UUID()
        generation = run
        state = .starting
        startup = Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let node = try await resolveNode()
                try Task.checkCancellation()
                let environment = Self.environment(node: node)
                let cli = directory.appendingPathComponent("node_modules/expo-device-hub/dist/server/cli.mjs")
                if !FileManager.default.fileExists(atPath: cli.path) {
                    state = .installing
                    let npm = node.deletingLastPathComponent().appendingPathComponent("npm")
                    guard FileManager.default.isExecutableFile(atPath: npm.path) else {
                        throw HubError.message("Node.js was found, but npm is missing. Install Node.js with npm, then retry.")
                    }
                    try await install(npm: npm, environment: environment)
                }
                try Task.checkCancellation()
                guard generation == run else { return }
                state = .starting
                let log = directory.appendingPathComponent(serverLogName)
                let server = try launch(
                    executable: node,
                    arguments: [cli.path, "--host", "127.0.0.1", "--port", "0", "--transport", "mjpeg", "--hide-sidebar"],
                    environment: environment,
                    log: log
                )
                process = server
                server.terminationHandler = { [weak self] terminated in
                    Task { @MainActor in
                        guard let self, self.generation == run else { return }
                        self.process = nil
                        self.state = .failed("Device preview stopped (exit \(terminated.terminationStatus)). Reconnect to try again.")
                    }
                }
                for _ in 0..<120 {
                    try Task.checkCancellation()
                    guard server.isRunning else {
                        throw HubError.message("Device preview could not start.\n\(Self.logTail(log))")
                    }
                    if let url = Self.serverURL(in: Self.logTail(log)) {
                        let (_, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5))
                        if (response as? HTTPURLResponse)?.statusCode == 200 {
                            guard generation == run else { return }
                            state = .ready(url)
                            startup = nil
                            return
                        }
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
                throw HubError.message("Device preview took too long to start. Reconnect to try again.")
            } catch is CancellationError {
                // Closing the pane deliberately cancels installation/startup.
            } catch {
                guard generation == run else { return }
                generation = UUID()
                stopProcess()
                startup = nil
                state = .failed(error.localizedDescription)
            }
            if generation == run { startup = nil }
        }
    }

    func stop() {
        generation = UUID()
        startup?.cancel()
        startup = nil
        stopProcess()
        state = .idle
    }

    func reconnect() {
        stop()
        start()
    }

    private func stopProcess() {
        guard let running = process else { return }
        process = nil
        if running.isRunning { running.terminate() }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if running.isRunning { kill(running.processIdentifier, SIGKILL) }
        }
    }

    private func resolveNode() async throws -> URL {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".volta/bin").path]
        for path in paths {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent("node")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        // Finder launches do not inherit nvm/asdf shell configuration.
        let log = directory.appendingPathComponent("node-location.log")
        do {
            try await runToCompletion(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lc", "command -v node"], environment: ProcessInfo.processInfo.environment, log: log)
        } catch is CancellationError { throw CancellationError() }
        catch { throw HubError.message("Device preview needs Node.js and npm. Install Node.js, then retry.") }
        let path = Self.logTail(log).split(separator: "\n").last.map(String.init) ?? ""
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw HubError.message("Device preview needs Node.js and npm. Install Node.js, then retry.")
        }
        return URL(fileURLWithPath: path)
    }

    private func install(npm: URL, environment: [String: String]) async throws {
        do {
            try await runToCompletion(
                executable: npm,
                arguments: ["install", "--prefix", directory.path, "--no-audit", "--no-fund", "--save-exact", "expo-device-hub@\(Self.version)"],
                environment: environment,
                log: directory.appendingPathComponent("install.log")
            )
        } catch is CancellationError { throw CancellationError() }
        catch {
            throw HubError.message("Could not install the device preview engine. Check your internet connection and Node.js installation, then retry.\n\(Self.logTail(directory.appendingPathComponent("install.log")))")
        }
    }

    private func runToCompletion(executable: URL, arguments: [String], environment: [String: String], log: URL) async throws {
        let command = Process()
        process = command
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                command.terminationHandler = { terminated in
                    if terminated.terminationStatus == 0 { continuation.resume() }
                    else { continuation.resume(throwing: HubError.message("Command failed (exit \(terminated.terminationStatus)).")) }
                }
                do {
                    try configureAndRun(command, executable: executable, arguments: arguments, environment: environment, log: log)
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if command.isRunning { command.terminate() }
        }
        if process === command { process = nil }
        try Task.checkCancellation()
    }

    private func launch(executable: URL, arguments: [String], environment: [String: String], log: URL) throws -> Process {
        let command = Process()
        try configureAndRun(command, executable: executable, arguments: arguments, environment: environment, log: log)
        return command
    }

    private func configureAndRun(_ command: Process, executable: URL, arguments: [String], environment: [String: String], log: URL) throws {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        command.executableURL = executable
        command.arguments = arguments
        command.environment = environment
        command.currentDirectoryURL = directory
        command.standardOutput = handle
        command.standardError = handle
        try command.run()
    }

    static func environment(node: URL, inherited: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: String] {
        var environment = inherited
        let sdk = inherited["ANDROID_HOME"] ?? inherited["ANDROID_SDK_ROOT"] ?? home.appendingPathComponent("Library/Android/sdk").path
        environment["ANDROID_HOME"] = sdk
        environment["ANDROID_SDK_ROOT"] = sdk
        environment["PATH"] = [node.deletingLastPathComponent().path, "\(sdk)/platform-tools", "\(sdk)/emulator", "\(sdk)/cmdline-tools/latest/bin", "/opt/homebrew/bin", "/usr/local/bin", inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        // A hosting agent may itself be using Device Hub. Never inherit its
        // transport, remote access, recording, or mount-path configuration.
        for key in environment.keys where key.hasPrefix("EXPO_DEVICE_HUB_") { environment.removeValue(forKey: key) }
        return environment
    }

    static func serverURL(in output: String) -> URL? {
        guard let range = output.range(of: #"Local:\s+http://localhost:(\d+)"#, options: .regularExpression),
              let port = output[range].split(separator: ":").last.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
              (1...65535).contains(port) else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/")
    }

    private static func logTail(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 8192 ? size - 8192 : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }
}

private enum HubError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
