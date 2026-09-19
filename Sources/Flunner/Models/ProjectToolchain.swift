import Foundation

/// The SDK and CLI that drive a project.
///
/// DartNative's `dn` CLI is a fork of the Flutter tool: it speaks the same
/// `--machine` JSON protocol (`app.start`, `app.restart`, `app.stop`, …) and
/// accepts the same `run`, `pub`, `clean`, `doctor` and `build` commands. Only the
/// executable, the supported targets (iOS and Android) and a few tools differ.
enum ProjectToolchain: String, Codable, CaseIterable, Hashable, Sendable {
    case flutter
    case dartNative

    /// Executable Flunner invokes for this project, e.g. `flutter run` or `dn run`.
    var executable: String {
        switch self {
        case .flutter: "flutter"
        case .dartNative: "dn"
        }
    }

    var displayName: String {
        switch self {
        case .flutter: "Flutter"
        case .dartNative: "DartNative"
        }
    }

    /// Compact label for badges in dense lists.
    var shortLabel: String {
        switch self {
        case .flutter: "Flutter"
        case .dartNative: "DN"
        }
    }

    var docsURL: String {
        switch self {
        case .flutter: "https://docs.flutter.dev"
        case .dartNative: "https://dartnative.com/docs/"
        }
    }

    /// DartNative targets iOS and Android only; it has no web or desktop embedders
    /// and no widget previewer.
    var supportsWebAndDesktop: Bool { self == .flutter }
    var supportsWidgetPreviewer: Bool { self == .flutter }

    // MARK: - Detection

    /// Files that only a DartNative project has: `dn pub get` writes the lock file
    /// and generates the plugin registrant.
    static let dartNativeMarkerFiles = [
        "dn_plugins.lock",
        "lib/dartnative_plugin_registrant.dart",
    ]

    /// Detects the toolchain of the project at `projectPath`, or nil when the
    /// folder is neither a Flutter nor a DartNative project.
    static func detect(at projectPath: String, fileManager: FileManager = .default) -> ProjectToolchain? {
        let root = URL(fileURLWithPath: projectPath)
        let pubspecPath = root.appendingPathComponent("pubspec.yaml").path
        guard let pubspec = try? String(contentsOfFile: pubspecPath, encoding: .utf8) else { return nil }
        let hasMarkerFile = dartNativeMarkerFiles.contains {
            fileManager.fileExists(atPath: root.appendingPathComponent($0).path)
        }
        return detect(pubspec: pubspec, hasDartNativeMarkerFile: hasMarkerFile)
    }

    /// Classifies a pubspec. DartNative wins over Flutter because a DartNative
    /// project may still carry a `flutter:` section copied from a Flutter app.
    static func detect(pubspec: String, hasDartNativeMarkerFile: Bool = false) -> ProjectToolchain? {
        if hasDartNativeMarkerFile || pubspecDeclaresDartNative(pubspec) {
            return .dartNative
        }
        if pubspec.range(of: #"(?m)^\s*flutter\s*:"#, options: .regularExpression) != nil {
            return .flutter
        }
        return nil
    }

    /// True when the pubspec depends on `dartnative` / `dartnative_*` packages or has
    /// a top-level `dartnative:` section. Mirrors the check the `dn` launcher itself
    /// uses (`^[[:space:]]*dartnative`), restricted to YAML keys. Commented lines
    /// never match because `#` is not whitespace.
    static func pubspecDeclaresDartNative(_ pubspec: String) -> Bool {
        pubspec.range(
            of: #"(?m)^[ \t]*dartnative(_[A-Za-z0-9_]+)?[ \t]*:"#,
            options: .regularExpression
        ) != nil
    }
}
