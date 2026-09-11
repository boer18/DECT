import Foundation

/// The part of a project layout that is needed by the table tool.
///
/// A Unity repository may keep its Luban configuration in a directory named
/// `Config`, `LubanConfig`, or another project-specific directory. The source
/// of truth for the table directory is `luban.conf.dataDir`, not the name of
/// the parent directory.
struct LubanProjectLayout: Hashable {
    let configurationRootURL: URL
    let dataRootURL: URL
    let generatorURL: URL
    let lubanConfigURL: URL
}

/// The runtime requested by a project's bundled Luban executable.
///
/// Some repositories carry an older Luban build than the .NET runtime currently
/// installed on the Mac. Keeping this information beside the project resolver
/// lets the exporter adapt the child process without rewriting the repository's
/// shell scripts.
struct LubanRuntimeInfo: Hashable {
    let configURL: URL
    let frameworkName: String
    let requestedVersion: String
    let requestedMajorVersion: Int

    var description: String { "\(frameworkName) \(requestedVersion)" }
}

enum ProjectConfigurationResolver {
    /// Supported Luban entrypoints, ordered from the most project-specific
    /// export command to the legacy default. Some projects keep `gen.sh` for
    /// a binary/runtime build while their Unity editor menu invokes
    /// `gen_plus.sh` for the checked-in JSON configuration. Choosing the
    /// canonical entrypoint prevents an export from changing the repository's
    /// entire generated-data format.
    static let supportedGeneratorNames = ["gen_plus.sh", "gen_for_command.sh", "gen.sh"]

    static func isSupportedGeneratorName(_ name: String) -> Bool {
        supportedGeneratorNames.contains {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    static func shouldPreferGenerator(_ candidate: URL, over current: URL) -> Bool {
        let candidateName = candidate.lastPathComponent.lowercased()
        let currentName = current.lastPathComponent.lowercased()
        let candidatePriority = supportedGeneratorNames.firstIndex(of: candidateName) ?? Int.max
        let currentPriority = supportedGeneratorNames.firstIndex(of: currentName) ?? Int.max
        if candidatePriority != currentPriority { return candidatePriority < currentPriority }
        return candidate.path.localizedStandardCompare(current.path) == .orderedAscending
    }

    static func preferredGeneratorURL(in configurationRoot: URL) -> URL? {
        let manager = FileManager.default
        for name in supportedGeneratorNames {
            let candidate = configurationRoot.appendingPathComponent(name, isDirectory: false).standardizedFileURL
            if manager.isReadableFile(atPath: candidate.path), layout(for: candidate) != nil {
                return candidate
            }
        }
        return nil
    }

    static func layout(for generatorURL: URL) -> LubanProjectLayout? {
        let generator = generatorURL.standardizedFileURL
        let configurationRoot = generator.deletingLastPathComponent().standardizedFileURL
        let lubanConfig = configurationRoot.appendingPathComponent("luban.conf", isDirectory: false)
        let manager = FileManager.default
        guard manager.isReadableFile(atPath: generator.path),
              manager.isReadableFile(atPath: lubanConfig.path),
              let dataDirectory = dataDirectory(from: lubanConfig)
        else { return nil }

        let dataRoot: URL
        if dataDirectory.hasPrefix("/") {
            dataRoot = URL(fileURLWithPath: dataDirectory, isDirectory: true).standardizedFileURL
        } else {
            dataRoot = configurationRoot.appendingPathComponent(dataDirectory, isDirectory: true).standardizedFileURL
        }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: dataRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return LubanProjectLayout(
            configurationRootURL: configurationRoot,
            dataRootURL: dataRoot,
            generatorURL: generator,
            lubanConfigURL: lubanConfig
        )
    }

    /// Reads the runtime requested by the Luban executable used by a generator.
    ///
    /// The common locations are checked first, followed by a bounded recursive
    /// lookup. The latter covers layouts such as TCR's `Luban/Tool` without
    /// assuming that every repository stores the executable in the same folder.
    static func lubanRuntimeInfo(for generatorURL: URL) -> LubanRuntimeInfo? {
        let manager = FileManager.default
        for runtimeURL in runtimeConfigCandidates(for: generatorURL) {
            guard manager.isReadableFile(atPath: runtimeURL.path),
                  let data = try? Data(contentsOf: runtimeURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let runtimeOptions = object["runtimeOptions"] as? [String: Any],
                  let framework = runtimeFramework(from: runtimeOptions),
                  let name = framework["name"] as? String,
                  let version = framework["version"] as? String,
                  let major = Int(version.split(separator: ".", maxSplits: 1).first ?? "")
            else { continue }
            return LubanRuntimeInfo(
                configURL: runtimeURL.standardizedFileURL,
                frameworkName: name,
                requestedVersion: version,
                requestedMajorVersion: major
            )
        }
        return nil
    }

    /// Returns process-only overrides for older Luban builds.
    ///
    /// .NET uses the exact requested major version when it is installed. When
    /// it is absent, `Major` permits a compatible newer runtime (for example a
    /// net7.0 Luban on a Mac with only net8.0 installed). Projects already
    /// targeting net8.0 or newer receive no override, preserving their existing
    /// execution behavior.
    static func dotnetEnvironmentOverrides(for generatorURL: URL) -> [String: String] {
        guard let runtime = lubanRuntimeInfo(for: generatorURL), runtime.requestedMajorVersion < 8 else {
            return [:]
        }
        return ["DOTNET_ROLL_FORWARD": "Major"]
    }

    /// Finds the main `TbLanguage.xlsx` without mistaking framework/story
    /// localization workbooks for the project's primary language table.
    static func languageWorkbookURL(in project: ExportProject) -> URL? {
        let manager = FileManager.default
        let direct = project.dataRootURL.appendingPathComponent("TbLanguage.xlsx", isDirectory: false)
        if manager.isReadableFile(atPath: direct.path) { return direct.standardizedFileURL }

        guard let enumerator = manager.enumerator(
            at: project.dataRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        let matches = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  url.lastPathComponent.caseInsensitiveCompare("TbLanguage.xlsx") == .orderedSame,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            return url.standardizedFileURL
        }
        return matches.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }.first
    }

    /// Returns the closest repository root containing `.git`. This is used for
    /// display and history lookup when configuration and Unity roots are
    /// nested below a repository root (for example TCR/trunk/LubanConfig).
    static func nearestRepositoryRoot(from url: URL) -> URL? {
        let manager = FileManager.default
        var cursor = url.standardizedFileURL
        while cursor.pathComponents.count > 1 {
            var isDirectory: ObjCBool = false
            let gitURL = cursor.appendingPathComponent(".git", isDirectory: false)
            if manager.fileExists(atPath: gitURL.path, isDirectory: &isDirectory) {
                return cursor
            }
            let parent = cursor.deletingLastPathComponent().standardizedFileURL
            if parent == cursor { break }
            cursor = parent
        }
        return nil
    }

    private static func dataDirectory(from fileURL: URL) -> String? {
        guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }

        // Luban accepts JSON-like configuration files and existing projects in
        // the workspace use both strict JSON and trailing-comma JSON. Prefer a
        // real JSON decode, then fall back to the small field we need so old
        // configurations remain discoverable.
        if let data = source.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object["dataDir"] as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let pattern = #"(?m)[\"']dataDir[\"']\s*:\s*[\"']([^\"']+)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source)
        else { return nil }
        let value = String(source[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func runtimeConfigCandidates(for generatorURL: URL) -> [URL] {
        let configurationRoot = generatorURL.standardizedFileURL.deletingLastPathComponent()
        var candidates = [
            configurationRoot.appendingPathComponent("Luban/Luban.runtimeconfig.json", isDirectory: false),
            configurationRoot.appendingPathComponent("Luban/Tool/Luban.runtimeconfig.json", isDirectory: false)
        ]

        if let enumerator = FileManager.default.enumerator(
            at: configurationRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let itemURL as URL in enumerator {
                guard itemURL.lastPathComponent.caseInsensitiveCompare("Luban.runtimeconfig.json") == .orderedSame,
                      (try? itemURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { continue }
                candidates.append(itemURL.standardizedFileURL)
            }
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func runtimeFramework(from runtimeOptions: [String: Any]) -> [String: Any]? {
        if let framework = runtimeOptions["framework"] as? [String: Any] {
            return framework
        }
        if let frameworks = runtimeOptions["frameworks"] as? [[String: Any]] {
            return frameworks.first
        }
        return nil
    }
}
