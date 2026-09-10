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

enum ProjectConfigurationResolver {
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
}
