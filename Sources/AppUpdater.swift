import AppKit
import CryptoKit
import SwiftUI

enum UpdateInstaller {
    private(set) static var didLaunchAfterUpdate = false

    // Arguments, never interpolated shell source, carry all user-controlled paths.
    static let script = """
    #!/bin/sh
    parent="$1"; destination="$2"; staged="$3"; previous="$4"; root="$5"
    exec >>"$root/install.log" 2>&1
    echo "Waiting for application exit"
    touch "$root/ready"
    count=0
    while /bin/kill -0 "$parent" 2>/dev/null; do
      count=$((count + 1))
      if [ "$count" -ge 120 ]; then
        echo "Cancelled: application did not exit; no files replaced"
        exit 1
      fi
      /bin/sleep 1
    done
    if ! /bin/mv "$destination" "$previous"; then
      echo "Failed to preserve previous application"
      /usr/bin/open -a TextEdit "$root/install.log"
      exit 1
    fi
    if ! /bin/mv "$staged" "$destination"; then
      echo "Replacement failed; restoring previous application"
      /bin/mv "$previous" "$destination"
      /usr/bin/open -n -a "$destination"
      /usr/bin/open -a TextEdit "$root/install.log"
      exit 1
    fi
    echo "Installed; launching explicit new application instance"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"
    if ! /usr/bin/open -n -a "$destination" --args --dect-update-complete "$root"; then
      echo "Launch failed. Please open the application manually."
      /usr/bin/open -a TextEdit "$root/install.log"
      exit 1
    fi
    count=0
    while [ ! -f "$root/launched" ]; do
      count=$((count + 1))
      if [ "$count" -ge 30 ]; then
        echo "No startup confirmation. Please open the application manually."
        /usr/bin/open -a TextEdit "$root/install.log"
        exit 1
      fi
      /bin/sleep 1
    done
    echo "Restart confirmed"
    """

    @discardableResult
    static func acknowledgeLaunch(arguments args: [String] = CommandLine.arguments) -> Bool {
        didLaunchAfterUpdate = false
        guard let index = args.firstIndex(of: "--dect-update-complete"), index + 1 < args.count else { return false }
        let root = URL(fileURLWithPath: args[index + 1]).standardizedFileURL
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard root.deletingLastPathComponent().resolvingSymlinksInPath() == temp,
              root.lastPathComponent.hasPrefix("DECT-Update-"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) else { return false }
        try? Bundle.main.bundleURL.path.write(to: root.appendingPathComponent("launched"), atomically: true, encoding: .utf8)
        didLaunchAfterUpdate = true
        return true
    }
}

struct PublishedRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let digest: String?
        let size: Int
    }
    let tag_name: String
    let body: String?
    let html_url: URL
    let assets: [Asset]
    let prerelease: Bool
    let draft: Bool
}

struct ReleaseNoteSection: Identifiable {
    let id: String
    let version: String
    let releaseURL: URL
    let items: [String]
}

@MainActor
final class AppUpdater: ObservableObject {
    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    static let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "开发版"
    private static let lastSeenVersionKey = "appUpdater.lastSeenVersion"
    private static let pendingReleaseNotesFromKey = "appUpdater.pendingReleaseNotesFrom"
    private static let acknowledgedReleaseNotesVersionKey = "appUpdater.acknowledgedReleaseNotesVersion"
    // The previous shipped build predates launch-version tracking. The
    // installer passes a completion argument, so the first upgraded build can
    // still show its notes even when the old app has no stored version.
    private static let previousShippedVersion = "1.8.11"
    @Published var showsPanel = false
    @Published var showsReleaseNotes = false
    @Published var release: PublishedRelease?
    @Published private(set) var releaseNotes: [ReleaseNoteSection] = []
    @Published private(set) var releaseNotesLoading = false
    @Published private(set) var releaseNotesStatus = ""
    @Published var busy = false
    @Published var status = ""
    @Published var automatic = UserDefaults.standard.object(forKey: "automaticallyCheckUpdates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "automaticallyCheckUpdates") }
    }
    var mayRestart: () -> Bool = { false }
    private var started = false
    private var timer: Timer?
    private let launchNotesFromVersion: String?

    init() {
        let defaults = UserDefaults.standard
        let acknowledged = defaults.string(forKey: Self.acknowledgedReleaseNotesVersionKey)
        let storedPrevious = defaults.string(forKey: Self.lastSeenVersionKey)
        let handoffPrevious = UpdateInstaller.didLaunchAfterUpdate ? Self.previousShippedVersion : nil
        let pendingPrevious = defaults.string(forKey: Self.pendingReleaseNotesFromKey)
        let candidate = pendingPrevious ?? storedPrevious ?? handoffPrevious
        if let candidate,
           candidate != Self.currentVersion,
           Self.isNewer(Self.currentVersion, than: candidate),
           acknowledged != Self.currentVersion {
            launchNotesFromVersion = candidate
            defaults.set(candidate, forKey: Self.pendingReleaseNotesFromKey)
        } else {
            launchNotesFromVersion = nil
        }
        defaults.set(Self.currentVersion, forKey: Self.lastSeenVersionKey)
    }

    var releaseNotesRangeDescription: String {
        if let launchNotesFromVersion {
            return "v\(launchNotesFromVersion) → v\(Self.currentVersion)"
        }
        return "当前版本 v\(Self.currentVersion)"
    }

    var shouldPresentReleaseNotesOnLaunch: Bool { launchNotesFromVersion != nil }

    static func isNewer(_ tag: String, than current: String) -> Bool {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil else { return false }
        return version.compare(current, options: .numeric) == .orderedDescending
    }
    var hasUpdate: Bool { release.map { Self.isNewer($0.tag_name, than: Self.currentVersion) } ?? false }
    func start() {
        guard !started else { return }; started = true
        if shouldPresentReleaseNotesOnLaunch {
            showReleaseNotes()
        }
        if automatic { Task { await check(manual: false) } }
        timer = Timer.scheduledTimer(withTimeInterval: 14400, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.automatic else { return }
                await self.check(manual: false)
            }
        }
    }
    func check(manual: Bool = true) async {
        guard !busy else { if manual { showsPanel = true }; return }
        busy = true; status = "正在检查更新…"
        if manual && !showsReleaseNotes { showsPanel = true }
        defer { busy = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/boer18/DECT/releases/latest")!)
            request.timeoutInterval = 25
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("DECT-Updater", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw WorkspaceError(message: "暂时无法访问 GitHub，请稍后重试或前往发布页下载。")
            }
            let value = try JSONDecoder().decode(PublishedRelease.self, from: data)
            guard !value.draft, !value.prerelease else { return }
            release = value
            status = hasUpdate ? "发现新版本，可查看更新说明后安装。" : "当前已是最新版本。"
            if hasUpdate && !showsReleaseNotes { showsPanel = true }
        } catch { status = "检查失败：\(error.localizedDescription)" }
    }

    func showReleaseNotes() {
        showsPanel = false
        showsReleaseNotes = true
        if releaseNotes.isEmpty && !releaseNotesLoading {
            Task { await loadReleaseNotes() }
        }
    }

    func dismissReleaseNotes() {
        showsReleaseNotes = false
        UserDefaults.standard.set(Self.currentVersion, forKey: Self.acknowledgedReleaseNotesVersionKey)
        UserDefaults.standard.removeObject(forKey: Self.pendingReleaseNotesFromKey)
    }

    private func loadReleaseNotes() async {
        guard !releaseNotesLoading else { return }
        releaseNotesLoading = true
        releaseNotesStatus = "正在读取版本更新说明…"
        defer { releaseNotesLoading = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/boer18/DECT/releases?per_page=100")!)
            request.timeoutInterval = 25
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("DECT-Updater", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw WorkspaceError(message: "暂时无法读取 GitHub 版本说明。")
            }
            let releases = try JSONDecoder().decode([PublishedRelease].self, from: data)
            let fromVersion = launchNotesFromVersion ?? Self.currentVersion
            var sections = Self.releaseNoteSections(from: fromVersion, through: Self.currentVersion, releases: releases)
            if sections.isEmpty,
               let currentRelease = releases.first(where: {
                   Self.normalizedVersion($0.tag_name) == Self.currentVersion && !$0.draft && !$0.prerelease
               }) {
                sections = Self.releaseNoteSections(from: "0.0.0", through: Self.currentVersion, releases: [currentRelease])
            }
            if sections.isEmpty, let release {
                sections = Self.releaseNoteSections(from: "0.0.0", through: Self.currentVersion, releases: [release])
            }
            releaseNotes = sections
            releaseNotesStatus = sections.isEmpty ? "当前版本没有可读取的逐条更新说明。" : "共 \(sections.count) 个版本的更新内容"
        } catch {
            releaseNotesStatus = "读取失败：\(error.localizedDescription)"
        }
    }

    static func normalizedVersion(_ tag: String) -> String? {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) == nil ? nil : version
    }

    static func releaseNoteSections(from previous: String,
                                    through current: String,
                                    releases: [PublishedRelease]) -> [ReleaseNoteSection] {
        releases.compactMap { release in
            guard let version = normalizedVersion(release.tag_name),
                  !release.draft,
                  !release.prerelease,
                  isNewer(version, than: previous),
                  !isNewer(version, than: current)
            else { return nil }
            let items = conciseReleaseItems(from: release.body)
            guard !items.isEmpty else { return nil }
            return ReleaseNoteSection(id: version, version: version, releaseURL: release.html_url, items: items)
        }
        .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    static func conciseReleaseItems(from body: String?) -> [String] {
        guard let body else { return [] }
        let lines = body.components(separatedBy: .newlines)
        let bulletPattern = try? NSRegularExpression(pattern: #"^(?:[-*•]|[0-9]+[.)])\s+"#)
        var bulletItems: [String] = []
        var proseItems: [String] = []
        for raw in lines {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  !line.hasPrefix("#"),
                  !line.hasPrefix("<!--"),
                  !line.hasPrefix("Full Changelog") else { continue }
            var isBullet = false
            if let bulletPattern,
               let match = bulletPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                isBullet = true
                let prefixEnd = line.index(line.startIndex, offsetBy: match.range.length)
                line = String(line[prefixEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
            guard !line.isEmpty else { continue }
            if isBullet {
                bulletItems.append(line)
            } else if bulletItems.isEmpty {
                proseItems.append(line)
            }
        }
        var items = bulletItems.isEmpty ? proseItems : bulletItems
        if items.isEmpty {
            items = body.components(separatedBy: "\n\n")
                .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        var unique: [String] = []
        var seen = Set<String>()
        for item in items where seen.insert(item).inserted { unique.append(item) }
        return unique
    }
    func install() async {
        guard !busy, hasUpdate, let release else { return }
        guard mayRestart() else { status = "请先保存表格和多语言修改，并等待导表、翻译及对比任务完成，再安装更新。"; return }
        guard let asset = release.assets.first(where: { $0.name == "DECT-macOS-arm64.zip" }),
              asset.browser_download_url.scheme == "https",
              asset.browser_download_url.host == "github.com",
              asset.browser_download_url.path.hasPrefix("/boer18/DECT/releases/download/"),
              let digest = asset.digest, digest.hasPrefix("sha256:"), asset.size > 0, asset.size < 200_000_000 else {
            status = "此版本缺少可校验的 Mac 安装包，请前往发布页下载。"; return
        }
        let destination = Bundle.main.bundleURL.standardizedFileURL
        guard destination.pathExtension == "app", FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            status = "请将应用移到可写的“应用程序”目录后重试，或手动下载更新。"; return
        }
        busy = true; status = "正在下载更新，请稍候…"
        defer { busy = false }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("DECT-Update-\(UUID().uuidString)")
        var handedOff = false
        defer { if !handedOff { try? manager.removeItem(at: root) } }
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            var request = URLRequest(url: asset.browser_download_url); request.timeoutInterval = 180
            let (temporary, response) = try await URLSession.shared.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WorkspaceError(message: "下载失败，请重试。") }
            let archive = root.appendingPathComponent("update.zip")
            try manager.moveItem(at: temporary, to: archive)
            let expected = String(digest.dropFirst(7)).lowercased()
            let expectedVersion = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            status = "正在校验安装包…"
            let candidate = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: archive)
                let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard data.count == asset.size, actual == expected else { throw WorkspaceError(message: "安装包校验失败，未修改当前应用。") }
                let entries = String(decoding: try GridWorkbookIO.capture("/usr/bin/unzip", ["-Z1", archive.path]), as: UTF8.self)
                guard entries.split(separator: "\n").allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else {
                    throw WorkspaceError(message: "安装包包含无效路径。")
                }
                let unpacked = root.appendingPathComponent("unpacked")
                _ = try GridWorkbookIO.capture("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
                let app = unpacked.appendingPathComponent("表格工具.app")
                guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "io.centurygames.one-click-table-export",
                      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion else {
                    throw WorkspaceError(message: "应用标识或版本不匹配。")
                }
                _ = try GridWorkbookIO.capture("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
                return app
            }.value
            guard mayRestart() else { status = "下载完成，但当前有未保存内容或任务。请处理完成后再次安装。"; return }
            // Stage on the destination volume so replacement is a rename.
            let staged = destination.deletingLastPathComponent().appendingPathComponent(".DECT-update-\(UUID().uuidString).app")
            let previous = destination.deletingLastPathComponent().appendingPathComponent(".DECT-previous-\(UUID().uuidString).backup")
            try manager.copyItem(at: candidate, to: staged)
            let script = root.appendingPathComponent("install.sh")
            try UpdateInstaller.script.write(to: script, atomically: true, encoding: .utf8)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), destination.path, staged.path, previous.path, root.path]
            helper.standardInput = FileHandle.nullDevice; helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
            try helper.run()
            for _ in 0..<40 {
                if manager.fileExists(atPath: root.appendingPathComponent("ready").path) { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard helper.isRunning, manager.fileExists(atPath: root.appendingPathComponent("ready").path) else {
                if helper.isRunning { helper.terminate() }
                throw WorkspaceError(message: "无法启动安装助手，应用未退出。")
            }
            guard mayRestart() else {
                helper.terminate()
                status = "当前出现未保存内容或任务，安装已取消，请处理完成后重试。"
                return
            }
            handedOff = true
            status = "更新已就绪，正在重启…"
            // updater.busy remains true until this task exits, but it is not
            // unsaved user work. Mark the intentional update handoff before
            // asking AppKit to terminate so the normal quit guard cannot
            // deadlock the installer while it waits for this process.
            WorkspaceApplicationDelegate.isTerminatingForUpdate = true
            NSApp.terminate(nil)
        } catch { status = "更新失败：\(error.localizedDescription)。可重试或前往发布页下载。" }
    }
}

struct AppUpdatePanel: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(updater.hasUpdate ? "发现新版本" : "表格工具 · 版本与更新").font(.title2.bold())
            Text("当前版本 \(AppUpdater.currentVersion) · Build \(AppUpdater.currentBuild)").foregroundStyle(.secondary)
            if let release = updater.release {
                Text("最新发布：\(release.tag_name)").font(.headline)
                ScrollView { Text(release.body ?? "本版本未提供更新说明。").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(minHeight: 160, maxHeight: 260)
            }
            Toggle("自动检查更新（启动时及每 4 小时）", isOn: $updater.automatic)
            HStack { if updater.busy { ProgressView().controlSize(.small) }; Text(updater.status).font(.callout) }
            HStack {
                Link("发布页", destination: URL(string: "https://github.com/boer18/DECT/releases")!)
                Spacer()
                Button("本次更新说明") { updater.showReleaseNotes() }
                Button("关闭") { updater.showsPanel = false }.disabled(updater.busy)
                Button("检查更新") { Task { await updater.check() } }.disabled(updater.busy)
                if updater.hasUpdate {
                    Button("安装并重启") { Task { await updater.install() } }.buttonStyle(.borderedProminent).disabled(updater.busy)
                }
            }
        }.padding(24).frame(width: 550)
    }
}

struct AppReleaseNotesPanel: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("功能与 Bug 更新说明").font(.title2.bold())
                    Text(updater.releaseNotesRangeDescription).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("知道了") { updater.dismissReleaseNotes() }
            }
            Divider()
            if updater.releaseNotesLoading && updater.releaseNotes.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("正在读取更新说明…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 30)
            } else if updater.releaseNotes.isEmpty {
                ContentUnavailableView("暂时没有更新条目", systemImage: "doc.text.magnifyingglass",
                                       description: Text(updater.releaseNotesStatus))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(updater.releaseNotes) { section in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text("v\(section.version)").font(.headline.monospacedDigit())
                                    Spacer()
                                    Link("查看发布页", destination: section.releaseURL)
                                        .font(.caption)
                                }
                                ForEach(section.items, id: \.self) { item in
                                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                        Text(item).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .padding(14)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !updater.releaseNotesStatus.isEmpty && !updater.releaseNotes.isEmpty {
                Text(updater.releaseNotesStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 620, height: 520)
    }
}
