import AppKit
import CryptoKit
import SwiftUI

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

@MainActor
final class AppUpdater: ObservableObject {
    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    static let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "开发版"
    @Published var showsPanel = false
    @Published var release: PublishedRelease?
    @Published var busy = false
    @Published var status = ""
    @Published var automatic = UserDefaults.standard.object(forKey: "automaticallyCheckUpdates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "automaticallyCheckUpdates") }
    }
    var mayRestart: () -> Bool = { false }
    private var started = false
    private var timer: Timer?
    static func isNewer(_ tag: String, than current: String) -> Bool {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil else { return false }
        return version.compare(current, options: .numeric) == .orderedDescending
    }
    var hasUpdate: Bool { release.map { Self.isNewer($0.tag_name, than: Self.currentVersion) } ?? false }
    func start() {
        guard !started else { return }; started = true
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
        if manual { showsPanel = true }
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
            if hasUpdate { showsPanel = true }
        } catch { status = "检查失败：\(error.localizedDescription)" }
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
            let previous = destination.deletingLastPathComponent().appendingPathComponent(".DECT-previous-\(UUID().uuidString).app")
            try manager.copyItem(at: candidate, to: staged)
            let script = root.appendingPathComponent("install.sh")
            let contents = """
            #!/bin/sh
            parent="$1"; destination="$2"; staged="$3"; previous="$4"
            count=0
            while /bin/kill -0 "$parent" 2>/dev/null; do
              count=$((count + 1))
              if [ "$count" -ge 120 ]; then exit 1; fi
              /bin/sleep 1
            done
            if /bin/mv "$destination" "$previous"; then
              if /bin/mv "$staged" "$destination"; then
                /usr/bin/open "$destination"
              else
                /bin/mv "$previous" "$destination"
                /usr/bin/open "$destination"
              fi
            fi
            """
            try contents.write(to: script, atomically: true, encoding: .utf8)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), destination.path, staged.path, previous.path]
            helper.standardInput = FileHandle.nullDevice; helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
            try helper.run(); handedOff = true
            status = "更新已就绪，正在重启…"
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
                Button("关闭") { updater.showsPanel = false }.disabled(updater.busy)
                Button("检查更新") { Task { await updater.check() } }.disabled(updater.busy)
                if updater.hasUpdate {
                    Button("安装并重启") { Task { await updater.install() } }.buttonStyle(.borderedProminent).disabled(updater.busy)
                }
            }
        }.padding(24).frame(width: 550)
    }
}
