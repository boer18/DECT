import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftUI

struct GridAddress: Hashable, Codable {
    let row: Int
    let column: Int
    var reference: String { "\(Self.columnName(column))\(row + 1)" }
    static func columnName(_ column: Int) -> String {
        var n = column + 1, result = ""
        while n > 0 { n -= 1; result = String(UnicodeScalar(65 + n % 26)!) + result; n /= 26 }
        return result
    }
    init(row: Int, column: Int) { self.row = row; self.column = column }
    init?(_ reference: String) {
        let letters = reference.prefix { $0.isASCII && $0.isLetter }
        guard !letters.isEmpty, let row = Int(reference.dropFirst(letters.count)), row > 0 else { return nil }
        self.row = row - 1
        self.column = letters.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
    }
}

struct GridCell {
    let text: String
    let formula: Bool
    var formulaText: String? = nil
    var valueKind: String = ""
}
struct GridSheet: Identifiable, Hashable {
    let name: String
    let archivePath: String
    var id: String { archivePath }
}
struct GridSnapshot {
    let fileURL: URL
    let fingerprint: Data
    let sheets: [GridSheet]
    let sheet: GridSheet
    let cells: [GridAddress: GridCell]
    let rowCount: Int
    let columnCount: Int
}
enum GridFillMode: Equatable {
    case copy
    case sequence
}
struct GridFillRecord: Identifiable {
    let id = UUID()
    let sourceRows: ClosedRange<Int>
    let sourceColumns: ClosedRange<Int>
    let row: Int
    let column: Int
    let mode: GridFillMode
}
struct WorkspaceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The workbook stays at its original project path. Only edited cells in the
/// selected sheet change; all other ZIP members are carried over byte for byte.
enum GridWorkbookIO {
    static func capture(_ executable: String, _ arguments: [String], directory: URL? = nil) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw WorkspaceError(message: "无法读取或更新工作簿，请确认文件可访问且未被其他应用锁定。") }
        return data
    }
    static func entry(_ path: String, in file: URL) throws -> Data {
        let literal = path.map { "*?[]".contains($0) ? "\\" + String($0) : String($0) }.joined()
        return try capture("/usr/bin/unzip", ["-p", file.path, literal])
    }
    static func fingerprint(_ file: URL) throws -> Data { Data(SHA256.hash(data: try Data(contentsOf: file))) }
    static func document(_ data: Data) throws -> XMLDocument {
        try XMLDocument(data: data, options: [.nodePreserveAll])
    }
    static func elements(_ node: XMLNode, _ name: String) -> [XMLElement] {
        (node.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == name || $0.name == name }
    }
    static func read(_ file: URL, sheetPath: String? = nil) throws -> GridSnapshot {
        guard file.pathExtension.lowercased() == "xlsx" else {
            throw WorkspaceError(message: "内置编辑支持 .xlsx；此格式请使用“外部打开”。")
        }
        let before = try fingerprint(file)
        let workbook = try document(entry("xl/workbook.xml", in: file))
        let relationships = try document(entry("xl/_rels/workbook.xml.rels", in: file))
        var targets: [String: String] = [:]
        for relation in elements(relationships.rootElement()!, "Relationship") {
            guard let id = relation.attribute(forName: "Id")?.stringValue,
                  let target = relation.attribute(forName: "Target")?.stringValue,
                  relation.attribute(forName: "TargetMode")?.stringValue != "External" else { continue }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            let normalized = URL(fileURLWithPath: "/" + path).standardizedFileURL.path.dropFirst()
            if normalized.hasPrefix("xl/worksheets/") { targets[id] = String(normalized) }
        }
        let sheetNodes = try workbook.nodes(forXPath: "//*[local-name()='sheets']/*[local-name()='sheet']")
        let sheets = sheetNodes.compactMap { node -> GridSheet? in
            guard let element = node as? XMLElement, let name = element.attribute(forName: "name")?.stringValue,
                  let id = element.attributes?.first(where: { $0.localName == "id" || $0.name == "r:id" })?.stringValue,
                  let path = targets[id] else { return nil }
            return GridSheet(name: name, archivePath: path)
        }
        guard let sheet = sheets.first(where: { $0.archivePath == sheetPath }) ?? sheets.first else {
            throw WorkspaceError(message: "工作簿中没有可读取的工作表。")
        }
        let shared = (try? entry("xl/sharedStrings.xml", in: file)).map(SharedStringsParser.parse) ?? []
        let sheetData = try entry(sheet.archivePath, in: file)
        let parsedRows = try SheetRowsParser.parse(sheetData, sharedStrings: shared)
        let xml = try document(sheetData)
        let nodes = try xml.nodes(forXPath: "//*[local-name()='sheetData']/*[local-name()='row']/*[local-name()='c']")
        var cells: [GridAddress: GridCell] = [:], maxRow = 0, maxColumn = 0
        for case let cell as XMLElement in nodes {
            guard let reference = cell.attribute(forName: "r")?.stringValue, let address = GridAddress(reference) else { continue }
            // XMLParser expands text entities consistently. XMLDocument with
            // nodePreserveEntities can misreport stringValue around '#...&gt;'
            // on current macOS, even while its serialized XML is correct.
            let text = parsedRows[address.row + 1]?[address.column] ?? ""
            let formula = !elements(cell, "f").isEmpty
            if !text.isEmpty || formula {
                let kind = cell.attribute(forName: "t")?.stringValue ?? "n"
                cells[address] = GridCell(text: text, formula: formula,
                    formulaText: elements(cell, "f").first?.stringValue,
                    valueKind: ["s", "inlineStr", "str"].contains(kind) ? "text" : kind)
            }
            // Ignore format-only tails which Excel can extend to row 1048576.
            if !text.isEmpty || formula { maxRow = max(maxRow, address.row); maxColumn = max(maxColumn, address.column) }
        }
        guard try fingerprint(file) == before else { throw WorkspaceError(message: "读取期间文件发生变化，请重新读取。") }
        return GridSnapshot(fileURL: file, fingerprint: before, sheets: sheets, sheet: sheet, cells: cells,
                            rowCount: maxRow + 1, columnCount: maxColumn + 1)
    }
    static func save(_ snapshot: GridSnapshot, changes: [GridAddress: String], formulaAddresses: Set<GridAddress> = []) throws -> GridSnapshot {
        guard !changes.isEmpty else { return snapshot }
        guard try fingerprint(snapshot.fileURL) == snapshot.fingerprint else {
            throw WorkspaceError(message: "原表已被其他操作修改。当前编辑已保留，请复制需要的内容后重新读取，再核对保存。")
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("TableWorkspace-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let unpacked = root.appendingPathComponent("xlsx"), replacement = root.appendingPathComponent("replacement.xlsx")
        try manager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        _ = try capture("/usr/bin/unzip", ["-q", snapshot.fileURL.path, "-d", unpacked.path])
        let sheetURL = unpacked.appendingPathComponent(snapshot.sheet.archivePath)
        // Reparse the sheet without preserving entity nodes. Re-serializing a
        // document parsed with nodePreserveAll can turn already escaped text
        // such as '&lt;' and '&amp;' into malformed XML on a second save.
        let xml = try XMLDocument(data: Data(contentsOf: sheetURL), options: [])
        guard let sheetData = try xml.nodes(forXPath: "//*[local-name()='sheetData']").first as? XMLElement else {
            throw WorkspaceError(message: "工作表缺少单元格数据区。")
        }
        let prefix = sheetData.prefix.flatMap { $0.isEmpty ? nil : $0 + ":" } ?? ""
        func node(_ name: String) -> XMLElement { XMLElement(name: prefix + name) }
        func textNode(_ element: XMLElement, _ value: String) {
            element.addChild(XMLNode.text(withStringValue: value) as! XMLNode)
        }
        func attribute(_ element: XMLElement, _ name: String, _ value: String) {
            element.removeAttribute(forName: name)
            element.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
        }
        var rows: [Int: XMLElement] = [:]
        for row in elements(sheetData, "row") {
            if let value = row.attribute(forName: "r")?.stringValue, let number = Int(value) { rows[number - 1] = row }
        }
        for (address, rawText) in changes.sorted(by: { ($0.key.row, $0.key.column) < ($1.key.row, $1.key.column) }) {
            guard address.row >= 0, address.row < 1_048_576, address.column >= 0, address.column < 16_384 else {
                throw WorkspaceError(message: "粘贴内容超出了 Excel 支持的范围。")
            }
            let row: XMLElement
            if let existing = rows[address.row] { row = existing }
            else {
                row = node("row"); attribute(row, "r", String(address.row + 1))
                let next = elements(sheetData, "row").first { (Int($0.attribute(forName: "r")?.stringValue ?? "0") ?? 0) > address.row + 1 }
                sheetData.insertChild(row, at: next?.index ?? sheetData.childCount); rows[address.row] = row
            }
            let cell: XMLElement
            if let existing = elements(row, "c").first(where: { $0.attribute(forName: "r")?.stringValue == address.reference }) { cell = existing }
            else {
                cell = node("c"); attribute(cell, "r", address.reference)
                let next = elements(row, "c").first { (GridAddress($0.attribute(forName: "r")?.stringValue ?? "")?.column ?? -1) > address.column }
                row.insertChild(cell, at: next?.index ?? row.childCount)
            }
            for child in (cell.children ?? []).reversed() { child.detach() }
            let value = cleanText(rawText)
            if (formulaAddresses.contains(address) || snapshot.cells[address]?.formula == true), let formula = formulaBody(value) {
                // XLSX stores formulas without the leading '='. Keep a string
                // result type when the original formula used one; otherwise
                // let Excel treat the recalculated result as numeric/general.
                if cell.attribute(forName: "t")?.stringValue == "str" {
                    attribute(cell, "t", "str")
                } else {
                    cell.removeAttribute(forName: "t")
                }
                let formulaNode = node("f")
                textNode(formulaNode, formula)
                let cachedValue = node("v")
                textNode(cachedValue, "")
                cell.addChild(formulaNode); cell.addChild(cachedValue)
            } else {
                // Preserve obvious numerical values as numbers. Leading-zero
                // IDs and text beginning with '=' stay literal strings unless
                // the edited cell was already a formula cell.
                let numeric = value.range(of: "^-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?$", options: .regularExpression) != nil
                    && value.filter(\.isNumber).count <= 15
                if numeric {
                    cell.removeAttribute(forName: "t")
                    let v = node("v"); textNode(v, value); cell.addChild(v)
                } else {
                    attribute(cell, "t", "inlineStr")
                    let inline = node("is"), t = node("t")
                    attribute(t, "xml:space", "preserve"); textNode(t, value)
                    inline.addChild(t); cell.addChild(inline)
                }
            }
        }
        if let dimension = elements(xml.rootElement()!, "dimension").first {
            let maxRow = max(snapshot.rowCount - 1, changes.keys.map(\.row).max() ?? 0)
            let maxColumn = max(snapshot.columnCount - 1, changes.keys.map(\.column).max() ?? 0)
            attribute(dimension, "ref", "A1:\(GridAddress(row: maxRow, column: maxColumn).reference)")
        }
        let data = xml.xmlData(options: [.nodePreserveAll])
        let parser = XMLParser(data: data)
        guard parser.parse() else {
            throw WorkspaceError(message: "单元格校验失败：\(parser.parserError?.localizedDescription ?? "XML 格式无效")，原表未修改。")
        }
        try data.write(to: sheetURL, options: .atomic)
        _ = try capture("/usr/bin/zip", ["-q", "-r", replacement.path, "."], directory: unpacked)
        let validated = try read(replacement, sheetPath: snapshot.sheet.archivePath)
        for (address, text) in changes {
            let clean = cleanText(text)
            if (formulaAddresses.contains(address) || snapshot.cells[address]?.formula == true), let expectedFormula = formulaBody(clean) {
                guard validated.cells[address]?.formula == true,
                      validated.cells[address]?.formulaText == expectedFormula else {
                    throw WorkspaceError(message: "\(address.reference) 公式写入核验失败，原表未修改。")
                }
            } else {
                guard (validated.cells[address]?.text ?? "") == clean,
                      validated.cells[address]?.formula != true else {
                    throw WorkspaceError(message: "\(address.reference) 写入核验失败，原表未修改。")
                }
            }
        }
        for (address, cell) in snapshot.cells where changes[address] == nil {
            guard validated.cells[address]?.text == cell.text, validated.cells[address]?.formula == cell.formula else {
                throw WorkspaceError(message: "相邻单元格核验失败，原表未修改。")
            }
        }
        guard try fingerprint(snapshot.fileURL) == snapshot.fingerprint else { throw WorkspaceError(message: "保存期间原表发生变化，编辑已保留，请重新核对。") }
        _ = try manager.replaceItemAt(snapshot.fileURL, withItemAt: replacement)
        return try read(snapshot.fileURL, sheetPath: snapshot.sheet.archivePath)
    }
    static func formulaBody(_ value: String) -> String? {
        let clean = cleanText(value)
        guard clean.first == "=" else { return nil }
        let body = String(clean.dropFirst())
        return body.isEmpty ? nil : body
    }
    static func cleanText(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter {
            [9, 10, 13].contains($0.value) || (0x20...0xD7FF).contains($0.value)
                || (0xE000...0xFFFD).contains($0.value) || (0x10000...0x10FFFF).contains($0.value)
        })).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

/// Excel-compatible quoted TSV, including tabs/newlines inside a single cell.
enum GridClipboard {
    static func encode(_ rows: [[String]]) -> String {
        rows.map { $0.map { value in
            value.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" })
                ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }.joined(separator: "\t") }.joined(separator: "\n")
    }
    static func decode(_ text: String) -> [[String]] {
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false, i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { cell.append(c); i += 1 }
                else if quoted { quoted = false }
                else if cell.isEmpty { quoted = true }
                else { cell.append(c) }
            } else if !quoted && c == "\t" { row.append(cell); cell = "" }
            else if !quoted && c == "\n" { row.append(cell); rows.append(row); row = []; cell = "" }
            else { cell.append(c) }
            i += 1
        }
        if !row.isEmpty || !cell.isEmpty || rows.isEmpty { row.append(cell); rows.append(row) }
        return rows
    }
}

@MainActor
final class GridEditorModel: ObservableObject {
    @Published var snapshot: GridSnapshot? { didSet { rowHeights.removeAll() } }
    @Published var changes: [GridAddress: String] = [:] { didSet { rowHeights.removeAll() } }
    @Published var anchor = GridAddress(row: 0, column: 0)
    @Published var extent = GridAddress(row: 0, column: 0)
    @Published var isBusy = false
    @Published var message: String?
    @Published var isError = false
    @Published var revision = 0
    @Published var frozenRows = 0
    @Published var frozenColumns = 0
    @Published var showingFullContent = false
    @Published var lastFill: GridFillRecord?
    @Published var zoom: CGFloat = 1
    var fillPreviewTarget: GridAddress?
    func setZoom(_ value: CGFloat) { zoom = min(2.5, max(0.5, value)); revision += 1 }
    var columnWidths: [Int: CGFloat] = [:] { didSet { rowHeights.removeAll() } }
    @Published var adaptiveRows = false { didSet { rowHeights.removeAll(); revision += 1 } }
    private var rowHeights: [Int: CGFloat] = [:]
    func displayRowHeight(_ row: Int) -> CGFloat {
        guard adaptiveRows, row < usedRowCount else { return 29 }
        if let cached = rowHeights[row] { return cached }
        var height: CGFloat = 29
        for column in 0..<usedColumnCount {
            let value = String(text(GridAddress(row: row, column: column)).prefix(1024))
            guard !value.isEmpty else { continue }
            let size = (value as NSString).boundingRect(
                with: NSSize(width: max(30, (columnWidths[column] ?? 140) - 8), height: 96),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: 12)])
            height = min(96, max(height, ceil(size.height) + 8))
            if height == 96 { break }
        }
        rowHeights[row] = height
        return height
    }
    func fitColumns() {
        // Uniformly sample the sheet plus its headers; selection never triggers this scan.
        let count = usedRowCount
        let sample = Set(Array(0..<min(12, count)) + (0..<min(240, count)).map { $0 * max(1, count - 1) / max(1, min(240, count) - 1) }).sorted()
        var widths: [Int: CGFloat] = [:]
        for column in 0..<usedColumnCount {
            var measured: [CGFloat] = []
            for row in sample {
                let value = String(text(GridAddress(row: row, column: column)).prefix(256))
                guard !value.isEmpty else { continue }
                let width = value.components(separatedBy: .newlines).map {
                    ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
                }.max() ?? 0
                measured.append(width + 16)
            }
            measured.sort()
            widths[column] = min(360, max(120, measured.isEmpty ? 160 : measured[min(measured.count - 1, Int(Double(measured.count - 1) * 0.92))]))
        }
        columnWidths = widths; revision += 1
    }
    func resetCellLayout() { columnWidths = [:]; adaptiveRows = false; revision += 1 }
    var onActivate: (() -> Void)?
    private var axisSelection: String?
    var usedRowCount: Int { max(1, max(snapshot?.rowCount ?? 0, (changes.keys.map(\.row).max() ?? -1) + 1)) }
    var usedColumnCount: Int { min(256, max(1, max(snapshot?.columnCount ?? 0, (changes.keys.map(\.column).max() ?? -1) + 1))) }
    private static func roundedUp(_ value: Int, toMultiple multiple: Int) -> Int {
        guard value > 0 else { return 0 }
        return ((value + multiple - 1) / multiple) * multiple
    }
    func selectRows(_ row: Int, extending: Bool) {
        let start = extending && axisSelection == "row" ? anchor.row : row
        anchor = GridAddress(row: start, column: 0)
        extent = GridAddress(row: row, column: usedColumnCount - 1)
        axisSelection = "row"; revision += 1
    }
    func selectColumns(_ column: Int, extending: Bool) {
        let start = extending && axisSelection == "column" ? anchor.column : column
        anchor = GridAddress(row: 0, column: start)
        extent = GridAddress(row: usedRowCount - 1, column: column)
        axisSelection = "column"; revision += 1
    }
    func configureFreeze() {
        let alert = NSAlert()
        alert.messageText = "冻结行与列"
        alert.informativeText = "填写固定在顶部的行数和左侧的列数。0 表示不冻结；只影响当前工具视图，不修改源文件。"
        let view = NSStackView(); view.orientation = .vertical; view.spacing = 10
        let rowField = NSTextField(string: String(frozenRows))
        let colField = NSTextField(string: String(frozenColumns))
        for (label, field) in [("前几行", rowField), ("前几列", colField)] {
            let line = NSStackView(views: [NSTextField(labelWithString: label), field])
            field.widthAnchor.constraint(equalToConstant: 120).isActive = true
            view.addArrangedSubview(line)
        }
        view.frame = NSRect(x: 0, y: 0, width: 220, height: 70); alert.accessoryView = view
        alert.addButton(withTitle: "应用"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let r = Int(rowField.stringValue), let c = Int(colField.stringValue),
              r >= 0, c >= 0, r < rowCount, c < columnCount else {
            message = "冻结数量须为非负整数，且至少保留一行和一列可滚动区域。"; isError = true; return
        }
        frozenRows = r; frozenColumns = c; revision += 1
    }
    private struct EditorState {
        let changes: [GridAddress: String]
        let formulaAddresses: Set<GridAddress>
    }
    private var history: [EditorState] = []
    private var redoHistory: [EditorState] = []
    private(set) var formulaAddresses: Set<GridAddress> = []
    private var observedStamp: String?
    private var checkingExternal = false
    private static func stamp(_ url: URL) -> String {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "missing" }
        return "\(a[.modificationDate] ?? "")/\(a[.size] ?? "")/\(a[.systemFileNumber] ?? "")"
    }
    func refreshIfChanged() {
        guard !isBusy, !checkingExternal, let snapshot else { return }
        let stamp = Self.stamp(snapshot.fileURL)
        guard let previous = observedStamp else { observedStamp = stamp; return }
        guard stamp != previous else { return }
        guard changes.isEmpty else {
            message = "原文件已变化；当前编辑仍保留，自动刷新已暂停。请先复制需要的内容，再重新读取。"; isError = true; return
        }
        // Do not reload underneath an active in-cell or formula-bar editor.
        if NSApp.keyWindow?.firstResponder is NSTextView { return }
        checkingExternal = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try GridWorkbookIO.read(snapshot.fileURL, sheetPath: snapshot.sheet.archivePath) }
            DispatchQueue.main.async {
                self.checkingExternal = false
                guard self.changes.isEmpty, self.snapshot?.fingerprint == snapshot.fingerprint,
                      self.snapshot?.sheet == snapshot.sheet, !self.isBusy else { return }
                switch result {
                case .success(let updated):
                    self.snapshot = updated; self.observedStamp = Self.stamp(updated.fileURL)
                    self.history = []; self.redoHistory = []; self.formulaAddresses = []; self.revision += 1
                    self.message = "已自动刷新外部修改"; self.isError = false
                case .failure(let error): self.message = error.localizedDescription; self.isError = true
                }
            }
        }
    }
    var rows: ClosedRange<Int> { min(anchor.row, extent.row)...max(anchor.row, extent.row) }
    var columns: ClosedRange<Int> { min(anchor.column, extent.column)...max(anchor.column, extent.column) }
    var selectionLabel: String { "\(GridAddress(row: rows.lowerBound, column: columns.lowerBound).reference):\(GridAddress(row: rows.upperBound, column: columns.upperBound).reference)" }
    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }
    // Keep a stable virtual editing buffer around the source sheet. Growing
    // this count for every first edit in the buffer rebuilds the AppKit table
    // and loses the direct-typing session between two keystrokes (notably
    // when entering B201 in a sheet whose source ends at row 200). Expand in
    // fixed blocks only after the user reaches the current buffer boundary.
    var rowCount: Int {
        let sourceCount = snapshot?.rowCount ?? 0
        let editedCount = (changes.keys.map(\.row).max() ?? -1) + 1
        let baseline = max(40, Self.roundedUp(sourceCount + 20, toMultiple: 20))
        let required = Self.roundedUp(max(sourceCount, editedCount), toMultiple: 20)
        return max(baseline, required)
    }
    var columnCount: Int {
        let sourceCount = snapshot?.columnCount ?? 0
        let editedCount = (changes.keys.map(\.column).max() ?? -1) + 1
        let baseline = max(12, Self.roundedUp(sourceCount + 2, toMultiple: 8))
        let required = Self.roundedUp(max(sourceCount, editedCount), toMultiple: 8)
        return min(256, max(baseline, required))
    }
    func sourceText(_ address: GridAddress) -> String {
        guard let cell = snapshot?.cells[address] else { return "" }
        return cell.formula ? "=\(cell.formulaText ?? "")" : cell.text
    }
    func inputText(_ address: GridAddress) -> String { changes[address] ?? sourceText(address) }
    func text(_ address: GridAddress) -> String { changes[address] ?? snapshot?.cells[address]?.text ?? "" }
    func load(_ file: URL, sheetPath: String? = nil) {
        guard !isBusy else { return }
        guard changes.isEmpty else { message = "当前表有未保存修改，请先保存或撤销后切换。"; isError = true; return }
        isBusy = true; message = nil; isError = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try GridWorkbookIO.read(file, sheetPath: sheetPath) }
            DispatchQueue.main.async {
                self.isBusy = false
                switch result {
                case .success(let value):
                    self.snapshot = value; self.history = []; self.redoHistory = []; self.formulaAddresses = []
                    self.lastFill = nil; self.fillPreviewTarget = nil
                    self.observedStamp = Self.stamp(value.fileURL)
                    self.anchor = GridAddress(row: 0, column: 0); self.extent = self.anchor; self.revision += 1
                case .failure(let error): self.message = error.localizedDescription; self.isError = true
                }
            }
        }
    }
    func select(row: Int, column: Int, extending: Bool) {
        axisSelection = nil
        lastFill = nil; fillPreviewTarget = nil
        let address = GridAddress(row: max(0, min(rowCount - 1, row)), column: max(0, min(columnCount - 1, column)))
        if !extending { anchor = address }; extent = address; revision += 1
    }
    func edit(_ updates: [GridAddress: String], formulaAddresses newFormulaAddresses: Set<GridAddress> = []) {
        guard !isBusy, snapshot != nil else { return }
        let hasChange = updates.contains { address, value in
            let clean = GridWorkbookIO.cleanText(value)
            return inputText(address) != clean ||
                (newFormulaAddresses.contains(address) && !formulaAddresses.contains(address) && snapshot?.cells[address]?.formula != true)
        }
        guard hasChange else { return }
        lastFill = nil; fillPreviewTarget = nil
        history.append(EditorState(changes: changes, formulaAddresses: formulaAddresses))
        if history.count > 50 { history.removeFirst() }
        redoHistory = []
        for (address, value) in updates {
            let clean = GridWorkbookIO.cleanText(value)
            if clean == sourceText(address) {
                changes.removeValue(forKey: address); formulaAddresses.remove(address)
            } else {
                changes[address] = clean
                if newFormulaAddresses.contains(address) ||
                    (formulaAddresses.contains(address) && GridWorkbookIO.formulaBody(clean) != nil) {
                    formulaAddresses.insert(address)
                } else if snapshot?.cells[address]?.formula != true {
                    formulaAddresses.remove(address)
                }
            }
        }
        revision += 1; message = nil; isError = false
    }
    private func isFormula(_ address: GridAddress) -> Bool {
        formulaAddresses.contains(address) || snapshot?.cells[address]?.formula == true
    }
    private static func numberValue(_ value: String) -> Double? {
        guard value.range(of: "^-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              !(value.hasPrefix("-") && value.dropFirst().hasPrefix("0") && value.count > 2 && !value.hasPrefix("-0.")),
              !(!value.hasPrefix("-") && value.hasPrefix("0") && value.count > 1 && !value.hasPrefix("0.")) else { return nil }
        return Double(value)
    }
    private static func numberString(_ value: Double) -> String {
        if value.rounded() == value { return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value) }
        return String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    private static func dateValue(_ value: String) -> (date: Date, format: String)? {
        for format in ["yyyy-MM-dd", "yyyy/MM/dd", "MM/dd/yyyy", "dd/MM/yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: value) { return (date, format) }
        }
        return nil
    }
    private static func dateString(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
    private static func shiftedFormula(_ value: String, rowDelta: Int, columnDelta: Int) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_])(\\$?)([A-Za-z]{1,3})(\\$?)([0-9]+)") else { return value }
        let nsValue = value as NSString
        let fullRange = NSRange(location: 0, length: nsValue.length)
        var result = value
        for match in regex.matches(in: value, range: fullRange).reversed() {
            let prefix = nsValue.substring(with: NSRange(location: 0, length: match.range.location))
            // Do not rewrite cell-looking text inside a quoted Excel string.
            if prefix.filter({ $0 == "\"" }).count % 2 == 1 { continue }
            let columnAbsolute = nsValue.substring(with: match.range(at: 1)) == "$"
            let letters = nsValue.substring(with: match.range(at: 2)).uppercased()
            let rowAbsolute = nsValue.substring(with: match.range(at: 3)) == "$"
            guard let row = Int(nsValue.substring(with: match.range(at: 4))) else { continue }
            let column = letters.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
            let shiftedRow = rowAbsolute ? row : row + rowDelta
            let shiftedColumn = columnAbsolute ? column : column + columnDelta
            let replacement: String
            if shiftedRow < 1 || shiftedColumn < 0 || shiftedColumn >= 16_384 {
                replacement = "#REF!"
            } else {
                replacement = "\(columnAbsolute ? "$" : "")\(GridAddress.columnName(shiftedColumn))\(rowAbsolute ? "$" : "")\(shiftedRow)"
            }
            let stringRange = Range(match.range, in: result)!
            result.replaceSubrange(stringRange, with: replacement)
        }
        return result
    }
    private struct TextSequencePart {
        let prefix: String
        let number: Int
        let suffix: String
        let width: Int
    }

    private static func textSequenceParts(_ value: String) -> [TextSequencePart] {
        guard !value.hasPrefix("=") else { return [] }
        guard let regex = try? NSRegularExpression(pattern: "(?<![0-9])-?[0-9]+") else { return [] }
        let nsValue = value as NSString
        let fullRange = NSRange(location: 0, length: nsValue.length)
        return regex.matches(in: value, range: fullRange).compactMap { match in
            let token = nsValue.substring(with: match.range)
            guard let number = Int(token) else { return nil }
            let prefix = nsValue.substring(with: NSRange(location: 0, length: match.range.location))
            let suffixStart = match.range.location + match.range.length
            let suffix = nsValue.substring(with: NSRange(location: suffixStart, length: nsValue.length - suffixStart))
            let digits = token.hasPrefix("-") ? String(token.dropFirst()) : token
            let width = digits.count > 1 && digits.first == "0" ? digits.count : 0
            // A plain number is already handled by numberValue; requiring
            // surrounding text keeps leading-zero numeric cells unchanged.
            guard !prefix.isEmpty || !suffix.isEmpty else { return nil }
            return TextSequencePart(prefix: prefix, number: number, suffix: suffix, width: width)
        }
    }

    static func textSequenceValue(_ value: String, previous: String?, offset: Int) -> String? {
        let lastParts = textSequenceParts(value)
        guard !lastParts.isEmpty else { return nil }
        let selectedIndex: Int
        var step = 1
        if let previous {
            let firstParts = textSequenceParts(previous)
            guard firstParts.count == lastParts.count else { return nil }
            let matching = lastParts.indices.filter {
                lastParts[$0].prefix == firstParts[$0].prefix &&
                lastParts[$0].suffix == firstParts[$0].suffix
            }
            guard !matching.isEmpty else { return nil }
            selectedIndex = matching.first(where: { lastParts[$0].number != firstParts[$0].number }) ?? matching.last!
            let difference = lastParts[selectedIndex].number.subtractingReportingOverflow(firstParts[selectedIndex].number)
            guard !difference.overflow else { return nil }
            step = difference.partialValue
        } else {
            // With one starting value, the rightmost number is the least
            // surprising choice for values such as v1.2 or reward-1-level.
            selectedIndex = lastParts.count - 1
        }
        let delta = step.multipliedReportingOverflow(by: offset)
        let result = lastParts[selectedIndex].number.addingReportingOverflow(delta.partialValue)
        guard !delta.overflow, !result.overflow else { return nil }
        let part = lastParts[selectedIndex]
        let digits = String(result.partialValue.magnitude)
        let replacement = (result.partialValue < 0 ? "-" : "") +
            String(repeating: "0", count: max(0, part.width - digits.count)) + digits
        return part.prefix + replacement + part.suffix
    }

    private func scalarSequenceValue(last: String, previous: String?, offset: Int) -> String? {
        if let number = Self.numberValue(last) {
            if let previous, let first = Self.numberValue(previous) {
                return Self.numberString(number + (number - first) * Double(offset))
            }
            if previous == nil { return Self.numberString(number + Double(offset)) }
            return nil
        }
        if let date = Self.dateValue(last) {
            if let previous, let first = Self.dateValue(previous), date.format == first.format {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let step = calendar.dateComponents([.day], from: first.date, to: date.date).day ?? 0
                let shifted = calendar.date(byAdding: .day, value: step * offset, to: date.date) ?? date.date
                return Self.dateString(shifted, format: date.format)
            }
            if previous == nil {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let shifted = calendar.date(byAdding: .day, value: offset, to: date.date) ?? date.date
                return Self.dateString(shifted, format: date.format)
            }
            return nil
        }
        return Self.textSequenceValue(last, previous: previous, offset: offset)
    }

    private func sequenceValue(at target: GridAddress, rows sourceRows: ClosedRange<Int>, columns sourceColumns: ClosedRange<Int>) -> String? {
        guard !sourceRows.isEmpty, !sourceColumns.isEmpty else { return nil }
        // A downward fill is evaluated independently for every source column.
        // This is what makes a rectangular selection such as A1:B2 continue
        // A's series and B's series separately.
        if target.row > sourceRows.upperBound {
            let sourceColumn = sourceColumns.contains(target.column)
                ? target.column
                : sourceColumns.lowerBound + (target.column - sourceColumns.lowerBound) % sourceColumns.count
            let last = GridAddress(row: sourceRows.upperBound, column: sourceColumn)
            let previous = sourceRows.count >= 2
                ? GridAddress(row: sourceRows.upperBound - 1, column: sourceColumn) : nil
            let offset = target.row - sourceRows.upperBound
            return scalarSequenceValue(last: inputText(last), previous: previous.map(inputText), offset: offset)
        }
        // A rightward fill is evaluated independently for every source row.
        if target.column > sourceColumns.upperBound {
            let sourceRow = sourceRows.contains(target.row)
                ? target.row
                : sourceRows.lowerBound + (target.row - sourceRows.lowerBound) % sourceRows.count
            let last = GridAddress(row: sourceRow, column: sourceColumns.upperBound)
            let previous = sourceColumns.count >= 2
                ? GridAddress(row: sourceRow, column: sourceColumns.upperBound - 1) : nil
            let offset = target.column - sourceColumns.upperBound
            return scalarSequenceValue(last: inputText(last), previous: previous.map(inputText), offset: offset)
        }
        return nil
    }
    private func automaticFillMode(rows sourceRows: ClosedRange<Int>, columns sourceColumns: ClosedRange<Int>) -> GridFillMode {
        if sourceRows.contains(where: { row in sourceColumns.contains(where: { isFormula(GridAddress(row: row, column: $0)) }) }) {
            return .sequence
        }
        for column in sourceColumns {
            let probe = GridAddress(row: sourceRows.upperBound + 1, column: column)
            if sequenceValue(at: probe, rows: sourceRows, columns: sourceColumns) != nil { return .sequence }
        }
        for row in sourceRows {
            let probe = GridAddress(row: row, column: sourceColumns.upperBound + 1)
            if sequenceValue(at: probe, rows: sourceRows, columns: sourceColumns) != nil { return .sequence }
        }
        return .copy
    }
    @discardableResult
    func fillFromHandle(to targetRow: Int, targetColumn: Int) -> Bool {
        let sourceRows = rows, sourceColumns = columns
        let mode = automaticFillMode(rows: sourceRows, columns: sourceColumns)
        let didFill = fillSelection(to: targetRow, targetColumn: targetColumn, mode: mode)
        if didFill {
            lastFill = GridFillRecord(sourceRows: sourceRows, sourceColumns: sourceColumns,
                                      row: targetRow, column: targetColumn, mode: mode)
        }
        return didFill
    }
    func reapplyLastFill(_ mode: GridFillMode) {
        guard let record = lastFill, !isBusy, !history.isEmpty else { return }
        lastFill = nil; fillPreviewTarget = nil
        undo()
        anchor = GridAddress(row: record.sourceRows.lowerBound, column: record.sourceColumns.lowerBound)
        extent = GridAddress(row: record.sourceRows.upperBound, column: record.sourceColumns.upperBound)
        guard fillSelection(to: record.row, targetColumn: record.column, mode: mode) else { return }
        lastFill = GridFillRecord(sourceRows: record.sourceRows, sourceColumns: record.sourceColumns,
                                  row: record.row, column: record.column, mode: mode)
    }
    func cancelLastFillOptions() {
        lastFill = nil; fillPreviewTarget = nil; revision += 1
    }
    func fillSelection(to targetRow: Int, targetColumn: Int, mode: GridFillMode = .sequence) -> Bool {
        guard !isBusy, snapshot != nil else { return false }
        let sourceRows = rows, sourceColumns = columns
        let endRow = max(sourceRows.upperBound, min(rowCount - 1, targetRow))
        let endColumn = max(sourceColumns.upperBound, min(columnCount - 1, targetColumn))
        guard endRow > sourceRows.upperBound || endColumn > sourceColumns.upperBound else { return false }
        let total = (endRow - sourceRows.lowerBound + 1) * (endColumn - sourceColumns.lowerBound + 1)
            - sourceRows.count * sourceColumns.count
        guard total <= 50_000 else {
            message = "填充范围过大，单次最多填充 50,000 个单元格。"; isError = true; return false
        }
        var updates: [GridAddress: String] = [:], formulas: Set<GridAddress> = []
        for row in sourceRows.lowerBound...endRow {
            for column in sourceColumns.lowerBound...endColumn {
                guard !sourceRows.contains(row) || !sourceColumns.contains(column) else { continue }
                let target = GridAddress(row: row, column: column)
                let source = GridAddress(
                    row: sourceRows.lowerBound + (row - sourceRows.lowerBound) % sourceRows.count,
                    column: sourceColumns.lowerBound + (column - sourceColumns.lowerBound) % sourceColumns.count)
                let value: String
                if mode == .sequence, let sequence = sequenceValue(at: target, rows: sourceRows, columns: sourceColumns) {
                    value = sequence
                } else if isFormula(source), let formula = GridWorkbookIO.formulaBody(inputText(source)) {
                    value = Self.shiftedFormula("=\(formula)", rowDelta: row - source.row, columnDelta: column - source.column)
                    formulas.insert(target)
                } else {
                    value = inputText(source)
                }
                updates[target] = value
            }
        }
        edit(updates, formulaAddresses: formulas)
        guard !updates.isEmpty, !isError else { return false }
        anchor = sourceRows.lowerBound <= endRow ? GridAddress(row: sourceRows.lowerBound, column: sourceColumns.lowerBound) : anchor
        extent = GridAddress(row: endRow, column: endColumn)
        revision += 1
        return true
    }
    func copy() {
        let values = rows.map { row in columns.map { inputText(GridAddress(row: row, column: $0)) } }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(GridClipboard.encode(values), forType: .string)
        message = "已复制 \(rows.count) 行 × \(columns.count) 列"; isError = false
    }
    func paste() {
        guard let value = NSPasteboard.general.string(forType: .string) else { return }
        let values = GridClipboard.decode(value), count = values.reduce(0) { $0 + $1.count }
        guard count <= 50_000, columns.lowerBound + (values.map(\.count).max() ?? 0) <= 256,
              rows.lowerBound + values.count <= 1_048_576 else {
            message = "单次最多粘贴 50,000 个单元格，内置视图支持前 256 列。"; isError = true; return
        }
        var updates: [GridAddress: String] = [:]
        for (r, row) in values.enumerated() { for (c, text) in row.enumerated() {
            updates[GridAddress(row: rows.lowerBound + r, column: columns.lowerBound + c)] = text
        } }
        let start = GridAddress(row: rows.lowerBound, column: columns.lowerBound)
        edit(updates)
        if !isError { anchor = start; extent = GridAddress(row: start.row + values.count - 1, column: start.column + (values.map(\.count).max() ?? 1) - 1); revision += 1 }
    }
    func clearSelection() { edit(Dictionary(uniqueKeysWithValues: rows.flatMap { row in columns.map { (GridAddress(row: row, column: $0), "") } })) }
    func undo() {
        guard let previous = history.popLast(), !isBusy else { return }
        redoHistory.append(EditorState(changes: changes, formulaAddresses: formulaAddresses))
        changes = previous.changes; formulaAddresses = previous.formulaAddresses; lastFill = nil; fillPreviewTarget = nil; revision += 1
    }
    func redo() {
        guard let next = redoHistory.popLast(), !isBusy else { return }
        history.append(EditorState(changes: changes, formulaAddresses: formulaAddresses))
        changes = next.changes; formulaAddresses = next.formulaAddresses; lastFill = nil; fillPreviewTarget = nil; revision += 1
    }
    func save(afterSave: (() -> Void)? = nil) {
        guard !isBusy, let snapshot else { return }
        guard !changes.isEmpty else { afterSave?(); return }
        let updates = changes, formulaUpdates = formulaAddresses
        isBusy = true; message = "正在保存 \(updates.count) 个单元格…"; isError = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try GridWorkbookIO.save(snapshot, changes: updates, formulaAddresses: formulaUpdates) }
            DispatchQueue.main.async {
                self.isBusy = false
                switch result {
                case .success(let saved):
                    self.snapshot = saved; self.changes = [:]; self.history = []; self.redoHistory = []; self.formulaAddresses = []
                    self.lastFill = nil; self.fillPreviewTarget = nil; self.revision += 1
                    self.observedStamp = Self.stamp(saved.fileURL)
                    self.message = "已保存 \(updates.count) 个单元格"; afterSave?()
                case .failure(let error): self.message = error.localizedDescription; self.isError = true
                }
            }
        }
    }
}

final class CellGridTable: NSTableView, NSTextInputClient {
    weak var editor: GridEditorModel?
    var rowOffset = 0
    var draggingRows = false
    private var filling = false
    private var directTypingAddress: GridAddress?
    private var markedInput = NSMutableAttributedString()
    private var markedSelection = NSRange(location: 0, length: 0)
    private var markedAddress: GridAddress?
    private var markedBase = ""
    private var handledTextInputEvent = false

    func endDirectTyping() {
        directTypingAddress = nil
        clearMarkedInput()
    }

    private func enterDirectText(_ typed: String, editor: GridEditorModel) {
        let address = GridAddress(row: editor.anchor.row, column: editor.anchor.column)
        let value = directTypingAddress == address ? editor.inputText(address) + typed : typed
        editor.edit([address: value])
        directTypingAddress = address
    }

    private func inputString(_ value: Any) -> String {
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String ?? ""
    }

    private func isASCIIInteger(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    private func markedCellAddress() -> GridAddress? {
        markedAddress ?? editor.map { GridAddress(row: $0.anchor.row, column: $0.anchor.column) }
    }

    private func refreshMarkedCell(_ address: GridAddress? = nil) {
        guard let address = address ?? markedAddress,
              let localColumn = tableColumns.enumerated().first(where: { dataColumn($0.offset) == address.column })?.offset,
              address.row >= rowOffset,
              address.row - rowOffset < numberOfRows else { return }
        reloadData(forRowIndexes: IndexSet(integer: address.row - rowOffset),
                   columnIndexes: IndexSet(integer: localColumn))
    }

    private func clearMarkedInput() {
        let hadMarkedText = markedInput.length > 0 || markedAddress != nil
        let address = markedAddress
        markedInput = NSMutableAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
        markedAddress = nil
        markedBase = ""
        if hadMarkedText { refreshMarkedCell(address) }
    }

    func markedDisplayText(for address: GridAddress) -> String? {
        guard markedAddress == address, markedInput.length > 0 else { return nil }
        return markedBase + markedInput.string
    }

    // NSTextInputClient keeps macOS input methods in charge of composition.
    // Direct typing still commits to the selected cell, but pinyin is held as
    // marked text until the IME commits the chosen candidate.
    func insertText(_ string: Any, replacementRange: NSRange) {
        handledTextInputEvent = true
        let typed = inputString(string)
        guard let editor, !typed.isEmpty else { return }
        clearMarkedInput()
        enterDirectText(typed, editor: editor)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        handledTextInputEvent = true
        guard let editor else { return }
        let marked = inputString(string)
        // A few input sources send an ordinary number through
        // setMarkedText before committing it. Treat that as direct numeric
        // entry when no composition is already visible; otherwise a second
        // number replaces the first marked digit. If pinyin or another real
        // composition is active, hasMarkedText() stays true and candidate
        // selection continues through the normal IME path.
        if !hasMarkedText() && isASCIIInteger(marked) {
            clearMarkedInput()
            enterDirectText(marked, editor: editor)
            return
        }
        let address = markedAddress ?? GridAddress(row: editor.anchor.row, column: editor.anchor.column)
        if markedAddress == nil {
            markedAddress = address
            markedBase = directTypingAddress == address ? editor.inputText(address) : ""
        }
        markedInput = NSMutableAttributedString(attributedString: string as? NSAttributedString
            ?? NSAttributedString(string: marked))
        markedSelection = selectedRange
        refreshMarkedCell()
    }

    func unmarkText() {
        handledTextInputEvent = true
        clearMarkedInput()
    }

    func hasMarkedText() -> Bool { markedInput.length > 0 }
    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedInput.length) : NSRange(location: NSNotFound, length: 0)
    }
    func selectedRange() -> NSRange { markedSelection }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: UnsafeMutablePointer<NSRange>?) -> NSAttributedString? {
        let value: NSAttributedString
        if hasMarkedText() {
            value = markedInput
        } else if let editor {
            value = NSAttributedString(string: editor.inputText(GridAddress(row: editor.anchor.row, column: editor.anchor.column)))
        } else {
            value = NSAttributedString(string: "")
        }
        let fullRange = NSRange(location: 0, length: value.length)
        let intersection = NSIntersectionRange(range, fullRange)
        actualRange?.pointee = intersection
        return intersection.length > 0 ? value.attributedSubstring(from: intersection) : NSAttributedString(string: "")
    }

    func firstRect(forCharacterRange range: NSRange,
                   actualRange: UnsafeMutablePointer<NSRange>?) -> NSRect {
        actualRange?.pointee = range
        guard let address = markedCellAddress(),
              let localColumn = tableColumns.enumerated().first(where: { dataColumn($0.offset) == address.column })?.offset,
              address.row >= rowOffset,
              address.row - rowOffset < numberOfRows else {
            let fallback = convert(bounds, to: nil)
            return window?.convertToScreen(fallback) ?? fallback
        }
        let cell = frameOfCell(atColumn: localColumn, row: address.row - rowOffset)
        let windowRect = convert(cell, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func dataColumn(_ local: Int) -> Int {
        guard tableColumns.indices.contains(local) else { return -2 }
        return Int(tableColumns[local].identifier.rawValue) ?? -2
    }
    func fillHandleRect() -> NSRect? {
        guard let editor, !editor.isBusy else { return nil }
        let globalRow = editor.rows.upperBound - rowOffset
        guard globalRow >= 0, globalRow < numberOfRows else { return nil }
        guard let localColumn = tableColumns.firstIndex(where: { $0.identifier.rawValue == String(editor.columns.upperBound) }) else { return nil }
        let cell = frameOfCell(atColumn: localColumn, row: globalRow)
        guard !cell.isNull, !cell.isEmpty else { return nil }
        let side = min(CGFloat(8), max(CGFloat(6), min(cell.width, cell.height) - 4))
        return NSRect(x: cell.maxX - side / 2, y: cell.maxY - side / 2, width: side, height: side)
    }
    private func invalidateFillPreview() {
        var view: NSView? = self
        while let current = view {
            if let grid = current as? FrozenGridView {
                grid.regions.forEach { $0.table.needsDisplay = true }
                return
            }
            view = current.superview
        }
        needsDisplay = true
    }
    private func fillPreviewRects() -> [NSRect] {
        guard let editor, let target = editor.fillPreviewTarget else { return [] }
        let sourceRows = editor.rows, sourceColumns = editor.columns
        let endRow = max(sourceRows.upperBound, target.row)
        let endColumn = max(sourceColumns.upperBound, target.column)
        func rect(for rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> NSRect? {
            let lowRow = max(rows.lowerBound, rowOffset)
            let highRow = min(rows.upperBound, rowOffset + numberOfRows - 1)
            guard lowRow <= highRow else { return nil }
            let localColumns = tableColumns.indices.filter { local in
                let column = dataColumn(local)
                return column >= columns.lowerBound && column <= columns.upperBound
            }
            guard let firstColumn = localColumns.first, let lastColumn = localColumns.last else { return nil }
            let firstRow = lowRow - rowOffset, lastRow = highRow - rowOffset
            return frameOfCell(atColumn: firstColumn, row: firstRow)
                .union(frameOfCell(atColumn: lastColumn, row: lastRow))
        }
        var result: [NSRect] = []
        if endColumn > sourceColumns.upperBound,
           let right = rect(for: sourceRows.lowerBound...endRow,
                            columns: sourceColumns.upperBound + 1...endColumn) { result.append(right) }
        if endRow > sourceRows.upperBound,
           let bottom = rect(for: sourceRows.upperBound + 1...endRow,
                             columns: sourceColumns.lowerBound...endColumn) { result.append(bottom) }
        return result
    }
    private func updateFillTarget(with event: NSEvent) {
        guard filling, let editor else { return }
        let point = convert(event.locationInWindow, from: nil)
        var localRow = row(at: point)
        if localRow < 0 { localRow = point.y < 0 ? 0 : numberOfRows - 1 }
        var localColumn = column(at: point)
        if localColumn < 0 {
            localColumn = point.x < 0 ? 0 : max(0, numberOfColumns - 1)
        }
        let column = dataColumn(localColumn)
        guard localRow >= 0, column >= 0 else { return }
        let address = GridAddress(row: localRow + rowOffset, column: column)
        guard address.row >= editor.rows.upperBound || address.column >= editor.columns.upperBound else {
            editor.fillPreviewTarget = nil; invalidateFillPreview(); return
        }
        editor.fillPreviewTarget = address; invalidateFillPreview()
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for rect in fillPreviewRects() {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            rect.insetBy(dx: 1, dy: 1).fill()
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
            let outline = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            outline.lineWidth = 1.5
            outline.setLineDash([4, 3], count: 2, phase: 0)
            outline.stroke()
        }
        guard let handle = fillHandleRect() else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: handle.insetBy(dx: 1, dy: 1), xRadius: 1.5, yRadius: 1.5).fill()
    }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let editor, !editor.isBusy else { return }
        endDirectTyping()
        let p = convert(event.locationInWindow, from: nil), localRow = row(at: p), localColumn = column(at: p)
        if let handle = fillHandleRect(), handle.insetBy(dx: -5, dy: -5).contains(p) {
            editor.onActivate?()
            filling = true; editor.fillPreviewTarget = nil; invalidateFillPreview()
            window?.makeFirstResponder(self)
            return
        }
        let r = localRow + rowOffset, c = dataColumn(localColumn)
        guard localRow >= 0, c >= -1 else { return }
        editor.onActivate?()
        window?.makeFirstResponder(self)
        draggingRows = c == -1
        if draggingRows { editor.selectRows(r, extending: event.modifierFlags.contains(.shift)); return }
        editor.select(row: r, column: c, extending: event.modifierFlags.contains(.shift))
        if event.clickCount == 2 {
            editColumn(localColumn, row: localRow, with: nil, select: true)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        if filling {
            autoscroll(with: event)
            updateFillTarget(with: event)
            return
        }
        let p = convert(event.locationInWindow, from: nil), localRow = row(at: p), r = localRow + rowOffset, c = dataColumn(column(at: p))
        guard localRow >= 0 else { return }
        if draggingRows { editor?.selectRows(r, extending: true); autoscroll(with: event); return }
        guard c >= 0 else { return }
        editor?.select(row: r, column: c, extending: true); autoscroll(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        if filling {
            updateFillTarget(with: event)
            let target = editor?.fillPreviewTarget
            filling = false
            if let target { editor?.fillFromHandle(to: target.row, targetColumn: target.column) }
            else { editor?.fillPreviewTarget = nil; invalidateFillPreview() }
            invalidateFillPreview()
            return
        }
        super.mouseUp(with: event)
    }
    @objc func copy(_ sender: Any?) { endDirectTyping(); editor?.copy() }
    @objc func paste(_ sender: Any?) { endDirectTyping(); editor?.paste() }
    override func keyDown(with event: NSEvent) {
        guard let editor, !editor.isBusy else { return }
        // Once an IME has started composing, navigation, backspace, and
        // return belong to the input method first (for candidate selection or
        // cancellation), not to the grid's cell-selection shortcuts.
        if hasMarkedText() {
            handledTextInputEvent = false
            interpretKeyEvents([event])
            if handledTextInputEvent || hasMarkedText() { return }
        }
        if event.modifierFlags.contains(.command) {
            endDirectTyping()
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": editor.copy()
            case "v": editor.paste()
            case "s": editor.save()
            case "z":
                event.modifierFlags.contains(.shift) ? editor.redo() : editor.undo()
                // reloadData can make AppKit move focus to the window content;
                // keep the grid as the responder so repeated ⌘Z works.
                window?.makeFirstResponder(self)
            default: super.keyDown(with: event)
            }
            return
        }
        let extending = event.modifierFlags.contains(.shift)
        var row = editor.extent.row, column = editor.extent.column
        switch event.keyCode {
        case 123: column -= 1
        case 124, 48: column += 1
        case 125: row += 1
        case 126: row -= 1
        case 51, 117: endDirectTyping(); editor.clearSelection(); return
        case 36:
            endDirectTyping()
            let local = tableColumns.firstIndex { $0.identifier.rawValue == String(column) }
            if let local, row >= rowOffset, row - rowOffset < numberOfRows { editColumn(local, row: row - rowOffset, with: event, select: true) }
            return
        default:
            let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
            if event.modifierFlags.intersection(blockedModifiers).isEmpty,
               let typed = event.characters,
               !typed.isEmpty,
               typed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) {
                // Excel-style direct entry: a normal single click followed by
                // typing replaces the selected cell immediately. Further
                // characters in the same typing session append to that first
                // character, without opening a field editor or showing a caret.
                // ASCII digits are committed directly when there is no visible
                // IME composition. Some Chinese input methods temporarily keep
                // a first digit as marked text; sending the next digit through
                // interpretKeyEvents then replaces it, so direct numeric entry
                // must bypass that path. Once marked text exists, digits still
                // go to the IME so candidate selection keeps working.
                if isASCIIInteger(typed) && !hasMarkedText() {
                    enterDirectText(typed, editor: editor)
                    return
                }
                handledTextInputEvent = false
                interpretKeyEvents([event])
                if !handledTextInputEvent && !hasMarkedText() {
                    enterDirectText(typed, editor: editor)
                }
                return
            }
            endDirectTyping()
            super.keyDown(with: event); return
        }
        endDirectTyping()
        editor.select(row: row, column: column, extending: extending)
        if editor.extent.row >= rowOffset { scrollRowToVisible(editor.extent.row - rowOffset) }
        if let c = tableColumns.firstIndex(where: { $0.identifier.rawValue == String(editor.extent.column) }) { scrollColumnToVisible(c) }
    }
}

final class GridColumnHeader: NSTableHeaderView {
    private var resizingColumn: NSTableColumn?
    private var resizeStartX: CGFloat = 0
    private var resizeStartWidth: CGFloat = 0
    private(set) var appliedZoom: CGFloat = 1

    func applyZoom(_ value: CGFloat) {
        let zoom = min(2.5, max(0.5, value))
        appliedZoom = zoom
        var headerFrame = frame
        headerFrame.size.height = 23 * zoom
        if abs(headerFrame.height - frame.height) > 0.1 { frame = headerFrame }
        for column in tableView?.tableColumns ?? [] {
            column.headerCell.font = NSFont.systemFont(ofSize: 12 * zoom, weight: .medium)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let table = tableView as? CellGridTable, let editor = table.editor,
              !editor.isBusy else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let column = resizableColumn(near: point, in: table) {
            resizingColumn = column
            resizeStartX = point.x
            resizeStartWidth = column.width
            table.window?.makeFirstResponder(table)
            return
        }
        let local = column(at: point)
        let c = table.dataColumn(local)
        table.window?.makeFirstResponder(table)
        table.endDirectTyping()
        table.editor?.onActivate?()
        if c >= 0 { editor.selectColumns(c, extending: event.modifierFlags.contains(.shift)) }
    }
    override func mouseDragged(with event: NSEvent) {
        if let column = resizingColumn {
            let point = convert(event.locationInWindow, from: nil)
            column.width = min(column.maxWidth, max(column.minWidth, resizeStartWidth + point.x - resizeStartX))
            tableView?.needsDisplay = true
            return
        }
        guard let table = tableView as? CellGridTable else { return }
        let c = table.dataColumn(column(at: convert(event.locationInWindow, from: nil)))
        if c >= 0 { table.editor?.selectColumns(c, extending: true) }
    }
    override func mouseUp(with event: NSEvent) {
        resizingColumn = nil
        super.mouseUp(with: event)
    }

    private func resizableColumn(near point: NSPoint, in table: NSTableView) -> NSTableColumn? {
        let radius = max(10, 12 * appliedZoom)
        var result: (column: NSTableColumn, distance: CGFloat)?
        for index in table.tableColumns.indices {
            let candidate = table.tableColumns[index]
            guard Int(candidate.identifier.rawValue) ?? -1 >= 0 else { continue }
            let boundary = headerRect(ofColumn: index).maxX
            let distance = abs(boundary - point.x)
            guard distance <= radius else { continue }
            if result == nil || distance < result!.distance { result = (candidate, distance) }
        }
        return result?.column
    }
}

@MainActor
final class FillOptionsViewController: NSViewController {
    static let contentSize = NSSize(width: 150, height: 50)
    private let model: GridEditorModel
    private let onFinish: () -> Void
    private let copyButton: NSButton
    private let sequenceButton: NSButton

    init(model: GridEditorModel, onFinish: @escaping () -> Void) {
        self.model = model
        self.onFinish = onFinish
        copyButton = NSButton(title: "复制单元格", target: nil, action: nil)
        sequenceButton = NSButton(title: "以序列方式填充", target: nil, action: nil)
        super.init(nibName: nil, bundle: nil)
        copyButton.setButtonType(.radio)
        sequenceButton.setButtonType(.radio)
        copyButton.target = self; copyButton.action = #selector(selectCopy)
        sequenceButton.target = self; sequenceButton.action = #selector(selectSequence)
        copyButton.controlSize = NSControl.ControlSize.regular
        sequenceButton.controlSize = NSControl.ControlSize.regular
        copyButton.font = NSFont.systemFont(ofSize: 13)
        sequenceButton.font = NSFont.systemFont(ofSize: 13)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        root.addSubview(copyButton)
        root.addSubview(sequenceButton)
        view = root
        preferredContentSize = Self.contentSize
        viewDidLayout()
        switch model.lastFill?.mode {
        case .copy: copyButton.state = .on; sequenceButton.state = .off
        case .sequence: copyButton.state = .off; sequenceButton.state = .on
        case nil: copyButton.state = .off; sequenceButton.state = .off
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let horizontalInset: CGFloat = 10
        let verticalInset: CGFloat = 4
        let rowHeight: CGFloat = 21
        let width = max(0, view.bounds.width - horizontalInset * 2)
        sequenceButton.frame = NSRect(x: horizontalInset, y: verticalInset, width: width, height: rowHeight)
        copyButton.frame = NSRect(x: horizontalInset, y: view.bounds.height - verticalInset - rowHeight,
                                  width: width, height: rowHeight)
    }

    @objc private func selectCopy() {
        model.reapplyLastFill(.copy)
        onFinish()
    }

    @objc private func selectSequence() {
        model.reapplyLastFill(.sequence)
        onFinish()
    }
}

struct CellGrid: NSViewRepresentable {
    @ObservedObject var model: GridEditorModel
    func makeNSView(context: Context) -> FrozenGridView { FrozenGridView(model) }
    func updateNSView(_ view: FrozenGridView, context: Context) { view.update() }
}

// Four regions share one editor. Only the body scrolls on both axes; the top
// follows its horizontal offset and the left follows its vertical offset.
final class FrozenGridView: NSView {
    let model: GridEditorModel
    var regions: [GridRegion] = []
    var observations: [NSObjectProtocol] = []
    var signature = ""
    var syncing = false
    var lastRevision = -1
    var fillOptionsButton: NSButton?
    var fillOptionsPopover: NSPopover?
    private var fillOptionsObservation: AnyCancellable?
    override var isFlipped: Bool { true }
    init(_ model: GridEditorModel) {
        self.model = model
        super.init(frame: .zero)
        let image = NSImage(systemSymbolName: "arrow.down.right.square",
                            accessibilityDescription: "填充选项") ?? NSImage(size: NSSize(width: 16, height: 16))
        let button = NSButton(title: "⌄", target: nil, action: nil)
        button.image = image
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = NSButton.BezelStyle.roundRect
        button.controlSize = NSControl.ControlSize.small
        button.imagePosition = NSControl.ImagePosition.imageLeading
        button.imageHugsTitle = true
        button.imageScaling = NSImageScaling.scaleProportionallyDown
        button.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        button.alignment = .center
        button.contentTintColor = NSColor.secondaryLabelColor
        button.toolTip = "填充选项"
        button.setAccessibilityLabel("填充选项")
        button.target = self
        button.action = #selector(toggleFillOptions)
        button.frame = NSRect(x: 0, y: 0, width: 34, height: 22)
        button.isHidden = true
        fillOptionsButton = button
        addSubview(button)
        fillOptionsObservation = model.$lastFill.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.needsLayout = true
                self.updateFillOptionsButton()
            }
        }
        update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        observations.forEach { NotificationCenter.default.removeObserver($0) }
        fillOptionsObservation?.cancel()
    }

    private func selectedFillTable() -> CellGridTable? {
        guard model.lastFill != nil else { return nil }
        return regions.first(where: {
            $0.range.contains(model.rows.upperBound) &&
            $0.table.tableColumns.contains { $0.identifier.rawValue == String(model.columns.upperBound) }
        })?.table
    }

    func updateFillOptionsButton() {
        guard let button = fillOptionsButton,
              model.lastFill != nil,
              let table = selectedFillTable(),
              let handle = table.fillHandleRect(),
              bounds.width > 0, bounds.height > 0 else {
            fillOptionsPopover?.performClose(nil)
            fillOptionsPopover = nil
            fillOptionsButton?.isHidden = true
            return
        }
        let handleRect = table.convert(handle, to: self)
        let size = NSSize(width: 34, height: 22)
        var x = handleRect.maxX + 4
        var y = handleRect.minY - 4
        if x + size.width > bounds.width { x = handleRect.minX - size.width - 4 }
        if x < 0 { x = max(0, min(bounds.width - size.width, handleRect.midX - size.width / 2)) }
        if y + size.height > bounds.height { y = handleRect.maxY - size.height + 4 }
        y = max(0, min(bounds.height - size.height, y))
        button.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        button.isHidden = false
        addSubview(button, positioned: .above, relativeTo: nil)
    }

    @objc private func toggleFillOptions() {
        guard let button = fillOptionsButton, model.lastFill != nil else { return }
        if let popover = fillOptionsPopover, popover.isShown {
            popover.performClose(nil)
            fillOptionsPopover = nil
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = FillOptionsViewController(model: model) { [weak self, weak popover] in
            popover?.performClose(nil)
            self?.fillOptionsPopover = nil
            self?.needsLayout = true
        }
        fillOptionsPopover = popover
        popover.contentSize = FillOptionsViewController.contentSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    func update() {
        // Selection publishes a SwiftUI update immediately after double-click.
        // Reloading here would destroy AppKit's newly created field editor.
        guard !regions.contains(where: { $0.table.editedRow >= 0 }) else { return }
        let previousOrigins = regions.map { $0.scroll.contentView.bounds.origin }
        let previousRegionCount = regions.count
        let previousSignature = signature
        let revisionToRestore = model.revision
        let focusedTable = window?.firstResponder as? CellGridTable
        let shouldRestoreFocus = focusedTable?.isDescendant(of: self) == true
        let r = min(model.frozenRows, model.rowCount - 1), c = min(model.frozenColumns, model.columnCount - 1)
        let key = "\(r)/\(c)/\(model.columnCount)/\(model.rowCount)"
        if signature != key {
            signature = key
            observations.forEach { NotificationCenter.default.removeObserver($0) }; observations = []
            regions.forEach { $0.scroll.removeFromSuperview() }
            if r == 0 && c == 0 {
                // The ordinary view must be one NSTableView. Splitting the row
                // numbers and data into two scrolling tables causes subtle
                // one-row drift from independent header/clip-view geometry.
                regions = [GridRegion(model, rows: 0..<model.rowCount,
                                      columns: -1..<model.columnCount, header: true)]
            } else {
                regions = [
                    GridRegion(model, rows: 0..<r, columns: -1..<c, header: true),
                    GridRegion(model, rows: 0..<r, columns: c..<model.columnCount, header: true),
                    GridRegion(model, rows: r..<model.rowCount, columns: -1..<c, header: r == 0),
                    GridRegion(model, rows: r..<model.rowCount, columns: c..<model.columnCount, header: r == 0)
                ]
            }
            for (index, region) in regions.enumerated() {
                addSubview(region.scroll)
                region.scroll.contentView.postsBoundsChangedNotifications = true
                observations.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                    object: region.scroll.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.updateFillOptionsButton()
                        if self.regions.count == 4 { self.sync(from: index) }
                    }
                })
            }
            if regions.count == 1 {
                regions[0].scroll.hasHorizontalScroller = true
                regions[0].scroll.hasVerticalScroller = true
                regions[0].scroll.scrollerStyle = .overlay
            } else {
                regions[3].scroll.hasHorizontalScroller = true
                regions[3].scroll.hasVerticalScroller = true
                regions[3].scroll.scrollerStyle = .overlay
            }
            lastRevision = -1
            needsLayout = true
        }
        if lastRevision != model.revision {
            lastRevision = model.revision
            regions.forEach {
                // Scale the table's actual geometry instead of magnifying the
                // scroll document. Header and body then share one coordinate
                // system in both normal and frozen layouts.
                if abs($0.scroll.magnification - 1) > 0.001 {
                    $0.scroll.setMagnification(1, centeredAt: $0.scroll.contentView.bounds.origin)
                }
                $0.table.intercellSpacing = NSSize(width: model.zoom, height: model.zoom)
                $0.table.rowHeight = 29 * model.zoom
                for column in $0.table.tableColumns {
                    if let id = Int(column.identifier.rawValue) {
                        let width = (id >= 0 ? (model.columnWidths[id] ?? 140) : 48) * model.zoom
                        if abs(column.width - width) > 0.1 { column.width = width }
                        column.minWidth = (id >= 0 ? 65 : 48) * model.zoom
                        column.maxWidth = (id >= 0 ? 1000 : 48) * model.zoom
                    }
                }
                ($0.table.headerView as? GridColumnHeader)?.applyZoom(model.zoom)
                $0.table.reloadData()
                $0.alignDocumentToHeader()
                $0.table.headerView?.needsDisplay = true
            }
            if shouldRestoreFocus {
                let target = regions.first(where: {
                    $0.range.contains(model.anchor.row) &&
                    $0.table.tableColumns.contains { $0.identifier.rawValue == String(model.anchor.column) }
                })?.table ?? regions.last?.table
                if let target { window?.makeFirstResponder(target) }
            }
            needsLayout = true
        }
        updateFillOptionsButton()
        restoreScrollPositions(
            previousOrigins,
            previousRegionCount: previousRegionCount,
            previousSignature: previousSignature,
            revision: revisionToRestore)
    }

    private func restoreScrollPositions(_ origins: [NSPoint], previousRegionCount: Int,
                                        previousSignature: String, revision: Int) {
        guard !origins.isEmpty, previousRegionCount == regions.count,
              viewportLayout(previousSignature) == viewportLayout(signature) else { return }
        layoutSubtreeIfNeeded()
        for (index, origin) in origins.enumerated() where index < regions.count {
            let scroll = regions[index].scroll
            let clip = scroll.contentView
            let visibleSize = clip.bounds.size
            let documentSize = scroll.documentView?.frame.size ?? .zero
            let maximum = NSPoint(
                x: max(0, documentSize.width - visibleSize.width),
                y: max(0, documentSize.height - visibleSize.height))
            let target = NSPoint(
                x: min(max(0, origin.x), maximum.x),
                y: min(max(0, origin.y), maximum.y))
            clip.scroll(to: target)
            scroll.reflectScrolledClipView(clip)
        }
        if regions.count == 4 { sync(from: 3) }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.revision == revision,
                  self.viewportLayout(previousSignature) == self.viewportLayout(self.signature) else { return }
            self.layoutSubtreeIfNeeded()
            self.restoreScrollPositionsImmediately(origins)
        }
    }

    private func viewportLayout(_ value: String) -> String {
        value.split(separator: "/").prefix(2).joined(separator: "/")
    }

    private func restoreScrollPositionsImmediately(_ origins: [NSPoint]) {
        guard origins.count == regions.count else { return }
        for (index, origin) in origins.enumerated() {
            let scroll = regions[index].scroll
            let clip = scroll.contentView
            let visibleSize = clip.bounds.size
            let documentSize = scroll.documentView?.frame.size ?? .zero
            let maximum = NSPoint(
                x: max(0, documentSize.width - visibleSize.width),
                y: max(0, documentSize.height - visibleSize.height))
            let target = NSPoint(
                x: min(max(0, origin.x), maximum.x),
                y: min(max(0, origin.y), maximum.y))
            clip.scroll(to: target)
            scroll.reflectScrolledClipView(clip)
        }
        if regions.count == 4 { sync(from: 3) }
    }
    override func layout() {
        super.layout()
        if regions.count == 1 {
            regions[0].alignDocumentToHeader()
            regions[0].scroll.frame = bounds
            regions[0].scroll.hasHorizontalScroller = true
            regions[0].scroll.hasVerticalScroller = true
            updateFillOptionsButton()
            return
        }
        guard regions.count == 4 else { return }
        regions.forEach { $0.alignDocumentToHeader() }
        let frozenWidth = (0..<min(model.frozenColumns, model.columnCount - 1)).reduce(CGFloat(49)) { $0 + (model.columnWidths[$1] ?? 140) + 1 } * model.zoom
        let frozenHeight = model.frozenRows == 0 ? 0 : ((0..<min(model.frozenRows, model.rowCount - 1)).reduce(CGFloat(23)) { $0 + model.displayRowHeight($1) + 1 }) * model.zoom
        // Keep part of the live body visible even when many rows or columns
        // are frozen. If the frozen area is larger than its viewport, its own
        // scroll view exposes the remaining frozen content instead of cutting
        // it off at an arbitrary percentage of the window.
        let bodyMinimumWidth: CGFloat = 180
        let bodyMinimumHeight: CGFloat = 140
        let w = min(frozenWidth, max(49, bounds.width - bodyMinimumWidth))
        let h = min(frozenHeight, max(23, bounds.height - bodyMinimumHeight))
        let frozenWidthOverflows = frozenWidth > w + 0.5
        let frozenHeightOverflows = frozenHeight > h + 0.5
        regions[0].scroll.frame = NSRect(x: 0, y: 0, width: w, height: h)
        regions[1].scroll.frame = NSRect(x: w, y: 0, width: max(0, bounds.width-w), height: h)
        regions[2].scroll.frame = NSRect(x: 0, y: h, width: w, height: max(0, bounds.height-h))
        regions[3].scroll.frame = NSRect(x: w, y: h, width: max(0, bounds.width-w), height: max(0, bounds.height-h))
        regions[0].scroll.isHidden = h == 0; regions[1].scroll.isHidden = h == 0
        for (index, region) in regions.enumerated() {
            let isBody = index == 3
            let needsFrozenHorizontalScroll = frozenWidthOverflows && (index == 0 || index == 2)
            let needsFrozenVerticalScroll = frozenHeightOverflows && (index == 0 || index == 1)
            region.scroll.scrollerStyle = .overlay
            region.scroll.hasHorizontalScroller = isBody || needsFrozenHorizontalScroll
            region.scroll.hasVerticalScroller = isBody || needsFrozenVerticalScroll
        }
        updateFillOptionsButton()
    }
    func sync(from index: Int) {
        guard !syncing, regions.count == 4 else { return }
        syncing = true
        let source = regions[index].scroll.contentView.bounds.origin
        for other in 0..<4 where other != index {
            var point = regions[other].scroll.contentView.bounds.origin
            if index % 2 == other % 2 { point.x = source.x }
            if index / 2 == other / 2 { point.y = source.y }
            regions[other].scroll.contentView.scroll(to: point)
            regions[other].scroll.reflectScrolledClipView(regions[other].scroll.contentView)
        }
        syncing = false
    }
}

final class WorksheetScrollView: NSScrollView {
    weak var editor: GridEditorModel?
    override func magnify(with event: NSEvent) {
        window?.makeFirstResponder(nil)
        if let editor { editor.setZoom(editor.zoom * (1 + event.magnification)) }
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            window?.makeFirstResponder(nil)
            if let editor { editor.setZoom(editor.zoom * exp(-event.scrollingDeltaY * 0.01)) }
            return
        }

        // Consume wheel/trackpad events locally. When this AppKit view is
        // embedded in the SwiftUI horizontal scroll view used for multi-table
        // mode, forwarding the event to the responder chain lets the outer
        // pane switcher move together with the table contents. Clamp the
        // document origin here so only this table (and its synchronized frozen
        // regions) responds.
        let clip = contentView
        let documentSize = documentView?.frame.size ?? .zero
        let visibleSize = clip.bounds.size
        let maximum = NSPoint(x: max(0, documentSize.width - visibleSize.width),
                              y: max(0, documentSize.height - visibleSize.height))
        let origin = clip.bounds.origin
        let target = NSPoint(
            x: min(max(0, origin.x - event.scrollingDeltaX), maximum.x),
            y: min(max(0, origin.y - event.scrollingDeltaY), maximum.y))
        if target != origin {
            clip.scroll(to: target)
            reflectScrolledClipView(clip)
        }
    }
}

@MainActor
final class GridRegion: NSObject, NSTableViewDelegate, NSTableViewDataSource {
    let model: GridEditorModel
    let range: Range<Int>
    let scroll = WorksheetScrollView()
    let table = CellGridTable()
    init(_ model: GridEditorModel, rows: Range<Int>, columns: Range<Int>, header: Bool) {
        self.model = model; range = rows
        super.init()
        scroll.editor = model
        scroll.minMagnification = 0.5; scroll.maxMagnification = 2.5
        table.editor = model; table.rowOffset = rows.lowerBound
        table.delegate = self; table.dataSource = self
        // macOS's automatic/inset NSTableView style adds a small top inset
        // while the custom column header remains pinned at y=0. That makes
        // the first row start underneath the header (only its lower strip is
        // visible). A worksheet is a continuous grid, so use the edge-to-edge
        // style and keep the header/body coordinates in the same origin.
        table.style = .fullWidth
        table.rowHeight = 29 * model.zoom; table.intercellSpacing = NSSize(width: model.zoom, height: model.zoom)
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.gridColor = .separatorColor; table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing; table.allowsColumnReordering = false
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.headerView = header ? GridColumnHeader(frame: NSRect(x: 0, y: 0, width: 100, height: 23)) : nil
        for column in columns {
            let definition = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(column)))
            definition.title = column < 0 ? "行" : GridAddress.columnName(column)
            definition.width = (column < 0 ? 48 : model.columnWidths[column] ?? 140) * model.zoom
            definition.minWidth = (column < 0 ? 48 : 65) * model.zoom
            definition.maxWidth = (column < 0 ? 48 : 1000) * model.zoom
            definition.resizingMask = column < 0 ? [] : .userResizingMask
            definition.isEditable = column >= 0
            let cell = NSTextFieldCell(textCell: "")
            cell.font = .systemFont(ofSize: 12 * model.zoom); cell.lineBreakMode = .byTruncatingTail
            cell.isScrollable = true; cell.isEditable = column >= 0
            definition.dataCell = cell; table.addTableColumn(definition)
        }
        scroll.documentView = table
        scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor
        scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
        table.reloadData()
        alignDocumentToHeader()
    }

    func alignDocumentToHeader() {
        let topInset = table.headerView?.frame.height ?? 0
        guard topInset > 0 else {
            if table.frame.origin.y != 0 { table.setFrameOrigin(NSPoint(x: table.frame.origin.x, y: 0)) }
            return
        }
        guard abs(table.frame.origin.y - topInset) > 0.5 else { return }
        table.setFrameOrigin(NSPoint(x: table.frame.origin.x, y: topInset))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { range.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        model.displayRowHeight(row + range.lowerBound) * model.zoom
    }
    func tableViewColumnDidResize(_ notification: Notification) {
        guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              let id = Int(column.identifier.rawValue), id >= 0 else { return }
        let baseWidth = column.width / max(0.5, model.zoom)
        guard abs((model.columnWidths[id] ?? 140) - baseWidth) > 0.1 else { return }
        model.columnWidths[id] = baseWidth; model.revision += 1
    }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let r = row + range.lowerBound
        guard let c = Int(tableColumn?.identifier.rawValue ?? "-1"), c >= 0 else { return String(r + 1) }
        let address = GridAddress(row: r, column: c)
        if let table = tableView as? CellGridTable,
           let marked = table.markedDisplayText(for: address) { return marked }
        return address == model.anchor ? model.inputText(address) : model.text(address)
    }
    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard let c = Int(tableColumn?.identifier.rawValue ?? "-1"), c >= 0 else { return }
        model.edit([GridAddress(row: row + range.lowerBound, column: c): object as? String ?? ""])
    }
    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        guard let c = Int(tableColumn?.identifier.rawValue ?? "-1"), c >= 0 else { return false }
        return !model.isBusy
    }
    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        guard let field = cell as? NSTextFieldCell, let c = Int(tableColumn?.identifier.rawValue ?? "-1") else { return }
        let r = row + range.lowerBound
        field.font = .systemFont(ofSize: 12 * model.zoom)
        let selected = model.rows.contains(r) && (c < 0 || model.columns.contains(c))
        let edited = model.changes[GridAddress(row: r, column: c)] != nil
        field.drawsBackground = selected || edited || c < 0
        field.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.22)
            : edited ? NSColor.systemOrange.withAlphaComponent(0.12) : .controlBackgroundColor
        field.textColor = c < 0 ? .secondaryLabelColor : .labelColor
        field.usesSingleLineMode = !model.adaptiveRows || c < 0
        field.isScrollable = !model.adaptiveRows || c < 0
        field.wraps = model.adaptiveRows && c >= 0
        field.lineBreakMode = model.adaptiveRows && c >= 0 ? .byWordWrapping : .byTruncatingTail
    }
}

struct GridEditorPane: View {
    @ObservedObject var model: GridEditorModel
    let title: String
    let exportAction: (() -> Void)?
    let showsSelectionBorder: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    Text(model.snapshot?.fileURL.lastPathComponent ?? "选择一张表").font(.headline).lineLimit(1)
                }
                Spacer()
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo || model.isBusy).help("撤销 ⌘Z")
                Button("保存\(model.changes.isEmpty ? "" : "（\(model.changes.count)）")") { commit(); model.save() }
                    .buttonStyle(.borderedProminent).disabled(model.changes.isEmpty || model.isBusy)
                Menu {
                    Button("保存并导表") { commit(); model.save(afterSave: exportAction) }.disabled(exportAction == nil)
                    Button("重新读取") { if let s = model.snapshot { model.load(s.fileURL, sheetPath: s.sheet.archivePath) } }.disabled(!model.changes.isEmpty)
                    Button("外部打开") { if let s = model.snapshot { NSWorkspace.shared.open(s.fileURL) } }
                    Button("在 Finder 中显示") { if let s = model.snapshot { NSWorkspace.shared.activateFileViewerSelecting([s.fileURL]) } }
                } label: { Image(systemName: "ellipsis") }.disabled(model.isBusy || model.snapshot == nil)
            }.padding(12)
            if let snapshot = model.snapshot {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(snapshot.sheets) { sheet in
                            Button(sheet.name) { model.load(snapshot.fileURL, sheetPath: sheet.archivePath) }
                                .buttonStyle(.bordered).tint(sheet == snapshot.sheet ? .accentColor : .secondary)
                                .disabled(model.isBusy || !model.changes.isEmpty)
                        }
                    }.padding(.horizontal, 12).padding(.bottom, 8)
                }
                HStack(spacing: 8) {
                    Text(model.selectionLabel).font(.caption.monospaced()).frame(minWidth: 72)
                    TextField("单元格内容或公式", text: Binding(get: { model.inputText(model.anchor) }, set: { model.edit([model.anchor: $0]) }))
                        .textFieldStyle(.roundedBorder).onSubmit { commit() }
                        .help("选中公式单元格时显示完整公式；修改公式请保留开头的 =")
                        .disabled(model.isBusy)
                    Button { commit() } label: { Image(systemName: "checkmark") }.help("应用到选中的起始单元格")
                    Button { commit(); model.showingFullContent = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .help("展开查看当前单元格的完整内容")
                }.padding(.horizontal, 12).padding(.bottom, 8)
                Divider()
                HStack {
                    Menu {
                        Button("指定冻结行、列…") { commit(); model.configureFreeze() }
                        Button("冻结到当前单元格（含当前行列）") {
                            commit()
                            model.frozenRows = min(model.anchor.row + 1, model.rowCount - 1)
                            model.frozenColumns = min(model.anchor.column + 1, model.columnCount - 1)
                            model.revision += 1
                        }
                        Button("取消冻结") { model.frozenRows = 0; model.frozenColumns = 0; model.revision += 1 }
                    } label: { Label(model.frozenRows + model.frozenColumns == 0 ? "冻结" : "冻结 \(model.frozenRows) 行 · \(model.frozenColumns) 列", systemImage: "pin") }
                    Menu("选择") {
                        Button("选中当前整行") { model.selectRows(model.anchor.row, extending: false) }
                        Button("选中当前整列") { model.selectColumns(model.anchor.column, extending: false) }
                        Button("复制当前整行") { model.selectRows(model.anchor.row, extending: false); model.copy() }
                        Button("复制当前整列") { model.selectColumns(model.anchor.column, extending: false); model.copy() }
                    }
                    Menu("自适应") {
                        Button("智能适配行高与列宽") { commit(); model.fitColumns(); model.adaptiveRows = true }
                        Button("仅适配列宽") { commit(); model.fitColumns() }
                        Button(model.adaptiveRows ? "关闭自动换行与行高" : "自动换行与行高") { commit(); model.adaptiveRows.toggle() }
                        Divider()
                        Button("恢复默认行高、列宽") { commit(); model.resetCellLayout() }
                    }.help("列宽 120～360，行高最多 96；超长内容可在内容栏右侧展开查看")
                    Spacer()
                    Button("−") { commit(); model.setZoom(model.zoom - 0.1) }
                    Text("\(Int((model.zoom * 100).rounded()))%")
                        .monospacedDigit().frame(width: 42)
                    Button("+") { commit(); model.setZoom(model.zoom + 0.1) }
                    Button("重置大小") { commit(); model.setZoom(1) }
                }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 5)
                CellGrid(model: model)
                Divider()
                HStack {
                    Text("\(snapshot.rowCount) 行 · \(snapshot.columnCount) 列").font(.caption).foregroundStyle(.secondary)
                    Text("拖动选区右下角小方块可填充").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("复制选区") { model.copy() }.help("拖选或 Shift 点击选择范围 · ⌘C")
                    Button("粘贴") { model.paste() }.disabled(model.isBusy).help("从选区左上角粘贴 · ⌘V")
                }.controlSize(.small).padding(10)
            } else if model.isBusy {
                Spacer(); ProgressView("正在读取表格…"); Spacer()
            } else {
                ContentUnavailableView("选择一张表", systemImage: "tablecells", description: Text("从左侧选择表格，或打开另一项目的同名表并排编辑。"))
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(model.isError ? Color.red : Color.secondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $model.showingFullContent) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("完整内容 · \(model.anchor.reference)").font(.headline)
                    Spacer()
                    Button("复制内容") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.inputText(model.anchor), forType: .string)
                    }
                    Button("关闭") { model.showingFullContent = false }.keyboardShortcut(.cancelAction)
                }
                ScrollView {
                    Text(model.inputText(model.anchor).isEmpty ? "（空单元格）" : model.inputText(model.anchor))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("此窗口只读；修改内容请使用单元格编辑或上方内容栏。公式单元格展示原始公式。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(minWidth: 520, idealWidth: 680, minHeight: 360, idealHeight: 480)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if showsSelectionBorder {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
    private func commit() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}
