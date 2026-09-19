import Foundation

enum FlutterProjectMaintenanceOperation: Equatable {
    case pubGet
    case cleanAndPubGet

    var commands: [[String]] {
        switch self {
        case .pubGet:
            [["pub", "get"]]
        case .cleanAndPubGet:
            [["clean"], ["pub", "get"]]
        }
    }

    var displayName: String {
        switch self {
        case .pubGet: "Pub Get"
        case .cleanAndPubGet: "Clean + Pub Get"
        }
    }
}

enum FlutterProjectMaintenanceOutcome: Equatable {
    case succeeded
    case failed(command: String, exitCode: Int32)
    case launchFailed(String)
}

@MainActor
protocol FlutterProjectMaintaining: AnyObject {
    @discardableResult
    func run(
        _ operation: FlutterProjectMaintenanceOperation,
        projectPath: String,
        onOutput: @escaping (String, LogEntryType) -> Void,
        completion: @escaping (FlutterProjectMaintenanceOutcome) -> Void
    ) -> Bool
}

@MainActor
final class FlutterProjectMaintenanceService: FlutterProjectMaintaining {
    private var process: Process?
    private var stdoutPipe = Pipe()
    private var stderrPipe = Pipe()
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var pendingCommands: [[String]] = []
    private var commandIndex = 0
    private var projectPath = ""
    private var executable = ProjectToolchain.flutter.executable
    private var onOutput: ((String, LogEntryType) -> Void)?
    private var completion: ((FlutterProjectMaintenanceOutcome) -> Void)?

    deinit {
        process?.terminate()
    }

    @discardableResult
    func run(
        _ operation: FlutterProjectMaintenanceOperation,
        projectPath: String,
        onOutput: @escaping (String, LogEntryType) -> Void,
        completion: @escaping (FlutterProjectMaintenanceOutcome) -> Void
    ) -> Bool {
        guard process == nil, pendingCommands.isEmpty else { return false }

        self.projectPath = projectPath
        executable = (ProjectToolchain.detect(at: projectPath) ?? .flutter).executable
        self.onOutput = onOutput
        self.completion = completion
        pendingCommands = operation.commands
        commandIndex = 0
        runCurrentCommand()
        return true
    }

    private func runCurrentCommand() {
        guard pendingCommands.indices.contains(commandIndex) else {
            finish(.succeeded)
            return
        }

        let arguments = pendingCommands[commandIndex]
        stdoutPipe = Pipe()
        stderrPipe = Pipe()
        stdoutBuffer = ""
        stderrBuffer = ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ic", ([executable] + arguments).joined(separator: " ")]
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data, isStderr: false) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data, isStderr: true) }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.handleTermination(exitCode: process.terminationStatus)
            }
        }

        let command = ([executable] + arguments).joined(separator: " ")
        onOutput?(command, .command)

        do {
            try process.run()
            self.process = process
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            finish(.launchFailed(error.localizedDescription))
        }
    }

    private func consume(_ data: Data, isStderr: Bool) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let normalized = text.replacingOccurrences(of: "\r", with: "\n")

        if isStderr {
            let result = Self.splitCompleteLines(stderrBuffer + normalized)
            stderrBuffer = result.remainder
            result.lines.forEach { emit($0, isStderr: true) }
        } else {
            let result = Self.splitCompleteLines(stdoutBuffer + normalized)
            stdoutBuffer = result.remainder
            result.lines.forEach { emit($0, isStderr: false) }
        }
    }

    private static func splitCompleteLines(_ buffer: String) -> (lines: [String], remainder: String) {
        let lines = buffer.components(separatedBy: "\n")
        guard lines.count > 1 else { return ([], buffer) }
        return (Array(lines.dropLast()), lines.last ?? "")
    }

    private func emit(_ rawLine: String, isStderr: Bool) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        onOutput?(line, isStderr ? .error : Self.classify(line))
    }

    private func handleTermination(exitCode: Int32) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        emit(stdoutBuffer, isStderr: false)
        emit(stderrBuffer, isStderr: true)
        stdoutBuffer = ""
        stderrBuffer = ""
        process = nil

        let arguments = pendingCommands[commandIndex]
        let command = ([executable] + arguments).joined(separator: " ")
        guard exitCode == 0 else {
            finish(.failed(command: command, exitCode: exitCode))
            return
        }

        commandIndex += 1
        runCurrentCommand()
    }

    private func finish(_ outcome: FlutterProjectMaintenanceOutcome) {
        process = nil
        pendingCommands = []
        commandIndex = 0
        projectPath = ""
        onOutput = nil
        let completion = completion
        self.completion = nil
        completion?(outcome)
    }

    private static func classify(_ line: String) -> LogEntryType {
        let lowercase = line.lowercased()
        if lowercase.contains("error") || lowercase.contains("failed") || lowercase.contains("exception") {
            return .error
        }
        if lowercase.hasPrefix("running") || lowercase.hasPrefix("resolving") || lowercase.hasPrefix("downloading") {
            return .command
        }
        return .info
    }
}
