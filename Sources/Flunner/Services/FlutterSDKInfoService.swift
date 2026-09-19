import Foundation

@MainActor
final class FlutterSDKInfoService: ObservableObject {
    @Published private(set) var sdkInfo: FlutterSDKInfo?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// SDK being described: Flutter, or DartNative when a DartNative project is open.
    @Published private(set) var toolchain: ProjectToolchain = .flutter

    private let processRunner: ProcessRunner

    init(processRunner: ProcessRunner = ShellProcessRunner()) {
        self.processRunner = processRunner
    }

    /// Switches the described SDK. Clears stale info so the UI never shows the
    /// Flutter SDK for a DartNative project (or the reverse) while refreshing.
    func prepare(for toolchain: ProjectToolchain) {
        guard self.toolchain != toolchain else { return }
        self.toolchain = toolchain
        sdkInfo = nil
        errorMessage = nil
    }

    func refresh() async {
        let executable = toolchain.executable
        isLoading = true
        errorMessage = nil

        do {
            let flutterPath = try await resolveSDKPath(executable: executable)
            let versionInfo = try await resolveVersionInfo(executable: executable)
            let doctorCategories = try await resolveDoctor(executable: executable)
            // A refresh for another toolchain may have started meanwhile; drop this result.
            guard executable == toolchain.executable else {
                isLoading = false
                return
            }

            sdkInfo = FlutterSDKInfo(
                flutterPath: flutterPath,
                flutterVersion: versionInfo.version,
                channel: versionInfo.channel,
                dartVersion: versionInfo.dartVersion,
                engineRevision: versionInfo.engineRevision,
                frameworkRevision: versionInfo.frameworkRevision,
                doctorCategories: doctorCategories
            )
        } catch {
            if executable == toolchain.executable {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }

    private func resolveSDKPath(executable: String) async throws -> String {
        let output = try await processRunner.run(command: "which \(executable)")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveVersionInfo(executable: String) async throws -> VersionInfo {
        let command = "\(executable) --version --machine"
        let output = try await processRunner.run(command: command)
        guard let data = Self.jsonObjectData(in: output),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SDKInfoError.parsingFailed(command)
        }

        return VersionInfo(
            version: json["frameworkVersion"] as? String ?? "Unknown",
            channel: json["channel"] as? String ?? "Unknown",
            dartVersion: json["dartSdkVersion"] as? String ?? "Unknown",
            engineRevision: json["engineRevision"] as? String,
            frameworkRevision: json["frameworkRevision"] as? String
        )
    }

    private func resolveDoctor(executable: String) async throws -> [DoctorCategory] {
        let output = try await processRunner.run(command: "\(executable) doctor -v")
        return parseDoctorOutput(output)
    }

    /// `dn` can print update notices around the JSON, so parse only the outermost
    /// `{…}` block instead of the whole output.
    static func jsonObjectData(in output: String) -> Data? {
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}"),
              start < end else { return nil }
        return String(output[start...end]).data(using: .utf8)
    }

    private func parseDoctorOutput(_ output: String) -> [DoctorCategory] {
        var categories: [DoctorCategory] = []
        var currentStatus: DoctorStatus = .ok
        var currentName = ""
        var currentDetails: [String] = []

        func flushCategory() {
            guard !currentName.isEmpty else { return }
            categories.append(DoctorCategory(
                name: currentName,
                status: currentStatus,
                details: currentDetails
            ))
            currentName = ""
            currentDetails = []
        }

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[✓]") {
                flushCategory()
                currentStatus = .ok
                currentName = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("[✗]") {
                flushCategory()
                currentStatus = .error
                currentName = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("[!]") {
                flushCategory()
                currentStatus = .warning
                currentName = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("• ") {
                currentDetails.append(String(trimmed.dropFirst(2)))
            } else if trimmed.hasPrefix("✗ ") || trimmed.hasPrefix("! ") {
                currentDetails.append(trimmed)
            }
        }
        flushCategory()

        return categories
    }

    private struct VersionInfo {
        let version: String
        let channel: String
        let dartVersion: String
        let engineRevision: String?
        let frameworkRevision: String?
    }
}

enum SDKInfoError: LocalizedError {
    case parsingFailed(String)

    var errorDescription: String? {
        switch self {
        case let .parsingFailed(command):
            return "Could not parse output from \(command)"
        }
    }
}

protocol ProcessRunner {
    func run(command: String) async throws -> String
}

struct ShellProcessRunner: ProcessRunner {
    func run(command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-ic", command]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: stdoutData, encoding: .utf8) ?? ""
                let errorOutput = String(data: stderrData, encoding: .utf8) ?? ""

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let message = errorOutput.isEmpty ? output : errorOutput
                    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    let error: Error = NSError(
                        domain: "FlutterSDKInfo",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: trimmed.isEmpty ? "Unknown error running '\(command)'" : trimmed]
                    )
                    continuation.resume(throwing: error)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
