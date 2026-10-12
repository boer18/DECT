#if SMOKE_TEST
import Foundation

@MainActor
enum FrameworkExportSmokeTests {
    static func run(_ roots: [String]) throws {
        for path in roots {
            let root = URL(fileURLWithPath: path)
            let config = root.appendingPathComponent("Config")
            let project = ExportProject(rootURL: root, configurationRootURL: config,
                dataRootURL: config.appendingPathComponent("Datas"), generatorURL: config.appendingPathComponent("gen.sh"), displayPath: root.lastPathComponent)
            guard let layout = ProjectConfigurationResolver.frameworkLayout(in: project) else {
                throw WorkspaceError(message: "真实工程的框架脚本或配置不可用：\(root.lastPathComponent)")
            }
            try require(layout.generatorURL.lastPathComponent == "gen_framework.sh" &&
                layout.lubanConfigURL.lastPathComponent == "luban_framework.conf" &&
                layout.dataRootURL.lastPathComponent == "FrameWork" && ProjectConfigurationResolver.hasFrameworkTables(in: project),
                "真实工程的框架入口或数据目录识别错误")
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("FrameworkExport-smoke-\(UUID().uuidString)")
        let config = root.appendingPathComponent("Config")
        let data = config.appendingPathComponent("Datas")
        let frameRoot = data.appendingPathComponent("FrameWork")
        let gameScript = config.appendingPathComponent("gen.sh")
        let frameScript = config.appendingPathComponent("gen_framework.sh")
        let frameConfig = config.appendingPathComponent("luban_framework.conf")
        let suite = "io.centurygames.one-click-table-export.framework-export-smoke-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        try manager.createDirectory(at: frameRoot, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? manager.removeItem(at: root) }
        try "{\"dataDir\":\"Datas\"}".write(to: config.appendingPathComponent("luban.conf"), atomically: true, encoding: .utf8)
        try "{\"dataDir\":\"Datas/FrameWork\"}".write(to: frameConfig, atomically: true, encoding: .utf8)
        let workbook = frameRoot.appendingPathComponent("TbFrameLanguage.xlsx")
        guard let source = roots.first else { throw WorkspaceError(message: "需要一个工程根目录") }
        try manager.copyItem(at: URL(fileURLWithPath: source).appendingPathComponent("Config/Datas/FrameWork/TbFrameLanguage.xlsx"), to: workbook)
        try "#!/bin/bash\nprintf GAME > game.marker\nprintf 'GAME SCRIPT\\n'\n".write(to: gameScript, atomically: true, encoding: .utf8)
        try "#!/bin/bash\nsleep 0.1\nprintf FRAMEWORK > frame.marker\nprintf 'FRAMEWORK SCRIPT ROLL_FORWARD=%s\\n' \"$DOTNET_ROLL_FORWARD\"\n".write(to: frameScript, atomically: true, encoding: .utf8)
        let runtime = config.appendingPathComponent("Luban/Luban.runtimeconfig.json")
        try manager.createDirectory(at: runtime.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"runtimeOptions\":{\"framework\":{\"name\":\"Microsoft.NETCore.App\",\"version\":\"7.0.0\"}}}".write(to: runtime, atomically: true, encoding: .utf8)
        let project = ExportProject(rootURL: root, configurationRootURL: config, dataRootURL: data, generatorURL: gameScript, displayPath: "fixture")
        let exporter = ExportViewModel(defaults: defaults)
        func waitUntil(_ condition: () -> Bool) throws {
            let deadline = Date(timeIntervalSinceNow: 8)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
            try require(condition(), "框架导表验证超时")
        }
        exporter.export(project: project, kind: .framework)
        exporter.export(project: project) // A second export must be blocked while busy.
        try waitUntil { !exporter.isExporting }
        let frameMarker = try String(contentsOf: config.appendingPathComponent("frame.marker"), encoding: .utf8)
        try require(frameMarker == "FRAMEWORK" && !manager.fileExists(atPath: config.appendingPathComponent("game.marker").path) &&
            exporter.log.contains("ROLL_FORWARD=Major") && exporter.log.contains("框架表导出完成") &&
            exporter.log.contains(frameConfig.path), "框架脚本、工作目录、运行时覆盖或并发保护错误")
        exporter.export(project: project); try waitUntil { !exporter.isExporting }
        let gameMarker = try String(contentsOf: config.appendingPathComponent("game.marker"), encoding: .utf8)
        try require(gameMarker == "GAME" && exporter.log.contains("GAME SCRIPT"), "普通导表入口被改变")
        try "#!/bin/bash\nprintf 'FRAMEWORK FAILURE\\n'\nexit 9\n".write(to: frameScript, atomically: true, encoding: .utf8)
        exporter.export(project: project, kind: .framework); try waitUntil { !exporter.isExporting }
        try require(exporter.log.contains("FRAMEWORK FAILURE") && exporter.log.contains("退出代码 9"), "框架失败日志或退出代码未保留")
        try manager.removeItem(at: frameScript)
        exporter.export(project: project, kind: .framework)
        try require(!exporter.isExporting && exporter.log.contains("无法导出框架表") && exporter.log.contains("未执行普通导表脚本") &&
            ProjectConfigurationResolver.hasFrameworkTables(in: project), "缺失框架脚本时未拒绝导出或错误回退到普通脚本")
        let preferred = ProjectConfigurationResolver.preferredGeneratorURL(in: config)
        try require(preferred == gameScript && !ProjectConfigurationResolver.isSupportedGeneratorName("gen_framework.sh"),
            "框架脚本被误当成普通项目入口")

        let mainBook = data.appendingPathComponent("TbLanguage.xlsx")
        try manager.copyItem(at: workbook, to: mainBook)
        let untouchedMain = try Data(contentsOf: mainBook)
        let workspace = TableWorkspaceModel()
        let mainTable = ProjectTable(projectID: project.id, projectDisplayPath: "fixture", fileURL: mainBook,
            relativeDataPath: "TbLanguage.xlsx", byteCount: 0, modifiedAt: nil)
        let frameTable = ProjectTable(projectID: project.id, projectDisplayPath: "fixture", fileURL: workbook,
            relativeDataPath: "FrameWork/TbFrameLanguage.xlsx", byteCount: 0, modifiedAt: nil)
        workspace.open(mainTable); workspace.open(frameTable)
        try waitUntil { !workspace.isBusy }
        let mainEditor = workspace.editor(mainTable.id)!, frameEditor = workspace.editor(frameTable.id)!
        mainEditor.edit([GridAddress(row: 2, column: 2): "main unsaved"])
        frameEditor.edit([GridAddress(row: 2, column: 2): "framework saved"])
        var saved = false
        workspace.saveProject(project, dataRoot: frameRoot) { saved = true }
        try waitUntil { saved }
        let actualMain = try Data(contentsOf: mainBook)
        try require(mainEditor.hasPendingChanges && !frameEditor.hasPendingChanges && actualMain == untouchedMain,
            "框架导出前保存越过框架目录或丢失主表未保存编辑")
        try require(LanguageWorkbookKind.framework.exportKind == .framework && LanguageWorkbookKind.main.exportKind == .game,
            "框架多语言导出路由错误")
        print("框架导表：真实工程入口只读识别、临时脚本选择/工作目录/退出码、并发保护、旧运行时隔离、缺失脚本拒绝回退、普通入口保留及框架目录定向保存通过；未执行真实工程脚本。")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw WorkspaceError(message: message) }
    }
}
#endif
