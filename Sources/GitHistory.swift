import Foundation

enum ComparisonSourceMode: String, CaseIterable, Identifiable {
    case folders = "文件夹对比"
    case gitHistory = "Git 历史对比"

    var id: String { rawValue }
}

enum GitCommitSelectionMode: String, CaseIterable, Identifiable {
    case commit = "按提交"
    case date = "按时间"

    var id: String { rawValue }
}

struct GitBranch: Identifiable, Hashable {
    let name: String
    let isCurrent: Bool

    var id: String { name }
    var label: String { isCurrent ? "\(name)（当前）" : name }
}

struct GitCommit: Identifiable, Hashable {
    let hash: String
    let shortHash: String
    let date: Date
    let dateText: String
    let subject: String

    var id: String { hash }
}

struct GitRepositoryInfo: Hashable {
    let repositoryRoot: URL
    let projectRoot: URL
    let dataRelativePath: String
    let currentBranch: String?

    var currentDataRoot: URL {
        projectRoot.appendingPathComponent("Config/Datas", isDirectory: true).standardizedFileURL
    }
}

struct GitHistorySnapshot {
    let rootURL: URL
    let dataRoot: URL
    let commitHash: String
}

struct GitHistoryError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum GitHistoryProvider {
    private static let gitPath = "/usr/bin/git"
    private static let tarPath = "/usr/bin/tar"
    private static let fieldSeparator: Character = "\u{1F}"
    private static let branchFieldSeparator: Character = "\t"

    static func discover(projectURL: URL) throws -> GitRepositoryInfo {
        let projectRoot = projectURL.resolvingSymlinksInPath().standardizedFileURL
        let repositoryPath = try output([
            "-C", projectRoot.path,
            "rev-parse", "--show-toplevel"
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repositoryPath.isEmpty else {
            throw GitHistoryError(message: "当前项目不在 Git 工作区中。")
        }

        let repositoryRoot = URL(fileURLWithPath: repositoryPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard let relativeProjectPath = relativePath(from: repositoryRoot, to: projectRoot) else {
            throw GitHistoryError(message: "Git 仓库根目录与当前项目路径不一致。")
        }
        let dataRelativePath = [relativeProjectPath, "Config", "Datas"]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        guard FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("Config/Datas").path) else {
            throw GitHistoryError(message: "当前项目没有 Config/Datas 配置表目录。")
        }

        let branchOutput = try? output([
            "-C", repositoryRoot.path,
            "branch", "--show-current"
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        let currentBranch = branchOutput?.isEmpty == false ? branchOutput : nil
        return GitRepositoryInfo(
            repositoryRoot: repositoryRoot,
            projectRoot: projectRoot,
            dataRelativePath: dataRelativePath,
            currentBranch: currentBranch
        )
    }

    static func branches(repository: GitRepositoryInfo) throws -> [GitBranch] {
        let data = try capture([
            "-C", repository.repositoryRoot.path,
            "for-each-ref",
            "--format=%(refname:short)\t%(HEAD)",
            "refs/heads", "refs/remotes"
        ])
        var seen = Set<String>()
        var result: [GitBranch] = []
        for line in lines(data) {
            let fields = line.split(separator: branchFieldSeparator, maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = fields.first else { continue }
            let name = String(rawName).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.hasSuffix("/HEAD"), seen.insert(name).inserted else { continue }
            let marker = fields.count > 1 ? String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            result.append(GitBranch(name: name, isCurrent: marker == "*" || name == repository.currentBranch))
        }
        return result.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func commits(repository: GitRepositoryInfo, reference: String) throws -> [GitCommit] {
        let data = try capture([
            "-C", repository.repositoryRoot.path,
            "log",
            "--date=iso-strict",
            "--pretty=format:%H%x1f%h%x1f%ad%x1f%s",
            reference,
            "--", repository.dataRelativePath
        ])
        return lines(data).compactMap { line in
            let fields = line.split(separator: fieldSeparator, maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4 else { return nil }
            let hash = String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let shortHash = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let dateText = String(fields[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = String(fields[3]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hash.isEmpty, let date = parseDate(dateText) else { return nil }
            return GitCommit(hash: hash, shortHash: shortHash, date: date, dateText: dateText, subject: subject)
        }
    }

    static func materializeSnapshot(repository: GitRepositoryInfo, commit: GitCommit) throws -> GitHistorySnapshot {
        let resolvedHash = try resolveCommit(repository: repository, revision: commit.hash)
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("OneClickTableExport-git-\(UUID().uuidString)", isDirectory: true)
        let dataRoot = root.appendingPathComponent(repository.dataRelativePath, isDirectory: true)
        try manager.createDirectory(at: dataRoot, withIntermediateDirectories: true)

        let archivePipe = Pipe()
        let archiveError = Pipe()
        let extractError = Pipe()
        let archive = Process()
        archive.executableURL = URL(fileURLWithPath: gitPath)
        archive.arguments = [
            "-C", repository.repositoryRoot.path,
            "archive", "--format=tar", resolvedHash,
            "--", repository.dataRelativePath
        ]
        archive.standardOutput = archivePipe
        archive.standardError = archiveError

        let extractor = Process()
        extractor.executableURL = URL(fileURLWithPath: tarPath)
        extractor.arguments = ["-xf", "-", "-C", root.path]
        extractor.standardInput = archivePipe
        extractor.standardOutput = FileHandle.nullDevice
        extractor.standardError = extractError

        do {
            try extractor.run()
            try archive.run()
        } catch {
            if archive.isRunning { archive.terminate() }
            if extractor.isRunning { extractor.terminate() }
            archivePipe.fileHandleForWriting.closeFile()
            try? manager.removeItem(at: root)
            throw GitHistoryError(message: "无法读取 Git 历史配置表：\(error.localizedDescription)")
        }

        archive.waitUntilExit()
        archivePipe.fileHandleForWriting.closeFile()
        extractor.waitUntilExit()
        let archiveDetails = String(decoding: archiveError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let extractDetails = String(decoding: extractError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard archive.terminationStatus == 0 else {
            try? manager.removeItem(at: root)
            throw GitHistoryError(message: "Git 历史配置表读取失败：\(archiveDetails.isEmpty ? "无法创建历史快照" : archiveDetails)")
        }
        guard extractor.terminationStatus == 0 else {
            try? manager.removeItem(at: root)
            throw GitHistoryError(message: "历史配置表解包失败：\(extractDetails.isEmpty ? "tar 执行失败" : extractDetails)")
        }
        return GitHistorySnapshot(rootURL: root, dataRoot: dataRoot, commitHash: resolvedHash)
    }

    static func removeSnapshot(at root: URL?) {
        guard let root else { return }
        try? FileManager.default.removeItem(at: root)
    }

    private static func resolveCommit(repository: GitRepositoryInfo, revision: String) throws -> String {
        let resolved = try output([
            "-C", repository.repositoryRoot.path,
            "rev-parse", "--verify", "\(revision)^{commit}"
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolved.count == 40,
              resolved.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else {
            throw GitHistoryError(message: "无法解析所选 Git 提交。")
        }
        return resolved
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTime]
        return formatter.date(from: text)
    }

    private static func relativePath(from base: URL, to target: URL) -> String? {
        let baseComponents = base.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        guard targetComponents.count >= baseComponents.count,
              Array(targetComponents.prefix(baseComponents.count)) == baseComponents else { return nil }
        return targetComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }

    private static func output(_ arguments: [String]) throws -> String {
        String(decoding: try capture(arguments), as: UTF8.self)
    }

    private static func capture(_ arguments: [String]) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: gitPath) else {
            throw GitHistoryError(message: "找不到 Git 命令。请确认已安装 Xcode Command Line Tools。")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        do {
            try process.run()
        } catch {
            throw GitHistoryError(message: "无法启动 Git：\(error.localizedDescription)")
        }
        let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitHistoryError(message: details.isEmpty ? "Git 命令执行失败。" : details)
        }
        return data
    }

    private static func lines(_ data: Data) -> [Substring] {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
    }
}
