#if SMOKE_TEST
import AppKit
import Foundation

enum WorkspaceSmokeTests {
    @MainActor static func compareAndTabs(_ source: String) throws {
        var originalCells: [GridAddress: GridCell] = [:], shiftedCells: [GridAddress: GridCell] = [:]
        for row in 0..<3000 {
            for column in 0..<4 {
                let value = GridCell(text: row == 0 ? "field\(column)" : "value\(row)-\(column)", formula: false)
                originalCells[GridAddress(row: row, column: column)] = value
                if row != 120 {
                    shiftedCells[GridAddress(row: row < 120 ? row : row - 1, column: column + 1)] = value
                }
            }
        }
        shiftedCells[GridAddress(row: 0, column: 0)] = GridCell(text: "new field", formula: false)
        let alignment = TableAlignment.align(ComparedSheet(name: "test", cells: originalCells), ComparedSheet(name: "test", cells: shiftedCells))
        let structural = FolderComparer.diff(alignment.0, alignment.1, alignKeys: false).0
        try require(structural.count == 5 && structural.filter { $0.status == .added }.count == 1 && structural.filter { $0.status == .removed }.count == 4,
                    "3000 行表新增列并删除行导致相同内容误报")
        let reverse = TableAlignment.align(ComparedSheet(name: "test", cells: shiftedCells), ComparedSheet(name: "test", cells: originalCells))
        try require(FolderComparer.diff(reverse.0, reverse.1, alignKeys: false).0.count == 5, "反向增删对齐失败")
        let manager = FileManager.default, sourceURL = URL(fileURLWithPath: source)
        let original = try Data(contentsOf: sourceURL)
        let root = manager.temporaryDirectory.appendingPathComponent("TableCompare-smoke-\(UUID().uuidString)")
        try manager.createDirectory(at: root.appendingPathComponent("old/sub"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("new/sub"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let old = root.appendingPathComponent("old/sub/Table.xlsx"), new = root.appendingPathComponent("new/sub/Table.xlsx")
        try manager.copyItem(at: sourceURL, to: old); try manager.copyItem(at: sourceURL, to: new)
        let snapshot = try GridWorkbookIO.read(new)
        _ = try GridWorkbookIO.save(snapshot, changes: [GridAddress(row: 5, column: 3): "Version test {0} &", GridAddress(row: 6, column: 3): "Version second cell"])
        let cancellation = ComparisonCancellation()
        let result = FolderComparer.compare(path: "sub/Table.xlsx", oldURL: old, newURL: new, alignKeys: false, cancellation: cancellation)
        try require(result.status == .changed && result.differences.count == 2, "XLSX 差异数量错误：\(result.status.rawValue) / \(result.differences.count) / \(result.note)")
        let comparedSheet = result.newSheets.first!
        let projection = ComparisonTableProjection(file: result, sheetName: comparedSheet.name)
        try require(projection.kind(at: GridAddress(row: 5, column: 3)) == .modified &&
                    projection.rowKind(5) == .modified && projection.columnKind(3) == .modified,
                    "完整表格的单元格、行、列改动标记失败")
        let checking = FolderComparisonModel()
        checking.files = [result]; checking.selectedID = result.id; checking.markSelectedChecked()
        try require(checking.checkedCount == 1 && checking.checkedProgress == 1 && checking.isChecked(result), "已检查进度记录失败")
        let same = FolderComparer.compare(path: "same", oldURL: old, newURL: old, alignKeys: false, cancellation: cancellation)
        try require(same.status == .same, "相同 XLSX 误报差异")
        try "id,value\n1,\"a,b\"\n2,\"line\nnext\"\n".write(to: root.appendingPathComponent("old/values.csv"), atomically: true, encoding: .utf8)
        try "id,value\n1,new\n2,\"line\nnext\"\n".write(to: root.appendingPathComponent("new/values.csv"), atomically: true, encoding: .utf8)
        try "id\n1\n".write(to: root.appendingPathComponent("new/added.csv"), atomically: true, encoding: .utf8)
        try "id\n2\n".write(to: root.appendingPathComponent("old/deleted.csv"), atomically: true, encoding: .utf8)
        let a = try FolderComparer.catalog(root.appendingPathComponent("old")), b = try FolderComparer.catalog(root.appendingPathComponent("new"))
        try require(a["sub/Table.xlsx"] != nil && b["sub/Table.xlsx"] != nil, "子目录匹配失败")
        let csv = FolderComparer.compare(path: "values.csv", oldURL: a["values.csv"], newURL: b["values.csv"], alignKeys: false, cancellation: cancellation)
        try require(csv.differences.count == 1 && csv.differences.first?.old == "a,b", "CSV 逗号和跨行字段比较失败")
        let added = FolderComparer.compare(path: "added.csv", oldURL: nil, newURL: b["added.csv"], alignKeys: false, cancellation: cancellation)
        let deleted = FolderComparer.compare(path: "deleted.csv", oldURL: a["deleted.csv"], newURL: nil, alignKeys: false, cancellation: cancellation)
        try require(added.status == .added && deleted.status == .removed, "新增删除文件识别失败")
        let addedProjection = ComparisonTableProjection(file: added, sheetName: added.newSheets.first!.name)
        let deletedProjection = ComparisonTableProjection(file: deleted, sheetName: deleted.oldSheets.first!.name)
        try require(addedProjection.kind(at: GridAddress(row: 0, column: 0)) == .added &&
                    addedProjection.rowKind(0) == .added && addedProjection.columnKind(0) == .added &&
                    deletedProjection.kind(at: GridAddress(row: 0, column: 0)) == .removed &&
                    deletedProjection.rowKind(0) == .removed && deletedProjection.columnKind(0) == .removed,
                    "新增删除表格的单元格、行、列颜色标记失败")
        func sheet(_ reordered: Bool) -> ComparedSheet {
            let rows = reordered ? [["id", "value"], ["2", "b"], ["1", "a"]] : [["id", "value"], ["1", "a"], ["2", "b"]]
            var cells: [GridAddress: GridCell] = [:]
            for (r, row) in rows.enumerated() { for (c, value) in row.enumerated() { cells[GridAddress(row: r, column: c)] = GridCell(text: value, formula: false) } }
            return ComparedSheet(name: "data", cells: cells)
        }
        let aligned = FolderComparer.diff(sheet(false), sheet(true), alignKeys: true)
        try require(aligned.0.isEmpty && aligned.1, "唯一 ID 行对齐失败")
        let positional = FolderComparer.diff(sheet(false), sheet(true), alignKeys: false)
        try require(positional.0.count == 4, "位置模式未反映重排")
        let f1 = ComparedSheet(name: "formula", cells: [GridAddress(row: 0, column: 0): GridCell(text: "2", formula: true, formulaText: "1+1")])
        let f2 = ComparedSheet(name: "formula", cells: [GridAddress(row: 0, column: 0): GridCell(text: "2", formula: true, formulaText: "2*1")])
        try require(FolderComparer.diff(f1, f2, alignKeys: false).0.count == 1, "公式变化未识别")
        cancellation.cancel()
        try require(FolderComparer.compare(path: "cancel", oldURL: old, newURL: new, alignKeys: false, cancellation: cancellation).status == .failed, "停止未标记为未完成")
        let final = try Data(contentsOf: sourceURL)
        try require(final == original, "真实源表发生变化")
        print("文件夹对比：子目录、全部工作表、2 格精准差异、相同文件、CSV 引号跨行、新增删除、ID 对齐、公式变化和停止通过；源表未改。")
    }

    @MainActor static func gitHistory(_ source: String) throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("TableGitHistory-smoke-\(UUID().uuidString)")
        let projectRoot = root.appendingPathComponent("Project", isDirectory: true)
        let dataRoot = projectRoot.appendingPathComponent("Config/Datas", isDirectory: true)
        try manager.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let file = dataRoot.appendingPathComponent("Table.xlsx")
        try manager.copyItem(at: URL(fileURLWithPath: source), to: file)
        func git(_ arguments: [String]) throws {
            _ = try GridWorkbookIO.capture("/usr/bin/git", arguments, directory: root)
        }
        try git(["init", "-q"])
        try git(["config", "user.name", "Workspace Smoke"])
        try git(["config", "user.email", "workspace-smoke@example.invalid"])
        try git(["add", "Project/Config/Datas/Table.xlsx"])
        try git(["commit", "-qm", "initial table"])

        let committedSnapshot = try GridWorkbookIO.read(file)
        _ = try GridWorkbookIO.save(committedSnapshot,
            changes: [GridAddress(row: 4, column: 2): "committed history value"])
        try git(["add", "Project/Config/Datas/Table.xlsx"])
        try git(["commit", "-qm", "update table history"])

        let workingSnapshot = try GridWorkbookIO.read(file)
        _ = try GridWorkbookIO.save(workingSnapshot,
            changes: [GridAddress(row: 4, column: 2): "uncommitted working value"])

        let repository = try GitHistoryProvider.discover(projectURL: projectRoot)
        try require(repository.dataRelativePath == "Project/Config/Datas", "Git 配置表相对路径识别失败")
        let branches = try GitHistoryProvider.branches(repository: repository)
        try require(branches.contains(where: { $0.name == repository.currentBranch }), "Git 当前分支读取失败")
        let reference = repository.currentBranch ?? branches.first!.name
        let commits = try GitHistoryProvider.commits(repository: repository, reference: reference)
        try require(commits.count >= 2 && commits[0].date >= commits[1].date, "Git 提交历史或时间排序读取失败")
        let history = try GitHistoryProvider.materializeSnapshot(repository: repository, commit: commits[0])
        defer { GitHistoryProvider.removeSnapshot(at: history.rootURL) }
        let historyFile = history.dataRoot.appendingPathComponent("Table.xlsx")
        try require(manager.fileExists(atPath: historyFile.path), "Git 历史配置表快照未解包")
        let comparison = FolderComparer.compare(path: "Table.xlsx", oldURL: historyFile, newURL: file,
            alignKeys: false, cancellation: ComparisonCancellation())
        try require(comparison.status == .changed && comparison.differences.contains(where: {
            $0.old == "committed history value" && $0.new == "uncommitted working value"
        }), "Git 历史与当前未提交工作区对比失败")
        let snapshotRoot = history.rootURL
        GitHistoryProvider.removeSnapshot(at: snapshotRoot)
        try require(!manager.fileExists(atPath: snapshotRoot.path), "Git 历史临时快照未清理")
        print("Git 历史：仓库识别、分支、提交、临时快照、未提交工作区差异与清理通过。")
    }

    @MainActor static func projectDiscovery(_ rootPath: String) throws {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let projects = try ProjectScanner().scan(root: root)
        if let legacy = projects.first(where: { $0.rootURL.lastPathComponent == "sortime-game" }) {
            try require(legacy.configurationRootURL.lastPathComponent == "Config" &&
                        legacy.dataRootURL.path.hasSuffix("/Config/Datas"),
                        "传统 Config/Datas 工程兼容识别错误")
        }
        guard let project = projects.first(where: { $0.rootURL.lastPathComponent == "TCR" }) else {
            throw WorkspaceError(message: "项目扫描未找到 TCR 配置工程。")
        }
        try require(project.configurationRootURL.lastPathComponent == "LubanConfig",
                    "TCR 配置根目录识别错误：\(project.configurationRootURL.path)")
        try require(project.dataRootURL.lastPathComponent == "Datas" &&
                    project.dataRootURL.path.hasSuffix("/trunk/LubanConfig/Datas"),
                    "TCR dataDir 解析错误：\(project.dataRootURL.path)")
        try require(project.generatorURL.lastPathComponent == "gen.sh" &&
                    project.workingDirectoryURL == project.configurationRootURL,
                    "TCR 导表脚本或执行目录识别错误")

        let tables = try ProjectTableScanner.scan(projects: [project])
        try require(tables.count >= 80, "TCR 配置表递归扫描数量异常：\(tables.count)")
        try require(tables.contains(where: { $0.relativeDataPath == "TbLanguage.xlsx" }),
                    "TCR 主 TbLanguage.xlsx 未扫描到")
        try require(tables.contains(where: { $0.relativeDataPath.hasPrefix("V2.0/") }) &&
                    tables.contains(where: { $0.relativeDataPath.hasPrefix("V3.0/") }) &&
                    tables.contains(where: { $0.relativeDataPath.contains("水上狂欢/") }),
                    "TCR 二级和中文目录表格未完整扫描")

        guard let languageURL = ProjectConfigurationResolver.languageWorkbookURL(in: project) else {
            throw WorkspaceError(message: "TCR 主 TbLanguage.xlsx 定位失败。")
        }
        let language = try LanguageWorkbookReader.read(fileURL: languageURL)
        try require(!language.entries.isEmpty && language.languageColumns.count >= 2,
                    "TCR 主 TbLanguage.xlsx 读取结果为空")

        let repository = try GitHistoryProvider.discover(
            projectURL: project.rootURL,
            dataRootURL: project.dataRootURL
        )
        try require(repository.dataRelativePath == "trunk/LubanConfig/Datas" &&
                    repository.currentDataRoot == project.dataRootURL,
                    "TCR Git 历史配置表路径识别错误：\(repository.dataRelativePath)")
        print("TCR 通用工程扫描：配置根目录、dataDir、80 张表、V2/V3/中文子目录、主语言表和 Git 数据路径通过；源表未改。")
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw WorkspaceError(message: message) }
    }

    @MainActor static func translationSettings() throws {
        let suiteName = "io.centurygames.one-click-table-export.translation-smoke-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw WorkspaceError(message: "无法创建翻译设置 smoke suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try TranslationSettingsStore.save(
            apiKeyInput: "  smoke-api-key-123  ",
            endpoint: "https://example.invalid/v1/chat/completions",
            model: "smoke-model",
            defaults: defaults
        )
        let saved = TranslationSettingsStore.load(defaults: defaults)
        try require(saved.apiKey == "smoke-api-key-123" && saved.keySourceDescription == "本机设置",
                    "API Key 未写入普通本机设置")
        try require(saved.endpoint == "https://example.invalid/v1/chat/completions" && saved.model == "smoke-model",
                    "翻译 API 普通设置未写入")

        guard let reloadedDefaults = UserDefaults(suiteName: suiteName) else {
            throw WorkspaceError(message: "无法重新打开翻译设置 smoke suite")
        }
        let reloaded = TranslationSettingsStore.load(defaults: reloadedDefaults)
        try require(reloaded.apiKey == "smoke-api-key-123", "API Key 重载后没有保留")
        try TranslationSettingsStore.save(
            apiKeyInput: "",
            endpoint: reloaded.endpoint,
            model: reloaded.model,
            defaults: reloadedDefaults
        )
        try require(TranslationSettingsStore.load(defaults: reloadedDefaults).apiKey == "smoke-api-key-123",
                    "保存其他设置时错误清空了已有 API Key")
        print("翻译 API Key 普通本机设置写入、重载和留空保留通过；未访问钥匙串。")
    }

    @MainActor static func gridGeometry() throws {
        let sheet = GridSheet(name: "Sheet1", archivePath: "xl/worksheets/sheet1.xml")
        let cells = Dictionary(uniqueKeysWithValues: (0..<40).flatMap { row in
            (0..<4).map { column in
                (GridAddress(row: row, column: column), GridCell(text: "R\(row + 1)C\(column + 1)", formula: false))
            }
        })
        let snapshot = GridSnapshot(
            fileURL: URL(fileURLWithPath: "/tmp/grid-geometry-smoke.xlsx"),
            fingerprint: Data(), sheets: [sheet], sheet: sheet, cells: cells,
            rowCount: 40, columnCount: 4)
        let editor = GridEditorModel(); editor.snapshot = snapshot
        let grid = FrozenGridView(editor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = grid; window.makeKeyAndOrderFront(nil)
        grid.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        grid.layoutSubtreeIfNeeded(); grid.update(); grid.layoutSubtreeIfNeeded()
        guard let region = grid.regions.first else { throw WorkspaceError(message: "几何测试没有表格区域") }
        let table = region.table
        let header = table.headerView?.frame ?? .zero
        let first = table.rect(ofRow: 0)
        let visible = table.visibleRect
        let origin = region.scroll.contentView.bounds.origin
        func checkTopRow(_ region: GridRegion, label: String) throws -> (NSRect, NSRect) {
            guard let headerView = region.table.headerView else {
                throw WorkspaceError(message: "\(label) 缺少列标题")
            }
            let headerInClip = headerView.convert(headerView.bounds, to: region.scroll.contentView)
            let firstInClip = region.table.convert(region.table.rect(ofRow: 0), to: region.scroll.contentView)
            guard firstInClip.minY >= headerInClip.maxY - 0.5 && firstInClip.height >= 29 else {
                throw WorkspaceError(message: "\(label) 第一行被列标题遮挡：header=\(headerInClip) first=\(firstInClip)")
            }
            if region.range.count > 1 {
                let secondInClip = region.table.convert(region.table.rect(ofRow: 1), to: region.scroll.contentView)
                try require(secondInClip.minY >= firstInClip.maxY - 0.5,
                            "\(label) 第一行与第二行重叠：first=\(firstInClip) second=\(secondInClip)")
            }
            return (headerInClip, firstInClip)
        }
        let (headerInClip, firstInClip) = try checkTopRow(region, label: "100% 单表")
        print("GRID_GEOMETRY header=\(header) first=\(first) firstInClip=\(firstInClip) headerInClip=\(headerInClip) visible=\(visible) origin=\(origin) table=\(table.frame)")
        editor.setZoom(1.5); grid.update(); grid.layoutSubtreeIfNeeded()
        let (_, scaledFirstInClip) = try checkTopRow(region, label: "150% 单表")
        try require(abs(scaledFirstInClip.minY - 34.5) < 0.5, "缩放后第一行未跟随表头下移：\(scaledFirstInClip)")
        editor.frozenRows = 1; editor.frozenColumns = 1; editor.revision += 1
        grid.update(); grid.layoutSubtreeIfNeeded()
        guard let frozenTop = grid.regions.first else { throw WorkspaceError(message: "冻结测试没有左上区域") }
        _ = try checkTopRow(frozenTop, label: "冻结左上区域")
        window.orderOut(nil)
    }

    @MainActor static func run(_ files: [String]) throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("TableWorkspace-smoke-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let special = [["<color=#abcdef>中文 & {0}</color>", "line\nnext", "tab\there"], ["\"quoted\"", "00123", "=literal"]]
        try require(GridClipboard.decode(GridClipboard.encode(special)) == special, "跨行/Tab/引号剪贴板往返失败")
        try require(GridClipboard.decode("a\tb\r\nc\td\r\n") == [["a", "b"], ["c", "d"]], "Excel CRLF 剪贴板失败")
        print("剪贴板：矩形范围、换行、引号、Tab 和 Excel CRLF 通过")

        for (index, path) in files.enumerated() {
            let original = URL(fileURLWithPath: path), originalData = try Data(contentsOf: original)
            let project = root.appendingPathComponent("Project-\(index)")
            try manager.createDirectory(at: project, withIntermediateDirectories: true)
            let file = project.appendingPathComponent("TbLanguage.xlsx")
            try manager.copyItem(at: original, to: file)
            let snapshot = try GridWorkbookIO.read(file)
            let row = snapshot.rowCount + 2
            var updates: [GridAddress: String] = [:]
            for (r, values) in special.enumerated() { for (c, text) in values.enumerated() {
                updates[GridAddress(row: row + r, column: c)] = text
            } }
            // Existing cells, missing interior cells, and end-of-sheet inserts.
            for r in 5..<10 { for c in 3..<7 where snapshot.cells[GridAddress(row: r, column: c)]?.formula != true {
                updates[GridAddress(row: r, column: c)] = "check \(r)/\(c) 😀 {1}\u{0001}"
            } }
            let revised = try GridWorkbookIO.save(snapshot, changes: updates)
            for (address, text) in updates { try require(revised.cells[address]?.text == GridWorkbookIO.cleanText(text), "写入值不一致：\(address.reference)") }
            for (address, cell) in snapshot.cells where updates[address] == nil {
                try require(revised.cells[address]?.text == cell.text && revised.cells[address]?.formula == cell.formula, "非目标单元格变化：\(address.reference)")
            }
            let members = String(decoding: try GridWorkbookIO.capture("/usr/bin/unzip", ["-Z1", file.path]), as: UTF8.self).split(separator: "\n").map(String.init)
            for member in members where !member.hasSuffix("/") && member != snapshot.sheet.archivePath {
                let expected = try GridWorkbookIO.entry(member, in: original)
                let actual = try GridWorkbookIO.entry(member, in: file)
                try require(expected == actual, "非目标工作簿部件变化：\(member)")
            }
            _ = try GridWorkbookIO.capture("/usr/bin/unzip", ["-tq", file.path])
            // Formula editing: the editor exposes the raw formula with a
            // leading '=', and the writer stores the formula body in <f>.
            let formulaFile = project.appendingPathComponent("Formula.xlsx")
            try manager.copyItem(at: file, to: formulaFile)
            let formulaBase = try GridWorkbookIO.read(formulaFile)
            let formulaAddress = GridAddress(row: 0, column: 0)
            var formulaCells = formulaBase.cells
            let originalFormulaCell = formulaCells[formulaAddress]
            formulaCells[formulaAddress] = GridCell(
                text: originalFormulaCell?.text ?? "",
                formula: true,
                formulaText: "1+1",
                valueKind: originalFormulaCell?.valueKind ?? "n")
            let formulaSnapshot = GridSnapshot(
                fileURL: formulaBase.fileURL,
                fingerprint: formulaBase.fingerprint,
                sheets: formulaBase.sheets,
                sheet: formulaBase.sheet,
                cells: formulaCells,
                rowCount: formulaBase.rowCount,
                columnCount: formulaBase.columnCount)
            let formulaEditor = GridEditorModel(); formulaEditor.snapshot = formulaSnapshot
            let formulaRegion = GridRegion(formulaEditor, rows: 0..<2, columns: 0..<2, header: true)
            let formulaColumn = formulaRegion.table.tableColumns[0]
            try require(formulaRegion.tableView(formulaRegion.table, objectValueFor: formulaColumn, row: 0) as? String == "=1+1", "选中公式格未显示公式")
            formulaEditor.select(row: 1, column: 1, extending: false)
            try require(formulaRegion.tableView(formulaRegion.table, objectValueFor: formulaColumn, row: 0) as? String == (originalFormulaCell?.text ?? ""), "未选中公式格应显示缓存结果")
            try require(formulaEditor.inputText(formulaAddress) == "=1+1", "公式单元格未显示原始公式")
            formulaEditor.edit([formulaAddress: "=SUM(1, 2)"])
            try require(formulaEditor.changes[formulaAddress] == "=SUM(1, 2)", "公式单元格双击输入内容未进入编辑状态")
            let formulaSaved = try GridWorkbookIO.save(formulaSnapshot, changes: formulaEditor.changes)
            try require(formulaSaved.cells[formulaAddress]?.formula == true &&
                        formulaSaved.cells[formulaAddress]?.formulaText == "SUM(1, 2)",
                        "公式写回 XLSX 失败")
            let searchEntries = [
                GridSearchEntry(address: GridAddress(row: 0, column: 0), searchableText: "Reward 1"),
                GridSearchEntry(address: GridAddress(row: 1, column: 2), searchableText: "REWARD 2"),
                GridSearchEntry(address: GridAddress(row: 3, column: 1), searchableText: "缓存值\n=SUM(A1, 2)")
            ]
            try require(GridEditorModel.matchingSearchAddresses(query: "reward", in: searchEntries) == [
                GridAddress(row: 0, column: 0), GridAddress(row: 1, column: 2)],
                "表格搜索未按大小写不敏感方式匹配或排序")
            try require(GridEditorModel.matchingSearchAddresses(query: "sum(a1", in: searchEntries) == [
                GridAddress(row: 3, column: 1)], "表格搜索未匹配公式文本")
            try require(GridEditorModel.matchingSearchAddresses(query: "   ", in: searchEntries).isEmpty,
                        "空白搜索词不应产生命中")
            print("表格内搜索：大小写不敏感、公式文本、结果顺序与空白词处理通过")
            let searchSheet = GridSheet(name: "Sheet1", archivePath: "xl/worksheets/sheet1.xml")
            let searchCells: [GridAddress: GridCell] = [
                GridAddress(row: 0, column: 0): GridCell(text: "Reward 1", formula: false),
                GridAddress(row: 4, column: 2): GridCell(text: "Cached value", formula: true, formulaText: "SUM(A1, 2)")
            ]
            let searchSnapshot = GridSnapshot(
                fileURL: URL(fileURLWithPath: "/tmp/table-search-smoke.xlsx"), fingerprint: Data(),
                sheets: [searchSheet], sheet: searchSheet, cells: searchCells,
                rowCount: 5, columnCount: 3)
            let searchEditor = GridEditorModel(); searchEditor.snapshot = searchSnapshot
            searchEditor.searchText = "reward"; searchEditor.refreshSearch()
            let searchDeadline = Date().addingTimeInterval(1)
            while searchEditor.isSearching && Date() < searchDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            try require(!searchEditor.isSearching && searchEditor.searchMatches == [GridAddress(row: 0, column: 0)] &&
                        searchEditor.activeSearchAddress == GridAddress(row: 0, column: 0) &&
                        searchEditor.anchor == GridAddress(row: 0, column: 0),
                        "表格搜索异步结果或首个命中定位失败")
            searchEditor.searchText = "cached"; searchEditor.refreshSearch()
            let cachedDeadline = Date().addingTimeInterval(1)
            while searchEditor.isSearching && Date() < cachedDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            try require(searchEditor.searchMatches == [GridAddress(row: 4, column: 2)],
                        "表格搜索未匹配公式计算结果")
            searchEditor.searchText = "sum(a1"; searchEditor.refreshSearch()
            let formulaSearchDeadline = Date().addingTimeInterval(1)
            while searchEditor.isSearching && Date() < formulaSearchDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            try require(searchEditor.searchMatches == [GridAddress(row: 4, column: 2)],
                        "表格搜索未匹配公式文本")
            searchEditor.searchText = "reward"; searchEditor.refreshSearch()
            let navigationDeadline = Date().addingTimeInterval(1)
            while searchEditor.isSearching && Date() < navigationDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            searchEditor.edit([GridAddress(row: 1, column: 1): "Reward 2"])
            let editSearchDeadline = Date().addingTimeInterval(1)
            while searchEditor.isSearching && Date() < editSearchDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            try require(searchEditor.searchMatches == [GridAddress(row: 0, column: 0), GridAddress(row: 1, column: 1)],
                        "表格搜索未包含未保存编辑内容")
            searchEditor.nextSearchMatch()
            try require(searchEditor.activeSearchAddress == GridAddress(row: 1, column: 1),
                        "表格搜索下一个命中定位失败")
            searchEditor.nextSearchMatch()
            try require(searchEditor.activeSearchAddress == GridAddress(row: 0, column: 0),
                        "表格搜索循环定位失败")
            searchEditor.previousSearchMatch()
            try require(searchEditor.activeSearchAddress == GridAddress(row: 1, column: 1),
                        "表格搜索上一个命中定位失败")
            print("表格内搜索：异步扫描、计算结果、公式、未保存内容和循环定位通过")
            // A stale snapshot must never overwrite newer data.
            var blocked = false
            do { _ = try GridWorkbookIO.save(snapshot, changes: [GridAddress(row: 8, column: 3): "stale"]) }
            catch { blocked = error.localizedDescription.contains("已被") }
            try require(blocked, "未阻止旧快照覆盖新数据")
            let editor = GridEditorModel(); editor.snapshot = revised
            let address = GridAddress(row: 8, column: 3), old = editor.text(address)
            editor.edit([address: "new"]); try require(editor.changes.count == 1, "单元格编辑失败")
            editor.undo(); try require(editor.text(address) == old && editor.changes.isEmpty, "撤销失败")
            editor.redo(); try require(editor.text(address) == "new", "重做失败")
            editor.undo()
            var fillCells = revised.cells
            fillCells[GridAddress(row: 0, column: 0)] = GridCell(text: "1", formula: false)
            fillCells[GridAddress(row: 1, column: 0)] = GridCell(text: "3", formula: false)
            let fillSnapshot = GridSnapshot(fileURL: revised.fileURL, fingerprint: revised.fingerprint,
                sheets: revised.sheets, sheet: revised.sheet, cells: fillCells,
                rowCount: max(revised.rowCount, 2), columnCount: max(revised.columnCount, 1))
            let fillEditor = GridEditorModel(); fillEditor.snapshot = fillSnapshot
            fillEditor.select(row: 0, column: 0, extending: false); fillEditor.select(row: 1, column: 0, extending: true)
            _ = fillEditor.fillSelection(to: 4, targetColumn: 0)
            try require(fillEditor.inputText(GridAddress(row: 2, column: 0)) == "5" &&
                        fillEditor.inputText(GridAddress(row: 4, column: 0)) == "9", "数字序列填充失败")
            var dateCells = fillCells
            dateCells[GridAddress(row: 0, column: 0)] = GridCell(text: "2026-09-01", formula: false)
            dateCells[GridAddress(row: 1, column: 0)] = GridCell(text: "2026-09-02", formula: false)
            let dateSnapshot = GridSnapshot(fileURL: revised.fileURL, fingerprint: revised.fingerprint,
                sheets: revised.sheets, sheet: revised.sheet, cells: dateCells,
                rowCount: max(revised.rowCount, 2), columnCount: max(revised.columnCount, 1))
            let dateEditor = GridEditorModel(); dateEditor.snapshot = dateSnapshot
            dateEditor.select(row: 0, column: 0, extending: false); dateEditor.select(row: 1, column: 0, extending: true)
            _ = dateEditor.fillSelection(to: 3, targetColumn: 0)
            try require(dateEditor.inputText(GridAddress(row: 2, column: 0)) == "2026-09-03" &&
                        dateEditor.inputText(GridAddress(row: 3, column: 0)) == "2026-09-04", "日期序列填充失败")
            var singleFillCells = fillCells
            singleFillCells[GridAddress(row: 0, column: 0)] = GridCell(text: "10", formula: false)
            let singleFillSnapshot = GridSnapshot(fileURL: revised.fileURL, fingerprint: revised.fingerprint,
                sheets: revised.sheets, sheet: revised.sheet, cells: singleFillCells,
                rowCount: max(revised.rowCount, 2), columnCount: max(revised.columnCount, 1))
            let singleFillEditor = GridEditorModel(); singleFillEditor.snapshot = singleFillSnapshot
            singleFillEditor.select(row: 0, column: 0, extending: false)
            try require(singleFillEditor.fillFromHandle(to: 3, targetColumn: 0), "单个数字填充未完成")
            try require(singleFillEditor.lastFill?.mode == .sequence &&
                        singleFillEditor.inputText(GridAddress(row: 1, column: 0)) == "11" &&
                        singleFillEditor.inputText(GridAddress(row: 3, column: 0)) == "13",
                        "单个数字未按序列自动填充")
            singleFillEditor.reapplyLastFill(.copy)
            try require(singleFillEditor.inputText(GridAddress(row: 1, column: 0)) == "10" &&
                        singleFillEditor.inputText(GridAddress(row: 3, column: 0)) == "10",
                        "填充选项切换为复制未生效")
            singleFillEditor.reapplyLastFill(.sequence)
            try require(singleFillEditor.inputText(GridAddress(row: 1, column: 0)) == "11" &&
                        singleFillEditor.inputText(GridAddress(row: 3, column: 0)) == "13",
                        "填充选项切换为序列未生效")
            for (seed, previous, expected) in [("奖励1", nil, "奖励4"), ("奖励009", nil, "奖励012"),
                                               ("奖励3", "奖励1", "奖励9"), ("奖励3", "奖励5", "奖励-3"),
                                               ("奖励1", "道具1", nil), ("普通奖励", nil, nil), ("=A1", nil, nil)] as [(String, String?, String?)] {
                try require(GridEditorModel.textSequenceValue(seed, previous: previous, offset: 3) == expected, "文字编号序列失败：\(seed)")
            }
            let labelEditor = GridEditorModel(); labelEditor.snapshot = singleFillSnapshot
            labelEditor.edit([GridAddress(row: 0, column: 0): "奖励1"])
            labelEditor.select(row: 0, column: 0, extending: false)
            _ = labelEditor.fillFromHandle(to: 3, targetColumn: 0)
            try require(labelEditor.inputText(GridAddress(row: 3, column: 0)) == "奖励4", "文字编号自动填充失败")
            labelEditor.reapplyLastFill(.copy)
            try require(labelEditor.inputText(GridAddress(row: 3, column: 0)) == "奖励1", "文字编号复制失败")
            labelEditor.reapplyLastFill(.sequence)
            try require(labelEditor.inputText(GridAddress(row: 3, column: 0)) == "奖励4", "文字编号切换序列失败")
            labelEditor.select(row: 0, column: 0, extending: false)
            _ = labelEditor.fillSelection(to: 0, targetColumn: 3)
            try require(labelEditor.inputText(GridAddress(row: 0, column: 3)) == "奖励4", "文字编号横向填充失败")
            for (seed, previous, expected) in [("1奖励", nil, "4奖励"), ("奖励1级", nil, "奖励4级"),
                                                ("v1.2", nil, "v1.5"), ("v1.4", "v1.2", "v1.10")] as [(String, String?, String?)] {
                try require(GridEditorModel.textSequenceValue(seed, previous: previous, offset: 3) == expected, "文字中间/开头编号序列失败：\(seed)")
            }
            var independentFillCells = fillCells
            independentFillCells[GridAddress(row: 0, column: 0)] = GridCell(text: "1", formula: false)
            independentFillCells[GridAddress(row: 1, column: 0)] = GridCell(text: "3", formula: false)
            independentFillCells[GridAddress(row: 0, column: 1)] = GridCell(text: "奖励1", formula: false)
            independentFillCells[GridAddress(row: 1, column: 1)] = GridCell(text: "奖励3", formula: false)
            let independentSnapshot = GridSnapshot(fileURL: revised.fileURL, fingerprint: revised.fingerprint,
                sheets: revised.sheets, sheet: revised.sheet, cells: independentFillCells,
                rowCount: max(revised.rowCount, 2), columnCount: max(revised.columnCount, 2))
            let independentEditor = GridEditorModel(); independentEditor.snapshot = independentSnapshot
            independentEditor.select(row: 0, column: 0, extending: false)
            independentEditor.select(row: 1, column: 1, extending: true)
            _ = independentEditor.fillSelection(to: 3, targetColumn: 1, mode: .sequence)
            try require(independentEditor.inputText(GridAddress(row: 2, column: 0)) == "5" &&
                        independentEditor.inputText(GridAddress(row: 3, column: 0)) == "7" &&
                        independentEditor.inputText(GridAddress(row: 2, column: 1)) == "奖励5" &&
                        independentEditor.inputText(GridAddress(row: 3, column: 1)) == "奖励7",
                        "多单元格填充未按列独立判断序列")
            var fillFormulaCells = fillCells
            fillFormulaCells[GridAddress(row: 0, column: 0)] = GridCell(text: "1", formula: true, formulaText: "A1")
            let fillFormulaSnapshot = GridSnapshot(fileURL: revised.fileURL, fingerprint: revised.fingerprint,
                sheets: revised.sheets, sheet: revised.sheet, cells: fillFormulaCells,
                rowCount: max(revised.rowCount, 2), columnCount: max(revised.columnCount, 1))
            let fillFormulaEditor = GridEditorModel(); fillFormulaEditor.snapshot = fillFormulaSnapshot
            fillFormulaEditor.edit([GridAddress(row: 0, column: 0): "=A2"])
            fillFormulaEditor.select(row: 0, column: 0, extending: false)
            _ = fillFormulaEditor.fillSelection(to: 2, targetColumn: 0)
            try require(fillFormulaEditor.inputText(GridAddress(row: 1, column: 0)) == "=A3" &&
                        fillFormulaEditor.inputText(GridAddress(row: 2, column: 0)) == "=A4" &&
                        fillFormulaEditor.formulaAddresses.contains(GridAddress(row: 2, column: 0)), "公式相对引用填充失败")
            let fillFormulaSaved = try GridWorkbookIO.save(fillFormulaSnapshot,
                changes: fillFormulaEditor.changes, formulaAddresses: fillFormulaEditor.formulaAddresses)
            try require(fillFormulaSaved.cells[GridAddress(row: 2, column: 0)]?.formula == true &&
                        fillFormulaSaved.cells[GridAddress(row: 2, column: 0)]?.formulaText == "A4", "新增单元格公式写回失败")
            let longAddress = GridAddress(row: 0, column: 0)
            let longText = String(repeating: "很长的配置内容 Long text\n", count: 1000)
            editor.edit([longAddress: longText])
            editor.fitColumns(); editor.adaptiveRows = true
            try require(editor.columnWidths.values.allSatisfy { $0 >= 120 && $0 <= 360 }, "自适应列宽超出限制")
            try require(editor.displayRowHeight(0) == 96, "长文本行高未封顶")
            try require(editor.inputText(longAddress) == longText, "自适应截断了真实内容")
            editor.undo()
            editor.resetCellLayout()
            try require(editor.columnWidths.isEmpty && editor.displayRowHeight(0) == 29, "恢复默认布局失败")
            editor.adaptiveRows = true
            editor.selectRows(4, extending: false); editor.selectRows(6, extending: true)
            try require(editor.rows == 4...6 && editor.columns.count == editor.usedColumnCount, "整行连选失败")
            editor.selectColumns(2, extending: false); editor.selectColumns(4, extending: true)
            try require(editor.columns == 2...4 && editor.rows.count == editor.usedRowCount, "整列连选失败")
            let copied = GridClipboard.decode(GridClipboard.encode(editor.rows.map { r in editor.columns.map { c in editor.text(GridAddress(row: r, column: c)) } }))
            try require(copied.count == editor.usedRowCount && copied[0].count == 3, "整列复制范围失败")
            editor.frozenRows = 2; editor.frozenColumns = 2
            let grid = FrozenGridView(editor)
            grid.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
            grid.layoutSubtreeIfNeeded()
            try require(grid.regions.count == 4 && grid.regions[0].range == 0..<2 && grid.regions[3].range.lowerBound == 2, "冻结区域行映射失败")
            try require(grid.regions[3].table.dataColumn(0) == 2 && grid.regions[2].table.dataColumn(0) == -1, "冻结区域列映射失败")
            try require(grid.regions[2].table.rect(ofRow: 3).height == grid.regions[3].table.rect(ofRow: 3).height, "自动行高导致冻结区错位")
            let object = grid.regions[3].tableView(grid.regions[3].table, objectValueFor: grid.regions[3].table.tableColumns[0], row: 3) as? String
            try require(object == editor.text(GridAddress(row: 5, column: 2)), "冻结后单元格坐标错误")
            grid.regions[3].scroll.contentView.scroll(to: NSPoint(x: 100, y: 120))
            grid.sync(from: 3)
            try require(abs(grid.regions[1].scroll.contentView.bounds.origin.x - grid.regions[3].scroll.contentView.bounds.origin.x) < 1, "冻结顶部横向同步失败")
            try require(abs(grid.regions[2].scroll.contentView.bounds.origin.y - grid.regions[3].scroll.contentView.bounds.origin.y) < 1, "冻结左侧纵向同步失败")
            editor.frozenRows = 30; editor.frozenColumns = 8; editor.revision += 1
            grid.update(); grid.layoutSubtreeIfNeeded()
            try require(grid.regions.count == 4 && grid.regions[3].scroll.frame.width > 0 && grid.regions[3].scroll.frame.height > 0,
                        "大范围冻结后主体表格被裁切")
            try require(grid.regions[0].scroll.hasHorizontalScroller && grid.regions[0].scroll.hasVerticalScroller &&
                        grid.regions[2].scroll.hasHorizontalScroller,
                        "大范围冻结区域缺少内部滚动能力")
            editor.frozenRows = 2; editor.frozenColumns = 2; editor.revision += 1
            grid.update(); grid.layoutSubtreeIfNeeded()
            editor.select(row: 0, column: 0, extending: false)
            grid.update()
            grid.regions[3].scroll.contentView.scroll(to: NSPoint(x: 120, y: 180))
            grid.regions[3].scroll.reflectScrolledClipView(grid.regions[3].scroll.contentView)
            grid.sync(from: 3)
            let frozenScrollOrigin = grid.regions[3].scroll.contentView.bounds.origin
            _ = editor.fillSelection(to: 12, targetColumn: 0, mode: .copy)
            grid.update()
            let frozenScrollAfterFill = grid.regions[3].scroll.contentView.bounds.origin
            try require(abs(frozenScrollAfterFill.x - frozenScrollOrigin.x) < 1 &&
                        abs(frozenScrollAfterFill.y - frozenScrollOrigin.y) < 1,
                        "冻结多区域填充后滚动位置跳回顶部")
            editor.frozenRows = 0; editor.frozenColumns = 0; grid.update()
            try require(grid.regions.count == 1 && grid.regions[0].range.lowerBound == 0 &&
                        grid.regions[0].table.dataColumn(0) == -1 &&
                        grid.regions[0].table.dataColumn(1) == 0, "取消冻结后普通表格布局失败")
            var handleCells = revised.cells
            handleCells[GridAddress(row: 0, column: 0)] = GridCell(text: "fill seed", formula: false)
            let handleSnapshot = GridSnapshot(fileURL: revised.fileURL, fingerprint: revised.fingerprint,
                sheets: revised.sheets, sheet: revised.sheet, cells: handleCells,
                rowCount: max(revised.rowCount, 3), columnCount: max(revised.columnCount, 1))
            let handleEditor = GridEditorModel(); handleEditor.snapshot = handleSnapshot
            handleEditor.select(row: 0, column: 0, extending: false)
            let handleGrid = FrozenGridView(handleEditor)
            let handleWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            handleWindow.contentView = handleGrid; handleWindow.makeKeyAndOrderFront(nil)
            handleGrid.frame = NSRect(x: 0, y: 0, width: 900, height: 600); handleGrid.layoutSubtreeIfNeeded(); handleGrid.update()
            let handleTable = handleGrid.regions[0].table
            guard let handle = handleTable.fillHandleRect() else { throw WorkspaceError(message: "未绘制表格填充柄") }
            let handlePoint = handleTable.convert(NSPoint(x: handle.midX, y: handle.midY), to: nil)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: handlePoint, modifierFlags: [], timestamp: 0,
                windowNumber: handleWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            handleTable.mouseDown(with: down)
            let targetCell = handleTable.frameOfCell(atColumn: 1, row: 2)
            let targetPoint = handleTable.convert(NSPoint(x: targetCell.midX, y: targetCell.midY), to: nil)
            let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: targetPoint, modifierFlags: [], timestamp: 0,
                windowNumber: handleWindow.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
            handleTable.mouseDragged(with: drag)
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: targetPoint, modifierFlags: [], timestamp: 0,
                windowNumber: handleWindow.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1)!
            handleTable.mouseUp(with: up)
            handleGrid.layoutSubtreeIfNeeded(); handleGrid.update()
            try require(handleEditor.lastFill?.row == 2 && handleEditor.lastFill?.column == 0 &&
                        handleEditor.fillPreviewTarget == nil,
                        "填充拖拽后未自动完成并记录目标")
            try require(handleEditor.lastFill?.mode == .copy && handleGrid.fillOptionsButton?.isHidden == false,
                        "普通文本未自动判断为复制，或填充选项按钮未显示")
            try require(handleEditor.inputText(GridAddress(row: 1, column: 0)) == "fill seed" &&
                        handleEditor.inputText(GridAddress(row: 2, column: 0)) == "fill seed", "右下角填充柄拖拽失败")
            handleEditor.reapplyLastFill(.sequence)
            try require(handleEditor.lastFill?.mode == .sequence &&
                        handleEditor.inputText(GridAddress(row: 2, column: 0)) == "fill seed",
                        "展开填充选项后切换模式失败")
            let fillOptions = FillOptionsViewController(model: handleEditor, onFinish: {})
            _ = fillOptions.view
            let optionButtons = fillOptions.view.subviews.compactMap { $0 as? NSButton }
            try require(fillOptions.preferredContentSize == FillOptionsViewController.contentSize &&
                        optionButtons.count == 2 && optionButtons.allSatisfy { ($0.font?.pointSize ?? 0) >= 13 } &&
                        optionButtons.allSatisfy { $0.frame.minX >= 10 },
                        "填充选项浮窗布局、文字字号或左侧留白不符合设计")
            handleEditor.select(row: 0, column: 0, extending: false)
            handleGrid.update()
            handleGrid.regions[0].scroll.contentView.scroll(to: NSPoint(x: 100, y: 160))
            handleGrid.regions[0].scroll.reflectScrolledClipView(handleGrid.regions[0].scroll.contentView)
            let singleScrollOrigin = handleGrid.regions[0].scroll.contentView.bounds.origin
            _ = handleEditor.fillSelection(to: 12, targetColumn: 0, mode: .copy)
            handleGrid.update()
            let singleScrollAfterFill = handleGrid.regions[0].scroll.contentView.bounds.origin
            try require(abs(singleScrollAfterFill.x - singleScrollOrigin.x) < 1 &&
                        abs(singleScrollAfterFill.y - singleScrollOrigin.y) < 1,
                        "单表填充后滚动位置跳回顶部")
            handleEditor.select(row: 0, column: 0, extending: false)
            handleGrid.update(); handleWindow.makeFirstResponder(handleTable)
            func sendDirect(_ text: String) {
                let directKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: handleWindow.windowNumber, context: nil, characters: text,
                    charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0)!
                handleTable.keyDown(with: directKey)
            }
            sendDirect("直"); sendDirect("接"); sendDirect("替"); sendDirect("换")
            try require(handleEditor.inputText(GridAddress(row: 0, column: 0)) == "直接替换", "单击后键盘直接替换单元格失败")
            handleTable.endDirectTyping()
            sendDirect("1"); sendDirect("2")
            try require(handleEditor.inputText(GridAddress(row: 0, column: 0)) == "12", "连续数字输入首字符被吞掉")
            handleTable.endDirectTyping()
            handleTable.setMarkedText("1", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
            handleTable.setMarkedText("2", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
            try require(handleEditor.inputText(GridAddress(row: 0, column: 0)) == "12" &&
                        !handleTable.hasMarkedText(), "输入法组合入口连续数字输入首字符被吞掉")
            handleTable.endDirectTyping()
            func clickDataCell(_ dataColumn: Int, row: Int) {
                let localColumn = dataColumn + 1 // local column 0 is the row-number column.
                let cell = handleTable.frameOfCell(atColumn: localColumn, row: row)
                let point = handleTable.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
                let click = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: handleWindow.windowNumber, context: nil, eventNumber: 10 + dataColumn, clickCount: 1, pressure: 1)!
                handleTable.mouseDown(with: click)
            }
            func sendWindowDirect(_ text: String) {
                let directKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: handleWindow.windowNumber, context: nil, characters: text,
                    charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0)!
                handleWindow.sendEvent(directKey)
            }
            for dataColumn in 0...2 {
                clickDataCell(dataColumn, row: 10)
                sendDirect("1"); sendDirect("2")
                try require(handleEditor.inputText(GridAddress(row: 10, column: dataColumn)) == "12",
                            "第 \(dataColumn + 1) 列连续数字输入首字符被吞掉")
                handleTable.endDirectTyping()
            }
            handleTable.scrollRowToVisible(200)
            handleGrid.layoutSubtreeIfNeeded()
            clickDataCell(1, row: 200) // B201 is zero-based row 200.
            sendWindowDirect("1")
            // A newly edited row changes the virtual table extent. This is
            // the exact case where a SwiftUI/AppKit refresh used to rebuild
            // the table between the first and second digit.
            handleGrid.update(); handleGrid.layoutSubtreeIfNeeded()
            sendWindowDirect("2")
            try require(handleEditor.inputText(GridAddress(row: 200, column: 1)) == "12",
                        "B201 在刷新表格后连续数字输入首字符被吞掉")
            handleTable.endDirectTyping()
            let exactB201Snapshot = try GridWorkbookIO.read(original)
            let exactB201Editor = GridEditorModel(); exactB201Editor.snapshot = exactB201Snapshot
            exactB201Editor.select(row: 200, column: 1, extending: false)
            let exactB201Grid = FrozenGridView(exactB201Editor)
            let exactB201Window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            exactB201Window.contentView = exactB201Grid; exactB201Window.makeKeyAndOrderFront(nil)
            exactB201Grid.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
            exactB201Grid.layoutSubtreeIfNeeded(); exactB201Grid.update(); exactB201Grid.layoutSubtreeIfNeeded()
            let exactB201Table = exactB201Grid.regions[0].table
            exactB201Table.scrollRowToVisible(200); exactB201Grid.layoutSubtreeIfNeeded()
            let exactB201Cell = exactB201Table.frameOfCell(atColumn: 2, row: 200)
            let exactB201Point = exactB201Table.convert(NSPoint(x: exactB201Cell.midX, y: exactB201Cell.midY), to: nil)
            let exactB201Click = NSEvent.mouseEvent(with: .leftMouseDown, location: exactB201Point, modifierFlags: [], timestamp: 0,
                windowNumber: exactB201Window.windowNumber, context: nil, eventNumber: 40, clickCount: 1, pressure: 1)!
            exactB201Table.mouseDown(with: exactB201Click)
            func sendExactB201(_ text: String) {
                let directKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: exactB201Window.windowNumber, context: nil, characters: text,
                    charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0)!
                exactB201Window.sendEvent(directKey)
            }
            sendExactB201("1")
            exactB201Grid.update(); exactB201Grid.layoutSubtreeIfNeeded()
            sendExactB201("2")
            try require(exactB201Editor.inputText(GridAddress(row: 200, column: 1)) == "12",
                        "原始 TbDecorationModule.xlsx 的 B201 连续数字输入首字符被吞掉")
            exactB201Window.orderOut(nil)
            handleEditor.select(row: 0, column: 0, extending: false)
            handleGrid.update(); handleWindow.makeFirstResponder(handleTable)
            handleTable.setMarkedText("jiang", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: 0, length: 0))
            try require(handleTable.hasMarkedText() && handleTable.markedRange() == NSRange(location: 0, length: 5),
                        "输入法拼音组合状态未保留")
            handleTable.insertText("奖", replacementRange: NSRange(location: 0, length: 5))
            handleTable.insertText("励1", replacementRange: NSRange(location: 1, length: 0))
            try require(handleEditor.inputText(GridAddress(row: 0, column: 0)) == "奖励1" &&
                        !handleTable.hasMarkedText(), "中文输入法提交后单元格写入失败")
            // Restore the direct-entry value before the independent undo test.
            handleEditor.edit([GridAddress(row: 0, column: 0): "直接替换"])
            handleEditor.edit([GridAddress(row: 0, column: 0): "one"])
            handleEditor.edit([GridAddress(row: 0, column: 0): "two"])
            handleEditor.edit([GridAddress(row: 0, column: 0): "three"])
            func sendUndo() {
                let undo = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                    windowNumber: handleWindow.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z",
                    isARepeat: false, keyCode: 6)!
                handleTable.keyDown(with: undo); handleGrid.update()
            }
            sendUndo(); try require(handleEditor.inputText(GridAddress(row: 0, column: 0)) == "two", "第一次连续撤回失败")
            sendUndo(); try require(handleEditor.inputText(GridAddress(row: 0, column: 0)) == "one", "第二次连续撤回失败")
            sendUndo(); try require(handleEditor.inputText(GridAddress(row: 0, column: 0)) == "直接替换", "第三次连续撤回失败")
            let frozenInputEditor = GridEditorModel(); frozenInputEditor.snapshot = handleSnapshot
            frozenInputEditor.frozenColumns = 2
            frozenInputEditor.select(row: 10, column: 0, extending: false)
            let frozenInputGrid = FrozenGridView(frozenInputEditor)
            let frozenInputWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            frozenInputWindow.contentView = frozenInputGrid; frozenInputWindow.makeKeyAndOrderFront(nil)
            frozenInputGrid.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
            frozenInputGrid.layoutSubtreeIfNeeded(); frozenInputGrid.update(); frozenInputGrid.layoutSubtreeIfNeeded()
            for dataColumn in 0...2 {
                guard let region = frozenInputGrid.regions.first(where: {
                    $0.range.contains(10) && $0.table.tableColumns.contains { $0.identifier.rawValue == String(dataColumn) }
                }), let localColumn = region.table.tableColumns.firstIndex(where: { $0.identifier.rawValue == String(dataColumn) }) else {
                    throw WorkspaceError(message: "冻结列输入测试找不到第 \(dataColumn + 1) 列")
                }
                let cell = region.table.frameOfCell(atColumn: localColumn, row: 10 - region.range.lowerBound)
                let point = region.table.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
                let click = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: frozenInputWindow.windowNumber, context: nil, eventNumber: 20 + dataColumn, clickCount: 1, pressure: 1)!
                region.table.mouseDown(with: click)
                region.table.setMarkedText("1", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
                region.table.setMarkedText("2", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
                try require(frozenInputEditor.inputText(GridAddress(row: 10, column: dataColumn)) == "12",
                            "冻结列第 \(dataColumn + 1) 列连续数字输入首字符被吞掉")
                region.table.endDirectTyping()
            }
            frozenInputWindow.orderOut(nil)
            handleWindow.orderOut(nil)
            let workspace = TableWorkspaceModel()
            let testWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            testWindow.contentView = grid
            testWindow.makeKeyAndOrderFront(nil)
            grid.layoutSubtreeIfNeeded()
            let tableView = grid.regions[0].table
            let rect = tableView.frameOfCell(atColumn: 2, row: 5)
            let point = tableView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let click = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: testWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1)!
            tableView.mouseDown(with: click)
            grid.update()
            try require(tableView.editedRow == 5 && tableView.currentEditor() != nil, "双击后刷新销毁了单元格编辑器")
            tableView.currentEditor()?.string = "double-click edited"
            testWindow.makeFirstResponder(nil)
            try require(editor.inputText(GridAddress(row: 5, column: 1)) == "double-click edited", "单元格编辑提交失败")
            editor.setZoom(1.5); grid.update()
            let scaledHeader = grid.regions[0].table.headerView as? GridColumnHeader
            let firstHeaderFontSize = grid.regions[0].table.tableColumns.first?.headerCell.font?.pointSize ?? 0
            let scaledColumnWidth = grid.regions[0].table.tableColumns[1].width
            let scaledRowHeight = grid.regions[0].table.rect(ofRow: 5).height
            try require(abs(grid.regions[0].scroll.magnification - 1) < 0.01 &&
                        abs((scaledHeader?.appliedZoom ?? 0) - 1.5) < 0.01 &&
                        abs((scaledHeader?.frame.height ?? 0) - 34.5) < 0.5 &&
                        abs(firstHeaderFontSize - 18) < 0.5 &&
                        abs(scaledColumnWidth - 210) < 0.5 &&
                        abs(scaledRowHeight - (editor.displayRowHeight(5) + 1) * 1.5) < 0.5,
                        "表格缩放或字母表头同步缩放未生效")
            editor.setZoom(1); grid.update()
            testWindow.orderOut(nil)
            print("实际双击事件、编辑器保留、文本提交、150% 缩放与重置通过")
            print("自适应：列宽限幅、长文本行高封顶、内容完整保留、恢复默认、冻结区一致与换行模式下双击编辑通过")
            try require(!workspace.split, "多表并排默认状态应为关闭")
            workspace.split = false
            func previewTable(_ suffix: String) -> ProjectTable {
                ProjectTable(projectID: "test", projectDisplayPath: "test", fileURL: root.appendingPathComponent(suffix),
                             relativeDataPath: suffix, byteCount: 0, modifiedAt: nil)
            }
            let first = previewTable("first.xlsx"), second = previewTable("second.xlsx"), third = previewTable("third.xlsx")
            workspace.preview(first); workspace.preview(second)
            try require(workspace.openIDs == [second.id], "预览模式重复开表")
            workspace.editor(second.id)?.changes = [GridAddress(row: 0, column: 0): "unsaved"]
            workspace.preview(third)
            try require(workspace.openIDs == [second.id, third.id], "预览覆盖未保存编辑")
            print("冻结坐标、滚动同步、取消冻结、整行整列选择复制、预览复用与未保存保护通过")
            let draft = SavedTranslationDraft(key: "test_key", originals: ["en": ""], translations: ["en": "draft"])
            try TranslationDraftStore.save([draft], for: file)
            try require(TranslationDraftStore.load(for: file).first?.translations["en"] == "draft", "翻译草稿恢复失败")
            try TranslationDraftStore.save([], for: file)
            try require(TranslationDraftStore.load(for: file).isEmpty, "保存后草稿未清除")
            let finalOriginal = try Data(contentsOf: original)
            try require(finalOriginal == originalData, "真实源表被修改")
            print("\(original.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)：\(updates.count) 格写入 / 非目标格与工作簿部件保留 / ZIP 完整 / 外部变化拦截 / 撤销重做 / 草稿恢复通过")
        }
        print("工作区回归全部通过；所有项目源表未改。")
    }
}
#endif
