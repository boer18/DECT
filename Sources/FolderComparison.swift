import AppKit
import Combine
import Foundation
import SwiftUI

enum ComparisonStatus: String, CaseIterable {
    case changed = "修改", added = "新增", removed = "删除", same = "相同", failed = "未完成"
    var color: Color {
        switch self { case .changed: return .purple; case .added: return .green; case .removed: return .red; case .same: return .secondary; case .failed: return .orange }
    }
}
struct CellDifference: Identifiable {
    let id: String
    let sheet: String
    let location: String
    let key: String
    let old: String?
    let new: String?
    var status: ComparisonStatus { old == nil ? .added : new == nil ? .removed : .changed }
}
struct ComparedFile: Identifiable {
    let relativePath: String
    let oldURL: URL?
    let newURL: URL?
    let status: ComparisonStatus
    let differences: [CellDifference]
    let note: String
    let oldSheets: [ComparedSheet]
    let newSheets: [ComparedSheet]
    var id: String { relativePath }
}
struct ComparedSheet {
    let name: String
    let cells: [GridAddress: GridCell]
    let rowCount: Int
    let columnCount: Int
    init(name: String, cells: [GridAddress: GridCell], rowCount: Int? = nil, columnCount: Int? = nil) {
        self.name = name
        self.cells = cells
        let inferredRows = (cells.keys.map(\.row).max() ?? 0) + 1
        let inferredColumns = (cells.keys.map(\.column).max() ?? 0) + 1
        self.rowCount = max(1, rowCount ?? inferredRows)
        self.columnCount = max(1, columnCount ?? inferredColumns)
    }
}

enum ComparisonCellKind: Equatable {
    case same, added, removed, modified
    var color: Color {
        switch self { case .same: return .clear; case .added: return .green; case .removed: return .red; case .modified: return .purple }
    }
    var nsHeaderColor: NSColor {
        switch self {
        case .same: return .controlBackgroundColor
        case .added: return NSColor.systemGreen.withAlphaComponent(0.24)
        case .removed: return NSColor.systemRed.withAlphaComponent(0.24)
        case .modified: return NSColor.systemPurple.withAlphaComponent(0.24)
        }
    }
    var nsCellColor: NSColor {
        switch self {
        case .same: return .clear
        case .added: return NSColor.systemGreen.withAlphaComponent(0.14)
        case .removed: return NSColor.systemRed.withAlphaComponent(0.14)
        case .modified: return NSColor.systemPurple.withAlphaComponent(0.14)
        }
    }
    var label: String {
        switch self { case .same: return "无变化"; case .added: return "新增"; case .removed: return "删除"; case .modified: return "修改" }
    }
}

struct ComparisonTableProjection {
    let oldSheet: ComparedSheet?
    let newSheet: ComparedSheet?
    let rowCount: Int
    let columnCount: Int
    private let marks: [GridAddress: ComparisonCellKind]
    private let rowMarks: [Int: ComparisonCellKind]
    private let columnMarks: [Int: ComparisonCellKind]

    init(file: ComparedFile, sheetName: String) {
        let oldSheet = file.oldSheets.first { $0.name == sheetName }
        let newSheet = file.newSheets.first { $0.name == sheetName }
        self.oldSheet = oldSheet
        self.newSheet = newSheet
        self.rowCount = max(oldSheet?.rowCount ?? 1, newSheet?.rowCount ?? 1)
        self.columnCount = max(oldSheet?.columnCount ?? 1, newSheet?.columnCount ?? 1)
        var marks: [GridAddress: ComparisonCellKind] = [:]
        for difference in file.differences where difference.sheet == sheetName {
            let kind: ComparisonCellKind = difference.status == .added ? .added
                : difference.status == .removed ? .removed : .modified
            let references = difference.location
                .replacingOccurrences(of: "→", with: " ")
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .compactMap { GridAddress(String($0)) }
            if references.isEmpty && difference.location == "整张工作表" {
                let cells = kind == .added ? (newSheet?.cells ?? [:]) : (oldSheet?.cells ?? [:])
                for address in cells.keys { marks[address] = Self.combined(marks[address], kind) }
            } else {
                for address in references { marks[address] = Self.combined(marks[address], kind) }
            }
        }
        var rowMarks: [Int: ComparisonCellKind] = [:]
        var columnMarks: [Int: ComparisonCellKind] = [:]
        for (address, kind) in marks {
            rowMarks[address.row] = Self.combined(rowMarks[address.row], kind)
            columnMarks[address.column] = Self.combined(columnMarks[address.column], kind)
        }
        self.marks = marks
        self.rowMarks = rowMarks
        self.columnMarks = columnMarks
    }

    static func combined(_ existing: ComparisonCellKind?, _ incoming: ComparisonCellKind) -> ComparisonCellKind {
        guard let existing else { return incoming }
        if existing == .same { return incoming }
        if incoming == .same { return existing }
        if existing == incoming { return existing }
        return .modified
    }
    func kind(at address: GridAddress) -> ComparisonCellKind { marks[address] ?? .same }
    func oldText(at address: GridAddress) -> String { oldSheet?.cells[address]?.text ?? "" }
    func newText(at address: GridAddress) -> String { newSheet?.cells[address]?.text ?? "" }
    func matches(_ address: GridAddress, query: String) -> Bool {
        guard !query.isEmpty else { return false }
        return "\(address.reference) \(oldText(at: address)) \(newText(at: address))".localizedCaseInsensitiveContains(query)
    }
    func rowKind(_ row: Int) -> ComparisonCellKind {
        rowMarks[row] ?? .same
    }
    func columnKind(_ column: Int) -> ComparisonCellKind {
        columnMarks[column] ?? .same
    }
}
final class ComparisonCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { lock.lock(); let value = cancelled; lock.unlock(); if value { throw CancellationError() } }
}

enum FolderComparer {
    static func catalog(_ root: URL) throws -> [String: URL] {
        let scanRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceError(message: "目录不存在或无法访问：\(root.path)")
        }
        var traversalError: Error?
        guard let enumerator = FileManager.default.enumerator(at: scanRoot, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in traversalError = error; return false }) else {
            throw WorkspaceError(message: "无法读取所选文件夹。")
        }
        var files: [String: URL] = [:]
        for case let url as URL in enumerator {
            guard !url.lastPathComponent.hasPrefix("~$"), ["xlsx", "xlsm", "xls", "csv", "tsv", "ods"].contains(url.pathExtension.lowercased()),
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let components = url.standardizedFileURL.pathComponents
            files[components.dropFirst(scanRoot.pathComponents.count).joined(separator: "/")] = url
        }
        if let traversalError { throw traversalError }
        return files
    }
    static func readSheets(_ file: URL, cancellation: ComparisonCancellation) throws -> [ComparedSheet] {
        let ext = file.pathExtension.lowercased()
        if ext == "csv" || ext == "tsv" {
            let data = try Data(contentsOf: file)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                throw WorkspaceError(message: "无法识别文本编码，请转换为 UTF-8 后对比。")
            }
            let records = delimited(text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")), separator: ext == "csv" ? "," : "\t")
            var cells: [GridAddress: GridCell] = [:]
            for (r, row) in records.enumerated() { for (c, text) in row.enumerated() where !text.isEmpty {
                cells[GridAddress(row: r, column: c)] = GridCell(text: text, formula: false, valueKind: "text")
            } }
            return [ComparedSheet(name: "数据", cells: cells,
                                  rowCount: max(1, records.count),
                                  columnCount: max(1, records.map(\.count).max() ?? 1))]
        }
        guard ext == "xlsx" || ext == "xlsm" else {
            throw WorkspaceError(message: "此格式暂不支持数据级对比，请转换为 .xlsx。该文件未计为相同。")
        }
        let fingerprint = try GridWorkbookIO.fingerprint(file)
        let workbook = try GridWorkbookIO.document(GridWorkbookIO.entry("xl/workbook.xml", in: file))
        let relations = try GridWorkbookIO.document(GridWorkbookIO.entry("xl/_rels/workbook.xml.rels", in: file))
        var paths: [String: String] = [:]
        for relation in GridWorkbookIO.elements(relations.rootElement()!, "Relationship") {
            guard let id = relation.attribute(forName: "Id")?.stringValue, let path = relation.attribute(forName: "Target")?.stringValue,
                  relation.attribute(forName: "TargetMode")?.stringValue != "External" else { continue }
            let normalized = URL(fileURLWithPath: path.hasPrefix("/") ? path : "/xl/" + path).standardizedFileURL.path
            if normalized.hasPrefix("/xl/worksheets/") { paths[id] = String(normalized.dropFirst()) }
        }
        let shared = (try? GridWorkbookIO.entry("xl/sharedStrings.xml", in: file)).map(SharedStringsParser.parse) ?? []
        var sheets: [ComparedSheet] = []
        for case let sheet as XMLElement in try workbook.nodes(forXPath: "//*[local-name()='sheets']/*[local-name()='sheet']") {
            try cancellation.check()
            guard let name = sheet.attribute(forName: "name")?.stringValue,
                  let id = sheet.attributes?.first(where: { $0.localName == "id" })?.stringValue, let path = paths[id] else {
                throw WorkspaceError(message: "工作表关联缺失，无法完整对比。")
            }
            let data = try GridWorkbookIO.entry(path, in: file)
            let values = try SheetRowsParser.parse(data, sharedStrings: shared)
            let xml = try GridWorkbookIO.document(data)
            var cells: [GridAddress: GridCell] = [:], maxRow = 0, maxColumn = 0
            for case let node as XMLElement in try xml.nodes(forXPath: "//*[local-name()='sheetData']/*[local-name()='row']/*[local-name()='c']") {
                guard let ref = node.attribute(forName: "r")?.stringValue, let address = GridAddress(ref) else { continue }
                let value = values[address.row + 1]?[address.column] ?? ""
                let formulaNode = GridWorkbookIO.elements(node, "f").first
                if !value.isEmpty || formulaNode != nil {
                    let kind = node.attribute(forName: "t")?.stringValue ?? "n"
                    cells[address] = GridCell(text: value, formula: formulaNode != nil, formulaText: formulaNode?.xmlString,
                        valueKind: ["s", "inlineStr", "str"].contains(kind) ? "text" : kind)
                    maxRow = max(maxRow, address.row); maxColumn = max(maxColumn, address.column)
                }
            }
            sheets.append(ComparedSheet(name: name, cells: cells,
                                        rowCount: maxRow + 1, columnCount: maxColumn + 1))
        }
        guard try GridWorkbookIO.fingerprint(file) == fingerprint else { throw WorkspaceError(message: "对比期间文件已变化，请重新对比。") }
        return sheets
    }
    static func delimited(_ text: String, separator: Character) -> [[String]] {
        if separator == "\t" { return GridClipboard.decode(text) }
        var rows: [[String]] = [], row: [String] = [], value = "", quoted = false, i = 0
        let normalized = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        while i < normalized.count {
            let c = normalized[i]
            if c == "\"" && (quoted || value.isEmpty) {
                if quoted && i + 1 < normalized.count && normalized[i + 1] == "\"" { value.append(c); i += 1 }
                else { quoted.toggle() }
            } else if !quoted && c == separator { row.append(value); value = "" }
            else if !quoted && c == "\n" { row.append(value); rows.append(row); row = []; value = "" }
            else { value.append(c) }
            i += 1
        }
        if !row.isEmpty || !value.isEmpty || rows.isEmpty { row.append(value); rows.append(row) }
        return rows
    }
    static func keyedRows(_ sheet: ComparedSheet) -> (column: Int, rows: [String: Int], metadata: Set<Int>)? {
        let headers = sheet.cells.filter { $0.key.row == 0 }
        guard let header = headers.first(where: { $0.value.text.lowercased() == "key" }) ?? headers.first(where: { $0.value.text.lowercased() == "id" }) else { return nil }
        var rows: [String: Int] = [:], metadata: Set<Int> = [0]
        let rowNumbers = Set(sheet.cells.keys.map(\.row)).sorted()
        for row in rowNumbers where row > 0 {
            let marker = sheet.cells[GridAddress(row: row, column: 0)]?.text ?? ""
            if marker.hasPrefix("##") { metadata.insert(row); continue }
            guard let key = sheet.cells[GridAddress(row: row, column: header.key.column)]?.text, !key.isEmpty, rows[key] == nil else { return nil }
            rows[key] = row
        }
        return (header.key.column, rows, metadata)
    }
    static func diff(_ old: ComparedSheet?, _ new: ComparedSheet?, alignKeys: Bool) -> ([CellDifference], Bool) {
        let name = new?.name ?? old?.name ?? "", lhs = old?.cells ?? [:], rhs = new?.cells ?? [:]
        var pairs: [(String, Int?, Int?)] = [], aligned = false
        if alignKeys, let old, let new, let a = keyedRows(old), let b = keyedRows(new), a.column == b.column {
            aligned = true
            for row in a.metadata.union(b.metadata).sorted() { pairs.append(("", a.metadata.contains(row) ? row : nil, b.metadata.contains(row) ? row : nil)) }
            for key in Set(a.rows.keys).union(b.rows.keys).sorted() { pairs.append((key, a.rows[key], b.rows[key])) }
        } else {
            for row in Set(lhs.keys.map(\.row)).union(rhs.keys.map(\.row)).sorted() { pairs.append(("", row, row)) }
        }
        let oldRows = Dictionary(grouping: lhs.keys, by: \.row), newRows = Dictionary(grouping: rhs.keys, by: \.row)
        var result: [CellDifference] = []
        for (key, oldRow, newRow) in pairs {
            let columns = Set((oldRow.flatMap { oldRows[$0] } ?? []).map(\.column)).union((newRow.flatMap { newRows[$0] } ?? []).map(\.column))
            for column in columns.sorted() {
                let a = oldRow.flatMap { lhs[GridAddress(row: $0, column: column)] }, b = newRow.flatMap { rhs[GridAddress(row: $0, column: column)] }
                guard a?.text != b?.text || a?.formulaText != b?.formulaText || a?.valueKind != b?.valueKind else { continue }
                let oldRef = oldRow.map { GridAddress(row: $0, column: column).reference } ?? "—"
                let newRef = newRow.map { GridAddress(row: $0, column: column).reference } ?? "—"
                func display(_ cell: GridCell?) -> String? {
                    cell.map { $0.text + ($0.formula ? "\n公式：\($0.formulaText ?? "")" : "") + (a?.valueKind != b?.valueKind && a != nil && b != nil ? " [\($0.valueKind)]" : "") }
                }
                result.append(CellDifference(id: "\(name)/\(oldRef)/\(newRef)", sheet: name,
                    location: oldRef == newRef ? oldRef : "\(oldRef) → \(newRef)", key: key, old: display(a), new: display(b)))
            }
        }
        return (result, aligned)
    }
    static func compare(path: String, oldURL: URL?, newURL: URL?, alignKeys: Bool, cancellation: ComparisonCancellation) -> ComparedFile {
        do {
            try cancellation.check()
            var old = try oldURL.map { try readSheets($0, cancellation: cancellation) } ?? []
            var new = try newURL.map { try readSheets($0, cancellation: cancellation) } ?? []
            for i in old.indices {
                try cancellation.check()
                if let j = new.firstIndex(where: { $0.name == old[i].name }) {
                    let aligned = TableAlignment.align(old[i], new[j])
                    old[i] = aligned.0; new[j] = aligned.1
                }
            }
            var differences: [CellDifference] = [], notes: [String] = []
            for name in Set(old.map(\.name)).union(new.map(\.name)).sorted() {
                try cancellation.check()
                let a = old.first { $0.name == name }, b = new.first { $0.name == name }
                let (delta, aligned) = diff(a, b, alignKeys: alignKeys)
                differences += delta
                if a == nil || b == nil {
                    notes.append("\(a == nil ? "新增" : "删除")工作表：\(name)")
                    if delta.isEmpty { differences.append(CellDifference(id: "sheet/\(name)", sheet: name, location: "整张工作表", key: "", old: a == nil ? nil : "空工作表", new: b == nil ? nil : "空工作表")) }
                } else if alignKeys { notes.append("\(name)：\(aligned ? "按唯一 ID/key 对齐" : "按位置对比（无有效唯一 ID/key）")") }
            }
            let status: ComparisonStatus = oldURL == nil ? .added : newURL == nil ? .removed : differences.isEmpty ? .same : .changed
            return ComparedFile(relativePath: path, oldURL: oldURL, newURL: newURL, status: status,
                                differences: differences, note: notes.joined(separator: "；"),
                                oldSheets: old, newSheets: new)
        } catch {
            return ComparedFile(relativePath: path, oldURL: oldURL, newURL: newURL, status: .failed,
                                differences: [], note: error is CancellationError ? "已停止，未完成对比" : error.localizedDescription,
                                oldSheets: [], newSheets: [])
        }
    }
}

@MainActor
final class FolderComparisonModel: ObservableObject {
    private static let sourceModeDefaultsKey = "comparisonSourceMode"
    @Published var oldRoot: URL? = UserDefaults.standard.string(forKey: "comparisonOldRoot").map { URL(fileURLWithPath: $0) }
    @Published var newRoot: URL? = UserDefaults.standard.string(forKey: "comparisonNewRoot").map { URL(fileURLWithPath: $0) }
    @Published var sourceMode: ComparisonSourceMode
    @Published var files: [ComparedFile] = []
    @Published var selectedID: String?
    @Published var onlyDifferences = true
    @Published var query = ""
    @Published var sheetFilter = "全部工作表"
    @Published var cellQuery = ""
    @Published var alignKeys = false
    @Published var isRunning = false
    @Published var progress = 0.0
    @Published var status = "选择历史版本和当前版本的配置表目录。"
    @Published var page = 0
    @Published var checkedFileIDs = Set<String>()
    @Published var comparisonZoom: CGFloat = 1.0
    @Published private(set) var gitRepository: GitRepositoryInfo?
    @Published private(set) var gitBranches: [GitBranch] = []
    @Published private(set) var gitCommits: [GitCommit] = []
    @Published var selectedGitBranchRef = ""
    @Published var selectedGitCommitHash = ""
    @Published var gitCommitSelectionMode: GitCommitSelectionMode = .commit
    @Published var gitDate = Date()
    @Published private(set) var isLoadingGitHistory = false
    @Published private(set) var gitError: String?
    private var cancellation = ComparisonCancellation()
    private var projectionCache: [String: [String: ComparisonTableProjection]] = [:]
    private var configuredProjectID: String?
    private var gitRequestToken = UUID()
    private var gitSnapshotRoot: URL?

    init() {
        sourceMode = ComparisonSourceMode(
            rawValue: UserDefaults.standard.string(forKey: Self.sourceModeDefaultsKey) ?? ""
        ) ?? .folders
        status = sourceMode == .gitHistory
            ? "选择当前项目和 Git 历史提交。"
            : "选择历史版本和当前版本的配置表目录。"
    }

    var selected: ComparedFile? { files.first { $0.id == selectedID } }
    var selectedGitCommit: GitCommit? {
        switch gitCommitSelectionMode {
        case .commit:
            return gitCommits.first { $0.hash == selectedGitCommitHash }
        case .date:
            return gitCommits.first { $0.date <= gitDate }
        }
    }
    var canRun: Bool {
        switch sourceMode {
        case .folders:
            return oldRoot != nil && newRoot != nil
        case .gitHistory:
            guard let gitRepository, selectedGitCommit != nil else { return false }
            return FileManager.default.fileExists(atPath: gitRepository.currentDataRoot.path)
        }
    }
    var gitDataRootDescription: String? {
        guard let gitRepository else { return nil }
        return gitRepository.dataRelativePath
    }
    var visibleFiles: [ComparedFile] { files.filter { (!onlyDifferences || $0.status != .same) && (query.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(query)) } }
    var visibleCells: [CellDifference] { selected?.differences.filter {
        (sheetFilter == "全部工作表" || $0.sheet == sheetFilter) && (cellQuery.isEmpty || "\($0.location) \($0.key) \($0.old ?? "") \($0.new ?? "")".localizedCaseInsensitiveContains(cellQuery))
    } ?? [] }
    var reviewFiles: [ComparedFile] { files.filter { $0.status != .same } }
    var checkedCount: Int { reviewFiles.reduce(0) { $0 + (checkedFileIDs.contains($1.id) ? 1 : 0) } }
    var checkedProgress: Double { reviewFiles.isEmpty ? 0 : Double(checkedCount) / Double(reviewFiles.count) }
    var selectedIndex: Int? { selectedID.flatMap { id in files.firstIndex { $0.id == id } } }
    func isChecked(_ file: ComparedFile) -> Bool { checkedFileIDs.contains(file.id) }
    func markSelectedChecked() {
        guard let selectedID, let file = selected else { return }
        guard file.status != .same else { status = "此文件没有差异，无需标记检查。"; return }
        checkedFileIDs.insert(selectedID)
        status = "已检查：\(file.relativePath) · 当前进度 \(checkedCount)/\(reviewFiles.count)"
    }
    func sheetNames(for file: ComparedFile) -> [String] {
        Set(file.oldSheets.map(\.name)).union(file.newSheets.map(\.name)).sorted()
    }
    func choose(old: Bool) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.title = old ? "选择历史版本配置表目录" : "选择当前版本配置表目录"
        panel.directoryURL = old ? oldRoot : newRoot
        if panel.runModal() == .OK, let url = panel.url {
            if old { oldRoot = url } else { newRoot = url }
            UserDefaults.standard.set(url.path, forKey: old ? "comparisonOldRoot" : "comparisonNewRoot")
            files = []; selectedID = nil; checkedFileIDs = []; projectionCache = [:]; status = "目录已更新，请开始对比。"
        }
    }

    private struct ComparisonRoots {
        let old: URL
        let new: URL
        let temporaryRoot: URL?
    }

    func sourceModeDidChange(project: ExportProject?) {
        UserDefaults.standard.set(sourceMode.rawValue, forKey: Self.sourceModeDefaultsKey)
        cancellation.cancel()
        resetComparisonResults()
        gitRequestToken = UUID()
        if sourceMode == .gitHistory {
            status = "选择当前项目和 Git 历史提交。"
            configureGitProject(project)
        } else {
            isLoadingGitHistory = false
            gitError = nil
            configuredProjectID = nil
            if !isRunning { releaseGitSnapshot() }
            status = "选择历史版本和当前版本的配置表目录。"
        }
    }

    func configureGitProject(_ project: ExportProject?) {
        guard sourceMode == .gitHistory else { return }
        let projectID = project?.id
        guard projectID != configuredProjectID || gitRepository == nil else { return }
        configuredProjectID = projectID
        resetComparisonResults()
        if !isRunning { releaseGitSnapshot() }
        gitRepository = nil
        gitBranches = []
        gitCommits = []
        selectedGitBranchRef = ""
        selectedGitCommitHash = ""
        gitError = nil
        guard let project else {
            gitError = "请先在顶部选择项目。"
            status = gitError ?? ""
            return
        }

        let request = UUID()
        gitRequestToken = request
        isLoadingGitHistory = true
        status = "正在读取 Git 历史…"
        DispatchQueue.global(qos: .utility).async {
            do {
                let repository = try GitHistoryProvider.discover(projectURL: project.rootURL)
                let branches = try GitHistoryProvider.branches(repository: repository)
                let reference = branches.first(where: { $0.isCurrent })?.name ?? branches.first?.name ?? ""
                let commits = reference.isEmpty ? [] : try GitHistoryProvider.commits(repository: repository, reference: reference)
                DispatchQueue.main.async {
                    guard self.gitRequestToken == request else { return }
                    self.gitRepository = repository
                    self.gitBranches = branches
                    self.selectedGitBranchRef = reference
                    self.gitCommits = commits
                    self.selectedGitCommitHash = commits.first?.hash ?? ""
                    self.gitError = branches.isEmpty ? "仓库中没有可读取的本地分支或远程分支。" : nil
                    self.isLoadingGitHistory = false
                    self.status = commits.isEmpty
                        ? "已找到 Git 仓库，但所选分支没有影响 Config/Datas 的提交。"
                        : "已读取 \(commits.count) 条配置表历史提交。"
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.gitRequestToken == request else { return }
                    self.gitRepository = nil
                    self.gitBranches = []
                    self.gitCommits = []
                    self.selectedGitBranchRef = ""
                    self.selectedGitCommitHash = ""
                    self.gitError = error.localizedDescription
                    self.isLoadingGitHistory = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func refreshGit(project: ExportProject?) {
        configuredProjectID = nil
        gitRequestToken = UUID()
        configureGitProject(project)
    }

    func selectGitBranch(_ reference: String) {
        guard sourceMode == .gitHistory, let repository = gitRepository, !reference.isEmpty else { return }
        selectedGitBranchRef = reference
        selectedGitCommitHash = ""
        gitCommits = []
        gitError = nil
        let request = UUID()
        gitRequestToken = request
        isLoadingGitHistory = true
        status = "正在读取分支历史…"
        DispatchQueue.global(qos: .utility).async {
            do {
                let commits = try GitHistoryProvider.commits(repository: repository, reference: reference)
                DispatchQueue.main.async {
                    guard self.gitRequestToken == request else { return }
                    self.gitCommits = commits
                    self.selectedGitCommitHash = commits.first?.hash ?? ""
                    self.isLoadingGitHistory = false
                    self.status = commits.isEmpty
                        ? "所选分支没有影响 Config/Datas 的提交。"
                        : "已读取 \(commits.count) 条配置表历史提交。"
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.gitRequestToken == request else { return }
                    self.gitCommits = []
                    self.selectedGitCommitHash = ""
                    self.gitError = error.localizedDescription
                    self.isLoadingGitHistory = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    private func resetComparisonResults() {
        files = []
        selectedID = nil
        checkedFileIDs = []
        projectionCache = [:]
        progress = 0
    }

    private func releaseGitSnapshot() {
        GitHistoryProvider.removeSnapshot(at: gitSnapshotRoot)
        gitSnapshotRoot = nil
    }

    private func installGitSnapshot(_ root: URL) {
        releaseGitSnapshot()
        gitSnapshotRoot = root
    }

    func run() {
        guard !isRunning else { return }
        switch sourceMode {
        case .folders:
            runFolders()
        case .gitHistory:
            runGitHistory()
        }
    }

    private func runFolders() {
        guard let oldRoot, let newRoot else {
            status = "请选择历史版本和当前版本的配置表目录。"
            return
        }
        startComparison(
            initialStatus: "正在扫描文件夹…",
            completionPrefix: "文件夹对比完成") {
                ComparisonRoots(old: oldRoot, new: newRoot, temporaryRoot: nil)
            }
    }

    private func runGitHistory() {
        guard let repository = gitRepository, let commit = selectedGitCommit else {
            status = gitError ?? "请选择当前项目、分支和历史提交。"
            return
        }
        startComparison(
            initialStatus: "正在读取 Git 历史配置表…",
            completionPrefix: "Git 历史对比完成") {
                let snapshot = try GitHistoryProvider.materializeSnapshot(repository: repository, commit: commit)
                return ComparisonRoots(old: snapshot.dataRoot, new: repository.currentDataRoot,
                                       temporaryRoot: snapshot.rootURL)
            }
    }

    private func startComparison(initialStatus: String, completionPrefix: String,
                                 rootsProvider: @escaping () throws -> ComparisonRoots) {
        guard !isRunning else { return }
        let align = alignKeys, token = ComparisonCancellation(); cancellation = token
        isRunning = true
        resetComparisonResults()
        status = initialStatus
        DispatchQueue.global(qos: .userInitiated).async {
            var temporaryRoot: URL?
            do {
                let roots = try rootsProvider()
                temporaryRoot = roots.temporaryRoot
                try token.check()
                if let temporaryRoot {
                    DispatchQueue.main.sync { self.installGitSnapshot(temporaryRoot) }
                }
                let old = try FolderComparer.catalog(roots.old), new = try FolderComparer.catalog(roots.new)
                let paths = Set(old.keys).union(new.keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                for (index, path) in paths.enumerated() {
                    try token.check()
                    let result = FolderComparer.compare(path: path, oldURL: old[path], newURL: new[path], alignKeys: align, cancellation: token)
                    DispatchQueue.main.async {
                        guard self.cancellation === token else { return }
                        self.files.append(result); self.progress = Double(index + 1) / Double(max(1, paths.count))
                        self.status = "\(index + 1)/\(paths.count) · \(path)"
                        if self.selectedID == nil && result.status != .same { self.select(result.id) }
                    }
                }
                DispatchQueue.main.async {
                    guard self.cancellation === token else {
                        if let temporaryRoot, self.gitSnapshotRoot != temporaryRoot { GitHistoryProvider.removeSnapshot(at: temporaryRoot) }
                        return
                    }
                    self.isRunning = false
                    let failed = self.files.filter { $0.status == .failed }.count
                    self.status = paths.isEmpty ? "目录中没有识别到表格文件。" : "\(completionPrefix)：\(paths.count) 个文件 · \(failed) 个未完成 · 仅比较数据、类型和公式，忽略配色等格式"
                    if let temporaryRoot, self.gitSnapshotRoot == temporaryRoot { self.releaseGitSnapshot() }
                    else if let temporaryRoot { GitHistoryProvider.removeSnapshot(at: temporaryRoot) }
                }
            } catch {
                DispatchQueue.main.async {
                    if let temporaryRoot, self.gitSnapshotRoot == temporaryRoot { self.releaseGitSnapshot() }
                    else if let temporaryRoot { GitHistoryProvider.removeSnapshot(at: temporaryRoot) }
                    guard self.cancellation === token else { return }
                    self.isRunning = false
                    self.status = error is CancellationError ? "已停止，当前显示的是部分结果。" : error.localizedDescription
                }
            }
        }
    }
    func stop() { cancellation.cancel(); status = "正在停止对比…" }
    func projection(for file: ComparedFile, sheetName: String) -> ComparisonTableProjection {
        if let cached = projectionCache[file.id]?[sheetName] { return cached }
        let value = ComparisonTableProjection(file: file, sheetName: sheetName)
        projectionCache[file.id, default: [:]][sheetName] = value
        return value
    }
    func setComparisonZoom(_ value: CGFloat) {
        comparisonZoom = min(2.5, max(0.5, value))
    }
    func adjustComparisonZoom(_ delta: CGFloat) {
        setComparisonZoom(comparisonZoom + delta)
    }
    func resetComparisonZoom() {
        comparisonZoom = 1.0
    }
    func select(_ id: String?) {
        selectedID = id; cellQuery = ""; page = 0
        if let file = selected, let firstSheet = sheetNames(for: file).first { sheetFilter = firstSheet }
        else { sheetFilter = "全部工作表" }
    }
    func exportReport() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "配置表版本差异.csv"; panel.allowedFileTypes = ["csv"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var records: [[String]] = [["文件", "状态", "工作表", "位置", "ID/key", "历史值", "当前值", "说明"]]
        for file in files {
            if file.differences.isEmpty { records.append([file.relativePath, file.status.rawValue, "", "", "", "", "", file.note]) }
            for cell in file.differences { records.append([file.relativePath, cell.status.rawValue, cell.sheet, cell.location, cell.key, cell.old ?? "", cell.new ?? "", ""]) }
        }
        do {
            try ("\u{feff}" + records.map { $0.map(quote).joined(separator: ",") }.joined(separator: "\r\n")).write(to: url, atomically: true, encoding: .utf8)
            status = "差异报告已导出。"
        } catch { status = error.localizedDescription }
    }
}

private enum ComparisonCanvasMetrics {
    static let rowHeaderWidth: CGFloat = 54
    static let columnWidth: CGFloat = 150
    static let headerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 58
    static let horizontalInset: CGFloat = 6
    static let verticalInset: CGFloat = 5
}

final class ComparisonTableContentView: NSView {
    private(set) var projection: ComparisonTableProjection?
    private(set) var query = ""
    private(set) var zoom: CGFloat = 1.0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(projection: ComparisonTableProjection, query: String, zoom: CGFloat) {
        self.projection = projection
        self.query = query
        self.zoom = Self.clampedZoom(zoom)
        let width = (ComparisonCanvasMetrics.rowHeaderWidth + CGFloat(projection.columnCount) * ComparisonCanvasMetrics.columnWidth) * self.zoom
        let height = (ComparisonCanvasMetrics.headerHeight + CGFloat(projection.rowCount) * ComparisonCanvasMetrics.rowHeight) * self.zoom
        setFrameSize(NSSize(width: max(1, width), height: max(1, height)))
        needsDisplay = true
    }

    func updateZoom(_ zoom: CGFloat) {
        guard abs(self.zoom - zoom) > 0.0001 else { return }
        self.zoom = Self.clampedZoom(zoom)
        if let projection {
            let width = (ComparisonCanvasMetrics.rowHeaderWidth + CGFloat(projection.columnCount) * ComparisonCanvasMetrics.columnWidth) * self.zoom
            let height = (ComparisonCanvasMetrics.headerHeight + CGFloat(projection.rowCount) * ComparisonCanvasMetrics.rowHeight) * self.zoom
            setFrameSize(NSSize(width: max(1, width), height: max(1, height)))
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let projection, projection.rowCount > 0, projection.columnCount > 0 else { return }

        let scale = Self.clampedZoom(zoom)
        let logicalRect = NSRect(
            x: dirtyRect.minX / scale,
            y: dirtyRect.minY / scale,
            width: dirtyRect.width / scale,
            height: dirtyRect.height / scale
        )
        let firstColumn = max(0, Int(floor((logicalRect.minX - ComparisonCanvasMetrics.rowHeaderWidth) / ComparisonCanvasMetrics.columnWidth)) - 1)
        let lastColumn = min(projection.columnCount - 1,
            Int(ceil((logicalRect.maxX - ComparisonCanvasMetrics.rowHeaderWidth) / ComparisonCanvasMetrics.columnWidth)) + 1)
        let firstRow = max(0, Int(floor((logicalRect.minY - ComparisonCanvasMetrics.headerHeight) / ComparisonCanvasMetrics.rowHeight)) - 1)
        let lastRow = min(projection.rowCount - 1,
            Int(ceil((logicalRect.maxY - ComparisonCanvasMetrics.headerHeight) / ComparisonCanvasMetrics.rowHeight)) + 1)

        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.scaleBy(x: scale, y: scale)

        if firstRow <= lastRow, firstColumn <= lastColumn {
            for row in firstRow...lastRow {
                for column in firstColumn...lastColumn {
                    drawCell(projection: projection, row: row, column: column)
                }
            }
        }

        if logicalRect.minY <= ComparisonCanvasMetrics.headerHeight,
           logicalRect.maxY >= 0,
           firstColumn <= lastColumn {
            for column in firstColumn...lastColumn {
                let rect = NSRect(
                    x: ComparisonCanvasMetrics.rowHeaderWidth + CGFloat(column) * ComparisonCanvasMetrics.columnWidth,
                    y: 0,
                    width: ComparisonCanvasMetrics.columnWidth,
                    height: ComparisonCanvasMetrics.headerHeight
                )
                drawHeader(GridAddress.columnName(column), kind: projection.columnKind(column), in: rect)
            }
        }

        if logicalRect.minX <= ComparisonCanvasMetrics.rowHeaderWidth,
           logicalRect.maxX >= 0,
           firstRow <= lastRow {
            for row in firstRow...lastRow {
                let rect = NSRect(
                    x: 0,
                    y: ComparisonCanvasMetrics.headerHeight + CGFloat(row) * ComparisonCanvasMetrics.rowHeight,
                    width: ComparisonCanvasMetrics.rowHeaderWidth,
                    height: ComparisonCanvasMetrics.rowHeight
                )
                drawHeader(String(row + 1), kind: projection.rowKind(row), in: rect)
            }
        }

        if logicalRect.minX <= ComparisonCanvasMetrics.rowHeaderWidth,
           logicalRect.maxX >= 0,
           logicalRect.minY <= ComparisonCanvasMetrics.headerHeight,
           logicalRect.maxY >= 0 {
            drawHeader("行", kind: .same, in: NSRect(x: 0, y: 0,
                width: ComparisonCanvasMetrics.rowHeaderWidth, height: ComparisonCanvasMetrics.headerHeight))
        }
        context?.restoreGState()
    }

    private func drawHeader(_ text: String, kind: ComparisonCellKind, in rect: NSRect) {
        kind.nsHeaderColor.setFill()
        NSBezierPath(rect: rect).fill()
        drawText(text, in: rect.insetBy(dx: 4, dy: 3), color: .labelColor,
                 font: NSFont.systemFont(ofSize: 12, weight: .medium), alignment: .center)
        stroke(rect)
    }

    private func drawCell(projection: ComparisonTableProjection, row: Int, column: Int) {
        let address = GridAddress(row: row, column: column)
        let kind = projection.kind(at: address)
        let rect = NSRect(
            x: ComparisonCanvasMetrics.rowHeaderWidth + CGFloat(column) * ComparisonCanvasMetrics.columnWidth,
            y: ComparisonCanvasMetrics.headerHeight + CGFloat(row) * ComparisonCanvasMetrics.rowHeight,
            width: ComparisonCanvasMetrics.columnWidth,
            height: ComparisonCanvasMetrics.rowHeight
        )
        kind.nsCellColor.setFill()
        NSBezierPath(rect: rect).fill()

        let content = rect.insetBy(dx: ComparisonCanvasMetrics.horizontalInset, dy: ComparisonCanvasMetrics.verticalInset)
        let old = projection.oldText(at: address)
        let new = projection.newText(at: address)
        switch kind {
        case .same:
            drawText(new.isEmpty ? old : new, in: content, color: .labelColor,
                     font: NSFont.systemFont(ofSize: 12))
        case .added:
            drawText("新增", in: NSRect(x: content.minX, y: content.minY,
                width: content.width, height: 14), color: .systemGreen,
                font: NSFont.systemFont(ofSize: 10, weight: .semibold))
            drawText(displayValue(new), in: NSRect(x: content.minX, y: content.minY + 15,
                width: content.width, height: max(1, content.height - 15)), color: .labelColor,
                font: NSFont.systemFont(ofSize: 12))
        case .removed:
            drawText("删除", in: NSRect(x: content.minX, y: content.minY,
                width: content.width, height: 14), color: .systemRed,
                font: NSFont.systemFont(ofSize: 10, weight: .semibold))
            drawText(displayValue(old), in: NSRect(x: content.minX, y: content.minY + 15,
                width: content.width, height: max(1, content.height - 15)), color: .labelColor,
                font: NSFont.systemFont(ofSize: 12))
        case .modified:
            let segment = max(1, (content.height - 4) / 3)
            drawText(displayValue(old), in: NSRect(x: content.minX, y: content.minY,
                width: content.width, height: segment), color: .secondaryLabelColor,
                font: NSFont.systemFont(ofSize: 11))
            drawText("↓", in: NSRect(x: content.minX, y: content.minY + segment,
                width: content.width, height: segment), color: .systemPurple,
                font: NSFont.systemFont(ofSize: 11, weight: .semibold))
            drawText(displayValue(new), in: NSRect(x: content.minX, y: content.minY + segment * 2,
                width: content.width, height: segment), color: .labelColor,
                font: NSFont.systemFont(ofSize: 11))
        }

        if projection.matches(address, query: query) {
            NSColor.systemYellow.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
        }
        stroke(rect)
    }

    private func drawText(_ text: String, in rect: NSRect, color: NSColor,
                          font: NSFont, alignment: NSTextAlignment = .left) {
        guard !text.isEmpty, rect.width > 2, rect.height > 2 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                attributes: attributes, context: nil)
    }

    private func displayValue(_ value: String) -> String {
        value.isEmpty ? "（空）" : value
    }

    private func stroke(_ rect: NSRect) {
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 0.5
        path.stroke()
    }

    private static func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(2.5, max(0.5, value))
    }
}

final class ComparisonCanvasScrollView: NSScrollView {
    private let canvasView = ComparisonTableContentView(frame: .zero)
    private(set) var currentZoom: CGFloat = 1.0
    var zoomHandler: ((CGFloat) -> Void)?
    private var gestureStartZoom: CGFloat = 1.0
    private var contentIdentity = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        documentView = canvasView
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        borderType = .lineBorder
        addGestureRecognizer(NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnification(_:))))
    }

    func update(identity: String, projection: ComparisonTableProjection, query: String, zoom: CGFloat,
                zoomHandler: @escaping (CGFloat) -> Void) {
        self.zoomHandler = zoomHandler
        let targetZoom = Self.clampedZoom(zoom)
        let identityChanged = contentIdentity != identity
        contentIdentity = identity
        let oldZoom = currentZoom
        let center = identityChanged ? NSPoint.zero : logicalViewportCenter(for: oldZoom)
        currentZoom = targetZoom
        canvasView.update(projection: projection, query: query, zoom: targetZoom)
        if identityChanged {
            scrollToOrigin()
        } else if abs(oldZoom - targetZoom) > 0.0001 {
            scrollToLogicalCenter(center)
        } else {
            clampScrollPosition()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        guard delta != 0 else { return }
        let factor = max(0.75, min(1.25, 1 + CGFloat(delta) * 0.025))
        setZoom(currentZoom * factor)
    }

    @objc private func handleMagnification(_ recognizer: NSMagnificationGestureRecognizer) {
        switch recognizer.state {
        case .began:
            gestureStartZoom = currentZoom
        case .changed:
            setZoom(gestureStartZoom * (1 + recognizer.magnification))
        default:
            break
        }
    }

    private func setZoom(_ requested: CGFloat) {
        let targetZoom = Self.clampedZoom(requested)
        guard abs(targetZoom - currentZoom) > 0.0001 else { return }
        let center = logicalViewportCenter(for: currentZoom)
        currentZoom = targetZoom
        canvasView.updateZoom(targetZoom)
        scrollToLogicalCenter(center)
        zoomHandler?(targetZoom)
    }

    private func logicalViewportCenter(for zoom: CGFloat) -> NSPoint {
        let bounds = contentView.bounds
        let scale = max(0.01, zoom)
        return NSPoint(x: bounds.midX / scale, y: bounds.midY / scale)
    }

    private func scrollToLogicalCenter(_ center: NSPoint) {
        layoutSubtreeIfNeeded()
        let bounds = contentView.bounds
        let target = NSPoint(
            x: center.x * currentZoom - bounds.width / 2,
            y: center.y * currentZoom - bounds.height / 2
        )
        let maximum = NSPoint(
            x: max(0, canvasView.frame.width - bounds.width),
            y: max(0, canvasView.frame.height - bounds.height)
        )
        let origin = NSPoint(x: min(max(0, target.x), maximum.x), y: min(max(0, target.y), maximum.y))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    private func clampScrollPosition() {
        let bounds = contentView.bounds
        let maximum = NSPoint(
            x: max(0, canvasView.frame.width - bounds.width),
            y: max(0, canvasView.frame.height - bounds.height)
        )
        let origin = NSPoint(x: min(max(0, bounds.origin.x), maximum.x), y: min(max(0, bounds.origin.y), maximum.y))
        if origin != bounds.origin {
            contentView.scroll(to: origin)
            reflectScrolledClipView(contentView)
        }
    }

    private func scrollToOrigin() {
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    private static func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(2.5, max(0.5, value))
    }
}

struct ComparisonTableCanvas: NSViewRepresentable {
    let identity: String
    let projection: ComparisonTableProjection
    let query: String
    let zoom: CGFloat
    let onZoom: (CGFloat) -> Void

    func makeNSView(context: Context) -> ComparisonCanvasScrollView {
        let view = ComparisonCanvasScrollView(frame: .zero)
        view.update(identity: identity, projection: projection, query: query, zoom: zoom, zoomHandler: onZoom)
        return view
    }

    func updateNSView(_ nsView: ComparisonCanvasScrollView, context: Context) {
        nsView.update(identity: identity, projection: projection, query: query, zoom: zoom, zoomHandler: onZoom)
    }
}

struct ComparisonSheetTableView: View {
    let projection: ComparisonTableProjection
    let identity: String
    let query: String
    let sheetName: String
    let zoom: CGFloat
    let onZoom: (CGFloat) -> Void

    init(identity: String, projection: ComparisonTableProjection, sheetName: String, query: String, zoom: CGFloat,
         onZoom: @escaping (CGFloat) -> Void) {
        self.projection = projection
        self.identity = identity
        self.sheetName = sheetName
        self.query = query
        self.zoom = zoom
        self.onZoom = onZoom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(sheetName).font(.subheadline.weight(.semibold))
                Text("\(projection.rowCount) 行 · \(projection.columnCount) 列")
                    .font(.caption).foregroundStyle(.secondary)
                if projection.oldSheet == nil { Text("仅当前版本").font(.caption).foregroundStyle(.green) }
                if projection.newSheet == nil { Text("仅历史版本").font(.caption).foregroundStyle(.red) }
            }.padding(.bottom, 6)
            ComparisonTableCanvas(identity: identity, projection: projection, query: query, zoom: zoom, onZoom: onZoom)
                .frame(minHeight: 360, idealHeight: 560, maxHeight: 720)
        }
    }
}

struct FolderComparisonView: View {
    @ObservedObject var model: FolderComparisonModel
    let project: ExportProject?
    let openFiles: (URL?, URL?) -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("对比来源", selection: $model.sourceMode) {
                    ForEach(ComparisonSourceMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 220).fixedSize().disabled(model.isRunning)
                Spacer(minLength: 4)
                Button(model.isRunning ? "对比中…" : "开始对比") { model.run() }
                    .buttonStyle(.borderedProminent).disabled(model.isRunning || !model.canRun)
                if model.isRunning { Button("停止") { model.stop() } }
            }.padding(.horizontal, 16).padding(.top, 12)
            HStack(spacing: 12) {
                if model.sourceMode == .folders {
                    folder(old: true); Image(systemName: "arrow.right").foregroundStyle(.secondary); folder(old: false)
                } else {
                    gitSelector
                }
            }.padding(16)
            HStack {
                Toggle("仅看差异", isOn: $model.onlyDifferences).toggleStyle(.checkbox)
                Toggle("按唯一 ID/key 对齐行", isOn: $model.alignKeys).toggleStyle(.checkbox).disabled(model.isRunning).help("默认按内容识别行列增删；启用后进一步按唯一 ID/key 匹配重排的数据行。更改后需重新对比。")
                Spacer()
                Label("已检查 \(model.checkedCount)/\(model.reviewFiles.count)", systemImage: model.checkedCount == model.reviewFiles.count && !model.reviewFiles.isEmpty ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.checkedCount == model.reviewFiles.count && !model.reviewFiles.isEmpty ? .green : .secondary)
                ProgressView(value: model.checkedProgress).frame(width: 100)
                ForEach(ComparisonStatus.allCases, id: \.self) { s in Text("\(s.rawValue) \(model.files.filter { $0.status == s }.count)").foregroundStyle(s.color).font(.caption.monospacedDigit()) }
                Button("导出差异报告") { model.exportReport() }.disabled(model.files.isEmpty || model.isRunning)
            }.padding(.horizontal, 16).padding(.bottom, 12)
            if model.isRunning { ProgressView(value: model.progress).padding(.horizontal, 16) }
            Text(model.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 10)
            Divider()
            GeometryReader { geometry in
                HSplitView {
                    VStack {
                        TextField("搜索文件名或路径", text: $model.query).textFieldStyle(.roundedBorder).padding(10)
                        List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                            ForEach(model.visibleFiles) { file in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(file.relativePath).lineLimit(2).font(.system(size: 12, weight: .medium))
                                        Text("\(file.status.rawValue) · \(file.differences.count) 处差异").font(.caption).foregroundStyle(file.status.color)
                                    }
                                    Spacer()
                                    if model.isChecked(file) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                }.padding(.vertical, 4).tag(file.id)
                            }
                        }
                    }.frame(minWidth: 240, idealWidth: 280, maxWidth: 380, maxHeight: .infinity)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { model.configureGitProject(project) }
        .onChange(of: project?.id) { _, _ in model.configureGitProject(project) }
        .onChange(of: model.sourceMode) { _, _ in model.sourceModeDidChange(project: project) }
        .onChange(of: model.sheetFilter) { _, _ in model.page = 0 }
        .onChange(of: model.cellQuery) { _, _ in model.page = 0 }
    }
    private func folder(old: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(old ? "历史版本" : "当前版本").font(.headline); Button("选择文件夹…") { model.choose(old: old) }.disabled(model.isRunning) }
            Text((old ? model.oldRoot : model.newRoot)?.path ?? "选择包含配置表的文件夹，支持子目录")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var gitSelector: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label("当前项目", systemImage: "shippingbox")
                    .font(.subheadline.weight(.semibold))
                Text(project?.name ?? "未选择项目").foregroundStyle(project == nil ? .secondary : .primary)
                Button { model.refreshGit(project: project) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered).controlSize(.small).disabled(model.isLoadingGitHistory || project == nil)
                if model.isLoadingGitHistory { ProgressView().controlSize(.small) }
            }
            if let repository = model.gitRepository {
                Text("仓库：\(repository.repositoryRoot.path)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text("表目录：\(repository.dataRelativePath)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                Picker("分支", selection: $model.selectedGitBranchRef) {
                    if model.gitBranches.isEmpty { Text("暂无分支").tag("") }
                    ForEach(model.gitBranches) { branch in Text(branch.label).tag(branch.name) }
                }.frame(minWidth: 170, maxWidth: 220)
                    .onChange(of: model.selectedGitBranchRef) { _, value in model.selectGitBranch(value) }
                    .disabled(model.isLoadingGitHistory || model.gitBranches.isEmpty)
                Picker("定位", selection: $model.gitCommitSelectionMode) {
                    ForEach(GitCommitSelectionMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 160).fixedSize()
                if model.gitCommitSelectionMode == .commit {
                    Picker("提交", selection: $model.selectedGitCommitHash) {
                        if model.gitCommits.isEmpty { Text("暂无提交").tag("") }
                        ForEach(model.gitCommits) { commit in
                            Text("\(commit.subject) · \(commit.shortHash) · \(commit.date.formatted(date: .numeric, time: .shortened))").tag(commit.hash)
                        }
                    }.frame(minWidth: 240, maxWidth: 360)
                } else {
                    DatePicker("时间点", selection: $model.gitDate, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.field).labelsHidden().fixedSize()
                }
            }
            if let commit = model.selectedGitCommit {
                Text("历史版本：\(commit.shortHash) · \(commit.dateText) · \(commit.subject)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if let error = model.gitError {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var detail: some View {
        if let file = model.selected {
            let sheetNames = model.sheetNames(for: file)
            let selectedSheet = sheetNames.contains(model.sheetFilter) ? model.sheetFilter : sheetNames.first
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(file.relativePath).font(.headline).lineLimit(1)
                    Spacer()
                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Text("缩放").font(.caption).foregroundStyle(.secondary)
                            Button { model.adjustComparisonZoom(-0.1) } label: {
                                Image(systemName: "minus")
                                    .frame(width: 22, height: 20)
                            }
                            Text("\(Int(model.comparisonZoom * 100))%")
                                .font(.caption.monospacedDigit())
                                .frame(width: 42, height: 20)
                            Button { model.adjustComparisonZoom(0.1) } label: {
                                Image(systemName: "plus")
                                    .frame(width: 22, height: 20)
                            }
                            Button("重置大小") { model.resetComparisonZoom() }
                                .help("恢复为 100%；也可以用触控板捏合，或按住 ⌘ 滚轮缩放")
                        }
                        Button(model.sourceMode == .gitHistory ? "在编辑工作区打开当前表" : "在编辑工作区打开新旧表") {
                            openFiles(model.sourceMode == .gitHistory ? nil : file.oldURL, file.newURL)
                        }
                            .disabled(file.oldURL?.pathExtension.lowercased() != "xlsx" && file.newURL?.pathExtension.lowercased() != "xlsx")
                        Button(model.isChecked(file) ? "已检查" : "标记已检查") { model.markSelectedChecked() }
                            .buttonStyle(.borderedProminent)
                            .tint(model.isChecked(file) ? .green : .accentColor)
                            .disabled(model.isChecked(file))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if !file.note.isEmpty { Text(file.note).font(.caption).foregroundStyle(file.status == .failed ? .red : .secondary).textSelection(.enabled) }
                HStack(spacing: 12) {
                    Label("删除", systemImage: "minus.square.fill").foregroundStyle(.red)
                    Label("新增", systemImage: "plus.square.fill").foregroundStyle(.green)
                    Label("修改", systemImage: "square.fill").foregroundStyle(.purple)
                    Text("内容已对齐；行列号为对齐视图位置。修改显示旧值 ↓ 新值").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let index = model.selectedIndex { Text("文件 \(index + 1)/\(model.files.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }.font(.caption)
                HStack {
                    Picker("工作表", selection: $model.sheetFilter) {
                        Text("全部工作表").tag("全部工作表")
                        ForEach(sheetNames, id: \.self) { Text($0).tag($0) }
                    }.frame(maxWidth: 250)
                    TextField("在完整表格中查找值或位置", text: $model.cellQuery).textFieldStyle(.roundedBorder)
                }
                Divider()
                if sheetNames.isEmpty {
                    ContentUnavailableView("没有可展示的工作表", systemImage: "tablecells", description: Text(file.note))
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if model.sheetFilter == "全部工作表" {
                                ForEach(sheetNames, id: \.self) { name in
                                    ComparisonSheetTableView(identity: "\(file.id)#\(name)", projection: model.projection(for: file, sheetName: name), sheetName: name, query: model.cellQuery,
                                        zoom: model.comparisonZoom, onZoom: { model.setComparisonZoom($0) })
                                }
                            } else if let selectedSheet {
                                ComparisonSheetTableView(identity: "\(file.id)#\(selectedSheet)", projection: model.projection(for: file, sheetName: selectedSheet), sheetName: selectedSheet, query: model.cellQuery,
                                    zoom: model.comparisonZoom, onZoom: { model.setComparisonZoom($0) })
                            }
                        }
                        .padding(14)
                    }
                }
            }.padding(14)
        } else {
            ContentUnavailableView(model.sourceMode == .gitHistory ? "Git 历史对比" : "文件夹版本对比", systemImage: "doc.on.doc", description: Text("匹配相对路径，逐张比较全部工作表的数据和公式。选择左侧文件查看差异。"))
        }
    }
}
