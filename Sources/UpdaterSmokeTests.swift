#if SMOKE_TEST
import AppKit

enum UpdaterSmokeTests {
    @MainActor static func run() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DECT-Update-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Kept on failure to preserve diagnostic logs; no production application is touched.
        let destination = root.appendingPathComponent("测试 表格.app")
        let staged = root.appendingPathComponent("new.app")
        let previous = root.appendingPathComponent("previous.saved")
        let source = root.appendingPathComponent("Fixture.swift")
        try """
        import AppKit
        final class Delegate: NSObject, NSApplicationDelegate {
            func applicationDidFinishLaunching(_ notification: Notification) {
                let args = CommandLine.arguments
                if let i = args.firstIndex(of: "--test-install") {
                    let root = args[i + 1]
                    let helper = Process()
                    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
                    helper.arguments = [root + "/install.sh", String(ProcessInfo.processInfo.processIdentifier), root + "/测试 表格.app", root + "/new.app", root + "/previous.saved", root]
                    do { try helper.run() } catch { fatalError(String(describing: error)) }
                } else if let i = args.firstIndex(of: "--dect-update-complete") {
                    let text = Bundle.main.bundleURL.path + "|" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String)
                    try! text.write(toFile: args[i + 1] + "/launched", atomically: true, encoding: .utf8)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            }
        }
        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.run()
        """.write(to: source, atomically: true, encoding: .utf8)
        let binary = root.appendingPathComponent("Fixture")
        _ = try GridWorkbookIO.capture("/usr/bin/swiftc", [source.path, "-framework", "AppKit", "-o", binary.path])
        let identifier = "io.dect.updater-test." + UUID().uuidString.lowercased()
        for (url, version) in [(destination, "1.0.0"), (staged, "1.0.1")] {
            let contents = url.appendingPathComponent("Contents")
            try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try fm.copyItem(at: binary, to: contents.appendingPathComponent("MacOS/Fixture"))
            let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture",
                "CFBundleName": "DECT Update Test", "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": version, "LSUIElement": true]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            _ = try GridWorkbookIO.capture("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
        }
        try UpdateInstaller.script.write(to: root.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8)
        _ = try GridWorkbookIO.capture("/usr/bin/open", ["-n", "-a", destination.path, "--args", "--test-install", root.path])
        let receipt = root.appendingPathComponent("launched")
        for _ in 0..<200 {
            if fm.fileExists(atPath: receipt.path) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let confirmation = try? String(contentsOf: receipt, encoding: .utf8),
              confirmation.hasSuffix("|1.0.1"),
              URL(fileURLWithPath: String(confirmation.dropLast(6))).resolvingSymlinksInPath()
                == destination.resolvingSymlinksInPath() else {
            throw WorkspaceError(message: "实际更新重启失败，日志目录：\(root.path)")
        }
        try WorkspaceSmokeTests.require(fm.fileExists(atPath: previous.path), "旧版回退副本缺失")
        try WorkspaceSmokeTests.require(!fm.fileExists(atPath: staged.path), "新版未替换到目标位置")
        for _ in 0..<30 {
            let log = (try? String(contentsOf: root.appendingPathComponent("install.log"), encoding: .utf8)) ?? ""
            if log.contains("Restart confirmed") { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let log = try String(contentsOf: root.appendingPathComponent("install.log"), encoding: .utf8)
        try WorkspaceSmokeTests.require(log.contains("Restart confirmed"), "安装助手未收到启动确认")
        UpdateInstaller.acknowledgeLaunch(arguments: ["test", "--dect-update-complete", root.path])
        let realReceipt = try String(contentsOf: receipt, encoding: .utf8)
        try WorkspaceSmokeTests.require(realReceipt == Bundle.main.bundleURL.path, "正式启动回执未写入")
        print("真实更新链路通过：旧应用退出、替换、LaunchServices 启动新版、正确路径与版本回执；空格/中文路径通过。")
        print("仅使用独立测试应用，未关闭用户工具。")
        try fm.removeItem(at: root)
    }
}
#endif
