#if SMOKE_TEST
import Foundation

enum ProjectPresentationSmokeTests {
    @MainActor static func run() throws {
        let suite = "DECT-project-presentation-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func fixture(_ path: String) -> ExportProject {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            return ExportProject(rootURL: root, configurationRootURL: root.appendingPathComponent("Config"),
                                 dataRootURL: root.appendingPathComponent("Config/Datas"),
                                 generatorURL: root.appendingPathComponent("Config/gen.sh"), displayPath: path)
        }
        let a = fixture("/fixture/A/game"), b = fixture("/fixture/B/game"), c = fixture("/fixture/C/new")
        var settings = ProjectPresentationPreferences.load(defaults: defaults)
        try WorkspaceSmokeTests.require(settings.apply(to: [b, a]).map(\.id) == [a.id, b.id], "首次显示应保留默认路径顺序")
        var renamed = b
        renamed.remarkName = "  测试项目  "
        settings.update(from: [renamed, a])
        settings.save(defaults: defaults)
        settings = .load(defaults: defaults)
        let restored = settings.apply(to: [a, c, b])
        try WorkspaceSmokeTests.require(restored.map(\.id) == [b.id, a.id, c.id] && restored[0].name == "测试项目" &&
                                        restored[1].name == "game" && restored[0].generatorURL == b.generatorURL &&
                                        restored[0].dataRootURL == b.dataRootURL, "重启/重新扫描后顺序、同名项目备注、路径隔离失败")
        settings.update(from: [a, c])
        try WorkspaceSmokeTests.require(settings.apply(to: [a, b, c]).first?.name == "测试项目", "暂时缺失的项目应保留备注及排序")
        renamed.remarkName = " \n "
        settings.update(from: [a, renamed, c])
        settings.save(defaults: defaults)
        let cleared = ProjectPresentationPreferences.load(defaults: defaults).apply(to: [c, b, a])
        try WorkspaceSmokeTests.require(cleared.map(\.id) == [a.id, b.id, c.id] && cleared[1].name == b.originalName,
                                        "清空备注应恢复原工程名，手动排序应保存")
        try WorkspaceSmokeTests.require(settings.apply(to: [a, b, c]).map(CachedExportProject.init).map(\.rootPath) == [a.id, b.id, c.id],
                                        "备注不可改写工程缓存身份")
        print("项目显示设置：默认顺序、同名路径隔离、备注去空白、重启持久化、重扫/新项目追加、暂时缺失项目恢复、清空备注与导表路径保留通过；使用独立测试设置。")
    }
}
#endif
