#if SMOKE_TEST
import Foundation

@MainActor
enum LanguageWorkbookSmokeTests {
    static func run(_ sources: [String]) throws {
        guard let source = sources.first else { throw WorkspaceError(message: "需要一个框架语言源表供只读验证") }
        let originals = try sources.map { (URL(fileURLWithPath: $0), try Data(contentsOf: URL(fileURLWithPath: $0))) }
        for (file, _) in originals {
            let book = try LanguageWorkbookReader.read(fileURL: file)
            try WorkspaceSmokeTests.require(book.languageColumns.count == 14 && !book.entries.isEmpty,
                "真实框架语言表未识别出 14 个语言列：\(file.lastPathComponent)")
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("LanguageWorkbook-smoke-\(UUID().uuidString)")
        let config = root.appendingPathComponent("Project/Config")
        let data = config.appendingPathComponent("Datas")
        let main = data.appendingPathComponent("TbLanguage.xlsx")
        let frame = data.appendingPathComponent("FrameWork/TbFrameLanguage.xlsx")
        let suite = "io.centurygames.one-click-table-export.language-workbook-smoke-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        try manager.createDirectory(at: frame.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(atPath: source, toPath: main.path)
        try manager.copyItem(atPath: source, toPath: frame.path)
        defer {
            try? TranslationDraftStore.save([], for: main)
            try? TranslationDraftStore.save([], for: frame)
            defaults.removePersistentDomain(forName: suite)
            try? manager.removeItem(at: root)
        }
        let project = ExportProject(rootURL: root.appendingPathComponent("Project"), configurationRootURL: config,
            dataRootURL: data, generatorURL: config.appendingPathComponent("gen.sh"), displayPath: "Project")
        let first = try LanguageWorkbookReader.read(fileURL: frame).entries[0]
        let languages = try LanguageWorkbookReader.read(fileURL: frame).languageColumns
        func update(_ code: String, _ value: String) -> LocalizationCellUpdate {
            LocalizationCellUpdate(rowIndex: first.rowIndex, columnIndex: languages.first { $0.code == code }!.columnIndex,
                                   languageCode: code, value: value)
        }
        _ = try LanguageWorkbookWriter.write(fileURL: frame,
            updates: [update("en", "Framework source"), update("zh-CN", "框架原文"), update("ja", "")])
        _ = try LanguageWorkbookWriter.write(fileURL: main,
            updates: [update("en", "Game source"), update("zh-CN", "游戏原文"), update("ja", "游戏译文")])
        let untouchedMain = try Data(contentsOf: main)
        let members = String(decoding: try GridWorkbookIO.capture("/usr/bin/unzip", ["-Z1", frame.path]), as: UTF8.self)
            .split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/") && $0 != "xl/worksheets/sheet1.xml" }
        let unchangedParts = try members.map { ($0, try GridWorkbookIO.entry($0, in: frame)) }
        func wait(_ model: LanguageBrowserViewModel) throws {
            let deadline = Date(timeIntervalSinceNow: 8)
            while model.isBusy && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
            try WorkspaceSmokeTests.require(!model.isBusy, "语言表操作超时")
        }
        func entry(_ model: LanguageBrowserViewModel) throws -> LocalizationEntry {
            guard let result = model.workbook?.entries.first(where: { $0.key == first.key }) else {
                throw WorkspaceError(message: "切换后词条未正确读取")
            }
            return result
        }
        let model = LanguageBrowserViewModel(defaults: defaults)
        model.select(project: project); try wait(model)
        try WorkspaceSmokeTests.require(model.availableWorkbookKinds == [.main, .framework] && model.workbook?.fileURL == main,
            "默认主语言表或框架选项发现错误")
        model.translationBinding(for: try entry(model), languageCode: "en").wrappedValue = "game draft {0}"
        model.selectWorkbook(.framework, in: project); try wait(model)
        try WorkspaceSmokeTests.require(model.workbook?.fileURL == frame && model.pendingChangeCount == 0 &&
            model.missingTranslationCellCount >= 1 && model.consistencyEligibleEntryCount > 0,
            "框架表未进入翻译/一致性处理，或主表草稿串入框架表")
        model.translationBinding(for: try entry(model), languageCode: "en").wrappedValue = "frame draft {0}\nsecond line"
        model.selectWorkbook(.main, in: project); try wait(model)
        let mainDraft = model.translation(for: try entry(model), languageCode: "en")
        try WorkspaceSmokeTests.require(mainDraft == "game draft {0}" &&
            model.pendingChangeCount == 1, "切换丢失主语言表草稿")
        model.selectWorkbook(.framework, in: project); try wait(model)
        let frameDraft = model.translation(for: try entry(model), languageCode: "en")
        try WorkspaceSmokeTests.require(frameDraft == "frame draft {0}\nsecond line",
            "切换丢失框架语言表草稿")
        model.translateAllMissing()
        try WorkspaceSmokeTests.require(model.showsTranslationSettings && !model.isTranslating,
            "框架翻译未保留缺少 API Key 的设置入口")
        model.showsTranslationSettings = false
        model.checkTranslationConsistency()
        try WorkspaceSmokeTests.require(model.showsTranslationSettings && !model.isCheckingConsistency,
            "框架一致性检查未保留 API 设置入口")
        var savedCallback = false
        model.savePendingChanges { savedCallback = true }; try wait(model)
        try WorkspaceSmokeTests.require(savedCallback && model.pendingChangeCount == 0 &&
            model.workbook?.entries.first(where: { $0.key == first.key })?.translations["en"] == "frame draft {0}\nsecond line",
            "框架保存或保存后导表回调失败")
        let writtenMain = try Data(contentsOf: main)
        try WorkspaceSmokeTests.require(writtenMain == untouchedMain, "框架保存改动了主语言表")
        for (name, original) in unchangedParts {
            let actual = try GridWorkbookIO.entry(name, in: frame)
            try WorkspaceSmokeTests.require(actual == original,
                "框架保存改动了非目标工作簿部件：\(name)")
        }
        let restored = LanguageBrowserViewModel(defaults: defaults)
        restored.select(project: project); try wait(restored)
        let restoredDraft = restored.translation(for: try entry(restored), languageCode: "en")
        try WorkspaceSmokeTests.require(restoredDraft == "game draft {0}",
            "重新创建模型未恢复主语言表的独立草稿")
        model.translationBinding(for: try entry(model), languageCode: "en").wrappedValue = "pending conflict"
        _ = try LanguageWorkbookWriter.write(fileURL: frame, updates: [update("en", "external change")])
        savedCallback = false
        model.savePendingChanges { savedCallback = true }; try wait(model)
        try WorkspaceSmokeTests.require(!savedCallback && model.pendingChangeCount == 1 && model.errorMessage != nil,
            "框架原表外部改动未阻止写回或导表回调")
        let otherData = root.appendingPathComponent("Other/Datas")
        try manager.createDirectory(at: otherData, withIntermediateDirectories: true)
        try manager.copyItem(at: main, to: otherData.appendingPathComponent("TbLanguage.xlsx"))
        try manager.copyItem(at: frame, to: otherData.appendingPathComponent("TbFrameLanguage.story.xlsx"))
        let other = ExportProject(rootURL: root.appendingPathComponent("Other"), configurationRootURL: otherData,
            dataRootURL: otherData, generatorURL: otherData.appendingPathComponent("gen.sh"), displayPath: "Other")
        model.select(project: other); try wait(model)
        try WorkspaceSmokeTests.require(model.availableWorkbookKinds == [.main] && model.selectedWorkbookKind == .main,
            "无框架表项目错误显示框架入口或模糊匹配故事表")
        model.selectWorkbook(.framework, in: other)
        try WorkspaceSmokeTests.require(model.selectedWorkbookKind == .main, "无框架表时错误切换")
        model.select(project: project); try wait(model)
        let returnedDraft = model.translation(for: try entry(model), languageCode: "en")
        try WorkspaceSmokeTests.require(model.selectedWorkbookKind == .framework && model.pendingChangeCount == 1 &&
            returnedDraft == "pending conflict", "跨项目切换丢失框架草稿或选择")
        let frameOnlyData = root.appendingPathComponent("FrameOnly/Datas")
        try manager.createDirectory(at: frameOnlyData, withIntermediateDirectories: true)
        try manager.copyItem(at: frame, to: frameOnlyData.appendingPathComponent("tbframelanguage.xlsx"))
        let frameOnly = ExportProject(rootURL: root.appendingPathComponent("FrameOnly"), configurationRootURL: frameOnlyData,
            dataRootURL: frameOnlyData, generatorURL: frameOnlyData.appendingPathComponent("gen.sh"), displayPath: "FrameOnly")
        model.select(project: frameOnly); try wait(model)
        try WorkspaceSmokeTests.require(model.availableWorkbookKinds == [.framework] && model.selectedWorkbookKind == .framework,
            "只有框架语言表或文件名大小写变化时未正确加载")
        for (file, original) in originals {
            let actual = try Data(contentsOf: file)
            try WorkspaceSmokeTests.require(actual == original, "真实框架源表发生改动")
        }
        print("框架多语言：真实 14 语言只读解析、递归精确发现、主表/框架切换、同 key 草稿隔离与恢复、缺失翻译和一致性入口、定向保存、非目标部件保留、保存回调、外部冲突保护及无框架/仅框架项目通过；未调用真实 AI 或工程导表，真实源表未改。")
    }
}
#endif
