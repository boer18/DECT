import AppKit
import Combine
import Foundation
import Security
import SwiftUI

struct ExportProject: Identifiable, Hashable {
    let rootURL: URL
    let generatorURL: URL
    let displayPath: String

    var id: String { rootURL.standardizedFileURL.path }
    var name: String { rootURL.lastPathComponent }
    var workingDirectoryURL: URL { generatorURL.deletingLastPathComponent().standardizedFileURL }
}

struct CachedExportProject: Codable {
    let rootPath: String
    let generatorPath: String
    let displayPath: String

    init(_ project: ExportProject) {
        rootPath = project.rootURL.path
        generatorPath = project.generatorURL.path
        displayPath = project.displayPath
    }

    /// A cached entry is usable only while its source entrypoint still exists.
    /// This gives startup cache speed without trying to export a moved project.
    func restoreIfValid() -> ExportProject? {
        let manager = FileManager.default
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let generatorURL = URL(fileURLWithPath: generatorPath).standardizedFileURL
        let lubanConfig = rootURL.appendingPathComponent("Config/luban.conf")
        guard manager.fileExists(atPath: rootURL.path),
              manager.fileExists(atPath: generatorURL.path),
              manager.fileExists(atPath: lubanConfig.path)
        else { return nil }
        return ExportProject(rootURL: rootURL, generatorURL: generatorURL, displayPath: displayPath)
    }
}

struct ProjectListCache: Codable {
    let scanRootPath: String
    let projects: [CachedExportProject]
}

struct LocalizationLanguageColumn: Identifiable, Hashable {
    let code: String
    let displayName: String
    let columnIndex: Int

    var id: String { code }
}

struct LocalizationEntry: Identifiable, Hashable {
    let rowIndex: Int
    let key: String
    let translations: [String: String]

    var id: Int { rowIndex }
}

struct LocalizationWorkbook {
    let fileURL: URL
    let sheetName: String
    let languageColumns: [LocalizationLanguageColumn]
    let entries: [LocalizationEntry]
}

struct TranslationWorkItem {
    let entry: LocalizationEntry
    let sourceLanguage: String
    let sourceText: String
    let targetLanguages: [String]
}

struct TranslationConsistencyRequest: Encodable {
    let rowIndex: Int
    let key: String
    let sourceLanguage: String
    let sourceText: String
    let translations: [String: String]

    private enum CodingKeys: String, CodingKey {
        case rowIndex = "row"
        case key
        case sourceLanguage = "source_language"
        case sourceText = "source_text"
        case translations
    }
}

struct TranslationConsistencyFinding: Decodable, Hashable {
    let rowIndex: Int
    let languageCode: String
    let reason: String
    let suggestion: String?

    private enum CodingKeys: String, CodingKey {
        case rowIndex = "row"
        case languageCode = "language"
        case reason
        case suggestion
    }
}

struct TranslationConsistencyIssue: Identifiable, Hashable {
    let rowIndex: Int
    let key: String
    let sourceLanguage: String
    let sourceText: String
    let targetLanguage: String
    let targetLanguageName: String
    let currentTranslation: String
    let reason: String
    let suggestion: String?

    var id: String { "\(rowIndex)-\(targetLanguage)" }
}

struct LanguageWorkbookReaderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func localXMLName(_ qualifiedName: String) -> String {
    qualifiedName.split(separator: ":").last.map(String.init) ?? qualifiedName
}

/// Minimal XLSX reader for the TCST TbLanguage contract. It deliberately reads
/// only the first worksheet, matching the existing TCST LanguageTool, and never
/// modifies the workbook. This keeps the desktop tool independent of Unity.
enum LanguageWorkbookReader {
    private static let languageCodesByHeader: [String: String] = [
        "english": "en",
        "chinesesimplified": "zh-CN",
        "chinesetraditional": "zh-TW",
        "german": "de",
        "spanish": "es",
        "portuguese": "pt",
        "french": "fr",
        "japanese": "ja",
        "korean": "ko",
        "russian": "ru",
        "italian": "it",
        "turkish": "tr",
        "indonesian": "id",
        "filipino": "fil"
    ]

    static func read(fileURL: URL) throws -> LocalizationWorkbook {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else {
            throw LanguageWorkbookReaderError(message: "找不到 TbLanguage.xlsx：\(fileURL.path)")
        }

        let sharedStringsData = try? archiveEntry("xl/sharedStrings.xml", in: fileURL)
        let sharedStrings = sharedStringsData.map { SharedStringsParser.parse($0) } ?? []
        let sheetData = try archiveEntry("xl/worksheets/sheet1.xml", in: fileURL)
        let rows = try SheetRowsParser.parse(sheetData, sharedStrings: sharedStrings)

        guard let header = rows[1] else {
            throw LanguageWorkbookReaderError(message: "TbLanguage.xlsx 的 Sheet1 缺少表头行。")
        }
        guard let keyColumn = header.first(where: {
            $0.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "key"
        })?.key else {
            throw LanguageWorkbookReaderError(message: "TbLanguage.xlsx 的 Sheet1 未找到 key 列。")
        }

        let languageColumns = header.compactMap { column, rawHeader -> LocalizationLanguageColumn? in
            let trimmedHeader = rawHeader.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmedHeader
                .replacingOccurrences(of: "#", with: "")
                .replacingOccurrences(of: " ", with: "")
                .lowercased()
            guard let code = languageCodesByHeader[normalized] else { return nil }
            return LocalizationLanguageColumn(
                code: code,
                displayName: trimmedHeader.replacingOccurrences(of: "##", with: ""),
                columnIndex: column
            )
        }.sorted { $0.columnIndex < $1.columnIndex }

        guard languageColumns.count >= 2 else {
            throw LanguageWorkbookReaderError(message: "TbLanguage.xlsx 的 Sheet1 未识别出标准语言列。")
        }

        let entries = rows.keys.filter { $0 >= 3 }.sorted().compactMap { rowIndex -> LocalizationEntry? in
            guard let row = rows[rowIndex],
                  let rawKey = row[keyColumn]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawKey.isEmpty
            else { return nil }
            var translations: [String: String] = [:]
            for language in languageColumns {
                translations[language.code] = row[language.columnIndex] ?? ""
            }
            return LocalizationEntry(rowIndex: rowIndex, key: rawKey, translations: translations)
        }

        return LocalizationWorkbook(
            fileURL: fileURL,
            sheetName: "Sheet1",
            languageColumns: languageColumns,
            entries: entries
        )
    }

    private static func archiveEntry(_ entryName: String, in workbook: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", workbook.path, entryName]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        // Drain stdout before waiting. Large Sheet1 XML files otherwise fill the
        // pipe buffer and make unzip wait forever while this process waits for it.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw LanguageWorkbookReaderError(message: "无法读取 \(entryName)：\(details.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return data
    }
}

final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var currentString = ""
    private var readingText = false

    static func parse(_ data: Data) -> [String] {
        let delegate = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        return parser.parse() ? delegate.strings : []
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let localName = localXMLName(name)
        if localName == "si" { currentString = "" }
        if localName == "t" { readingText = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readingText { currentString += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        let localName = localXMLName(name)
        if localName == "t" { readingText = false }
        if localName == "si" { strings.append(currentString) }
    }
}

final class SheetRowsParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private(set) var rows: [Int: [Int: String]] = [:]
    private var currentRow = 0
    private var currentColumn: Int?
    private var currentCellType = ""
    private var currentCellValue = ""
    private var readingCellValue = false
    private var readingInlineText = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    static func parse(_ data: Data, sharedStrings: [String]) throws -> [Int: [Int: String]] {
        let delegate = SheetRowsParser(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw LanguageWorkbookReaderError(message: "无法解析 TbLanguage.xlsx 的 Sheet1 数据。")
        }
        return delegate.rows
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch localXMLName(name) {
        case "row":
            currentRow = Int(attributeDict["r"] ?? "0") ?? 0
        case "c":
            currentColumn = Self.columnIndex(from: attributeDict["r"] ?? "")
            currentCellType = attributeDict["t"] ?? ""
            currentCellValue = ""
        case "v":
            readingCellValue = true
        case "t":
            if currentCellType == "inlineStr" { readingInlineText = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readingCellValue || readingInlineText { currentCellValue += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch localXMLName(name) {
        case "v":
            readingCellValue = false
        case "t":
            readingInlineText = false
        case "c":
            guard currentRow > 0, let currentColumn else { return }
            let value: String
            if currentCellType == "s", let index = Int(currentCellValue), sharedStrings.indices.contains(index) {
                value = sharedStrings[index]
            } else {
                value = currentCellValue
            }
            var row = rows[currentRow] ?? [:]
            row[currentColumn] = value
            rows[currentRow] = row
            self.currentColumn = nil
        default:
            break
        }
    }

    private static func columnIndex(from cellReference: String) -> Int? {
        let letters = cellReference.prefix { $0.isLetter }
        guard !letters.isEmpty else { return nil }
        return letters.uppercased().unicodeScalars.reduce(0) { partial, scalar in
            partial * 26 + Int(scalar.value - 64)
        } - 1
    }
}

struct LocalizationCellUpdate: Hashable {
    let rowIndex: Int
    let columnIndex: Int
    let languageCode: String
    let value: String
}

enum LanguageWorkbookWriter {
    /// Changes are first validated in a temporary workbook, then the original
    /// is replaced in one operation. The user requested no project-side backup,
    /// so this deliberately leaves no .bak file beside TbLanguage.xlsx.
    static func write(fileURL: URL, updates: [LocalizationCellUpdate]) throws -> LocalizationWorkbook {
        guard !updates.isEmpty else { return try LanguageWorkbookReader.read(fileURL: fileURL) }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw LanguageWorkbookReaderError(message: "找不到要写入的 TbLanguage.xlsx：\(fileURL.path)")
        }

        let manager = FileManager.default
        let temporaryRoot = manager.temporaryDirectory
            .appendingPathComponent("OneClickTableExport-language-write-\(UUID().uuidString)", isDirectory: true)
        let unpackedRoot = temporaryRoot.appendingPathComponent("xlsx", isDirectory: true)
        let replacementURL = temporaryRoot.appendingPathComponent("TbLanguage.replacement.xlsx")
        defer { try? manager.removeItem(at: temporaryRoot) }

        // Translation services can occasionally return an XML 1.0 control
        // character. It is valid in a JSON response but invalid inside an xlsx
        // worksheet XML text node, causing the post-write reader to fail.
        // Normalize before both writing and validating so the in-app view always
        // reflects exactly what was persisted.
        let normalizedUpdates = updates.map {
            LocalizationCellUpdate(
                rowIndex: $0.rowIndex,
                columnIndex: $0.columnIndex,
                languageCode: $0.languageCode,
                value: normalizedXMLText($0.value)
            )
        }

        try manager.createDirectory(at: unpackedRoot, withIntermediateDirectories: true)
        try runArchiveTool("/usr/bin/unzip", arguments: ["-q", fileURL.path, "-d", unpackedRoot.path])

        let sheetURL = unpackedRoot.appendingPathComponent("xl/worksheets/sheet1.xml")
        let originalSheet = try String(contentsOf: sheetURL, encoding: .utf8)
        let revisedSheet = try rewriteSheetXML(originalSheet, updates: normalizedUpdates)
        try validateRevisedSheetXML(revisedSheet)
        try revisedSheet.write(to: sheetURL, atomically: true, encoding: .utf8)

        try runArchiveTool(
            "/usr/bin/zip",
            arguments: ["-q", "-r", replacementURL.path, "."],
            currentDirectoryURL: unpackedRoot
        )

        let validatedWorkbook = try LanguageWorkbookReader.read(fileURL: replacementURL)
        try verify(updates: normalizedUpdates, in: validatedWorkbook)
        _ = try manager.replaceItemAt(fileURL, withItemAt: replacementURL)
        return try LanguageWorkbookReader.read(fileURL: fileURL)
    }

    private static func runArchiveTool(
        _ executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        let error = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw LanguageWorkbookReaderError(message: "无法更新语言表：\(details.isEmpty ? "归档工具执行失败" : details)")
        }
    }

    private static func verify(updates: [LocalizationCellUpdate], in workbook: LocalizationWorkbook) throws {
        for update in updates {
            guard let entry = workbook.entries.first(where: { $0.rowIndex == update.rowIndex }),
                  entry.translations[update.languageCode] == update.value
            else {
                throw LanguageWorkbookReaderError(message: "写入校验失败：第 \(update.rowIndex) 行的 \(update.languageCode) 未保留预期文本。")
            }
        }
    }

    /// Keep this validation immediately before packaging the temporary workbook.
    /// It prevents a malformed replacement from ever reaching the project file,
    /// while the location-only diagnostic makes a rare structural failure
    /// actionable without logging translated copy or credentials.
    private static func validateRevisedSheetXML(_ xml: String) throws {
        let parser = XMLParser(data: Data(xml.utf8))
        guard !parser.parse() else { return }

        let parserMessage = parser.parserError?.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let location = "第 \(parser.lineNumber) 行、第 \(parser.columnNumber) 列"
        let details = (parserMessage?.isEmpty == false) ? "（\(parserMessage!)）" : ""
        throw LanguageWorkbookReaderError(
            message: "翻译结果无法写入 Sheet1：XML 结构校验失败，\(location)\(details)。原语言表未被修改。"
        )
    }

    private static func rewriteSheetXML(_ xml: String, updates: [LocalizationCellUpdate]) throws -> String {
        var revisedXML = xml
        for update in updates {
            revisedXML = try replacingCell(
                in: revisedXML,
                rowIndex: update.rowIndex,
                columnIndex: update.columnIndex,
                value: update.value
            )
        }
        return revisedXML
    }

    private static func replacingCell(
        in xml: String,
        rowIndex: Int,
        columnIndex: Int,
        value: String
    ) throws -> String {
        let rowPattern = "<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?row\\b[^>]*\\br=\\\"\(rowIndex)\\\"[^>]*>(?s:.*?)</(?:[A-Za-z_][A-Za-z0-9_.-]*:)?row>"
        let rowRegex = try NSRegularExpression(pattern: rowPattern)
        guard let rowMatch = rowRegex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)) else {
            throw LanguageWorkbookReaderError(message: "写入失败：Sheet1 中找不到第 \(rowIndex) 行。")
        }
        let rowRange = rowMatch.range
        let rowText = (xml as NSString).substring(with: rowRange)
        let namespacePrefix = xmlPrefix(in: rowText, element: "row")
        let cellReference = "\(columnName(for: columnIndex))\(rowIndex)"
        let cellPattern = "<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?c\\b([^>]*\\br=\\\"\(cellReference)\\\"[^>]*?)\\s*/>|<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?c\\b([^>]*\\br=\\\"\(cellReference)\\\"[^>]*)>(?s:.*?)</(?:[A-Za-z_][A-Za-z0-9_.-]*:)?c>"
        let cellRegex = try NSRegularExpression(pattern: cellPattern)
        let cellTag = inlineStringCell(
            reference: cellReference,
            namespacePrefix: namespacePrefix,
            attributes: nil,
            value: value
        )

        var revisedRow = rowText
        if let cellMatch = cellRegex.firstMatch(in: rowText, range: NSRange(rowText.startIndex..., in: rowText)) {
            let attributeRange = cellMatch.range(at: cellMatch.range(at: 1).location != NSNotFound ? 1 : 2)
            let attributes = (rowText as NSString).substring(with: attributeRange)
            let replacement = inlineStringCell(
                reference: cellReference,
                namespacePrefix: namespacePrefix,
                attributes: attributes,
                value: value
            )
            revisedRow = (rowText as NSString).replacingCharacters(in: cellMatch.range, with: replacement)
        } else {
            revisedRow = try insertingCell(
                cellTag,
                columnIndex: columnIndex,
                into: rowText,
                namespacePrefix: namespacePrefix
            )
        }
        return (xml as NSString).replacingCharacters(in: rowRange, with: revisedRow)
    }

    private static func inlineStringCell(
        reference: String,
        namespacePrefix: String,
        attributes: String?,
        value: String
    ) -> String {
        let typeAttributeRegex = try? NSRegularExpression(pattern: "\\s+t\\s*=\\s*(?:\\\"[^\\\"]*\\\"|'[^']*')")
        var keptAttributes = attributes ?? " r=\"\(reference)\""
        if let typeAttributeRegex {
            keptAttributes = typeAttributeRegex.stringByReplacingMatches(
                in: keptAttributes,
                range: NSRange(keptAttributes.startIndex..., in: keptAttributes),
                withTemplate: ""
            )
        }
        if !keptAttributes.contains("r=\"") && !keptAttributes.contains("r='") {
            keptAttributes += " r=\"\(reference)\""
        }
        let escapedValue = escapeXML(value)
        return "<\(namespacePrefix)c\(keptAttributes) t=\"inlineStr\"><\(namespacePrefix)is><\(namespacePrefix)t xml:space=\"preserve\">\(escapedValue)</\(namespacePrefix)t></\(namespacePrefix)is></\(namespacePrefix)c>"
    }

    private static func insertingCell(
        _ cellTag: String,
        columnIndex targetColumnIndex: Int,
        into rowText: String,
        namespacePrefix: String
    ) throws -> String {
        // Insert before the opening `<c>` tag of the first cell to the right.
        // The previous implementation used the location of that cell's `r=`
        // attribute, which split the tag itself whenever a blank target cell
        // had to be created (for example, inserting D before `<c r=\"F1201\">`).
        let cellTagRegex = try NSRegularExpression(
            pattern: "<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?c\\b[^>]*\\br\\s*=\\s*\\\"([A-Z]+)[0-9]+\\\"[^>]*>"
        )
        let matches = cellTagRegex.matches(in: rowText, range: NSRange(rowText.startIndex..., in: rowText))
        let insertionLocation = matches.first(where: { match in
            let letters = (rowText as NSString).substring(with: match.range(at: 1))
            return columnIndex(fromLetters: letters) > targetColumnIndex
        })?.range.location ?? closingRowLocation(in: rowText, namespacePrefix: namespacePrefix)
        guard insertionLocation != NSNotFound else {
            throw LanguageWorkbookReaderError(message: "写入失败：无法定位 Excel 行结束位置。")
        }
        return (rowText as NSString).replacingCharacters(in: NSRange(location: insertionLocation, length: 0), with: cellTag)
    }

    private static func closingRowLocation(in rowText: String, namespacePrefix: String) -> Int {
        let closingTag = "</\(namespacePrefix)row>"
        return (rowText as NSString).range(of: closingTag).location
    }

    private static func xmlPrefix(in text: String, element: String) -> String {
        let pattern = "<([A-Za-z_][A-Za-z0-9_.-]*:)?\(element)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range(at: 1).location != NSNotFound
        else { return "" }
        return (text as NSString).substring(with: match.range(at: 1))
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func normalizedXMLText(_ value: String) -> String {
        let allowedScalars = value.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x9, 0xA, 0xD:
                return true
            case 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
                return true
            default:
                return false
            }
        }
        return String(String.UnicodeScalarView(allowedScalars))
    }

    private static func columnName(for index: Int) -> String {
        var value = index + 1
        var letters = ""
        while value > 0 {
            let remainder = (value - 1) % 26
            letters = String(UnicodeScalar(65 + remainder)!) + letters
            value = (value - 1) / 26
        }
        return letters
    }

    private static func columnIndex(fromLetters letters: String) -> Int {
        letters.uppercased().unicodeScalars.reduce(0) { partial, scalar in
            partial * 26 + Int(scalar.value - 64)
        } - 1
    }
}

struct TableContentImportPlan: Identifiable {
    let source: ProjectTable
    let destination: ProjectTable

    var id: String { "\(source.id)->\(destination.id)" }
}

enum WorkbookContentImporter {
    /// Imports only Sheet1's cell data into the target .xlsx. The target file,
    /// filename and its other workbook parts remain in place; no project-side
    /// backup is generated per the requested workflow.
    static func importSheet1Content(from sourceURL: URL, into targetURL: URL) throws {
        guard sourceURL.pathExtension.lowercased() == "xlsx",
              targetURL.pathExtension.lowercased() == "xlsx" else {
            throw LanguageWorkbookReaderError(message: "目前“导入表内容”仅支持 .xlsx 配置表。")
        }
        guard sourceURL.standardizedFileURL != targetURL.standardizedFileURL else {
            throw LanguageWorkbookReaderError(message: "源表和目标表不能是同一个文件。")
        }
        let manager = FileManager.default
        guard manager.fileExists(atPath: sourceURL.path), manager.fileExists(atPath: targetURL.path) else {
            throw LanguageWorkbookReaderError(message: "源表或目标表已不存在。")
        }

        let temporaryRoot = manager.temporaryDirectory
            .appendingPathComponent("OneClickTableExport-content-import-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = temporaryRoot.appendingPathComponent("source", isDirectory: true)
        let targetRoot = temporaryRoot.appendingPathComponent("target", isDirectory: true)
        let replacementURL = temporaryRoot.appendingPathComponent("target.replacement.xlsx")
        defer { try? manager.removeItem(at: temporaryRoot) }

        try manager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try manager.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        try runArchiveTool("/usr/bin/unzip", arguments: ["-q", sourceURL.path, "-d", sourceRoot.path])
        try runArchiveTool("/usr/bin/unzip", arguments: ["-q", targetURL.path, "-d", targetRoot.path])

        let sourceSheetURL = sourceRoot.appendingPathComponent("xl/worksheets/sheet1.xml")
        let targetSheetURL = targetRoot.appendingPathComponent("xl/worksheets/sheet1.xml")
        let sourceSheet = try String(contentsOf: sourceSheetURL, encoding: .utf8)
        let sourceSharedStrings = (try? readArchiveEntry("xl/sharedStrings.xml", in: sourceURL)).map { SharedStringsParser.parse($0) } ?? []
        let sourceData = try sheetDataBlock(in: sourceSheet)
        let inlineSourceData = try replacingSharedStringCells(in: sourceData, sharedStrings: sourceSharedStrings)
        let targetSheet = try String(contentsOf: targetSheetURL, encoding: .utf8)
        let revisedTargetSheet = try replacingSheetData(in: targetSheet, with: inlineSourceData)
        guard XMLParser(data: Data(revisedTargetSheet.utf8)).parse() else {
            throw LanguageWorkbookReaderError(message: "导入后的目标 Sheet1 XML 无法解析。")
        }
        try revisedTargetSheet.write(to: targetSheetURL, atomically: true, encoding: .utf8)

        try runArchiveTool(
            "/usr/bin/zip",
            arguments: ["-q", "-r", replacementURL.path, "."],
            currentDirectoryURL: targetRoot
        )
        try runArchiveTool("/usr/bin/unzip", arguments: ["-tq", replacementURL.path])
        let validatedTargetSheet = try String(decoding: readArchiveEntry("xl/worksheets/sheet1.xml", in: replacementURL), as: UTF8.self)
        guard try sheetDataBlock(in: validatedTargetSheet) == inlineSourceData else {
            throw LanguageWorkbookReaderError(message: "导入内容校验失败，目标表没有写入预期的 Sheet1 数据。")
        }
        _ = try manager.replaceItemAt(targetURL, withItemAt: replacementURL)
    }

    private static func runArchiveTool(
        _ executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        let error = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw LanguageWorkbookReaderError(message: "无法导入表内容：\(details.isEmpty ? "归档工具执行失败" : details)")
        }
    }

    private static func readArchiveEntry(_ entryName: String, in workbook: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", workbook.path, entryName]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw LanguageWorkbookReaderError(message: "无法读取工作簿内容：\(details.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return data
    }

    private static func sheetDataBlock(in sheetXML: String) throws -> String {
        let pattern = "<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?sheetData\\b[^>]*>(?s:.*?)</(?:[A-Za-z_][A-Za-z0-9_.-]*:)?sheetData>"
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: sheetXML, range: NSRange(sheetXML.startIndex..., in: sheetXML)) else {
            throw LanguageWorkbookReaderError(message: "工作簿 Sheet1 缺少 sheetData。")
        }
        return (sheetXML as NSString).substring(with: match.range)
    }

    private static func replacingSheetData(in sheetXML: String, with newSheetData: String) throws -> String {
        let pattern = "<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?sheetData\\b[^>]*>(?s:.*?)</(?:[A-Za-z_][A-Za-z0-9_.-]*:)?sheetData>"
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: sheetXML, range: NSRange(sheetXML.startIndex..., in: sheetXML)) else {
            throw LanguageWorkbookReaderError(message: "目标工作簿 Sheet1 缺少 sheetData。")
        }
        return (sheetXML as NSString).replacingCharacters(in: match.range, with: newSheetData)
    }

    private static func replacingSharedStringCells(in sheetData: String, sharedStrings: [String]) throws -> String {
        // Scan only opening <c> tags and move forward monotonically. A broad
        // cross-cell regex can backtrack badly on large generated worksheets.
        let openingCellRegex = try NSRegularExpression(pattern: "<([A-Za-z_][A-Za-z0-9_.-]*:)?c\\b")
        let typeRegex = try NSRegularExpression(pattern: "\\s+t\\s*=\\s*\\\"s\\\"")
        var cursor = sheetData.startIndex
        var revised = ""

        while let match = openingCellRegex.firstMatch(
            in: sheetData,
            range: NSRange(cursor..<sheetData.endIndex, in: sheetData)
        ), let matchRange = Range(match.range, in: sheetData) {
            revised += String(sheetData[cursor..<matchRange.lowerBound])
            guard let openingEnd = sheetData[matchRange.upperBound...].firstIndex(of: ">") else {
                revised += String(sheetData[matchRange.lowerBound...])
                break
            }
            let openingEndAfter = sheetData.index(after: openingEnd)
            let openingTag = String(sheetData[matchRange.lowerBound..<openingEndAfter])
            let prefix = match.range(at: 1).location == NSNotFound
                ? ""
                : (sheetData as NSString).substring(with: match.range(at: 1))
            let attributes = String(sheetData[matchRange.upperBound..<openingEnd])
            guard typeRegex.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)) != nil else {
                revised += openingTag
                cursor = openingEndAfter
                continue
            }

            let closingTag = "</\(prefix)c>"
            guard let closingRange = sheetData.range(of: closingTag, range: openingEndAfter..<sheetData.endIndex) else {
                revised += openingTag
                cursor = openingEndAfter
                continue
            }
            let cellBody = String(sheetData[openingEndAfter..<closingRange.lowerBound])
            let valueStartTag = "<\(prefix)v>"
            let valueEndTag = "</\(prefix)v>"
            guard let valueStart = cellBody.range(of: valueStartTag),
                  let valueEnd = cellBody.range(of: valueEndTag, range: valueStart.upperBound..<cellBody.endIndex),
                  let index = Int(cellBody[valueStart.upperBound..<valueEnd.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)),
                  sharedStrings.indices.contains(index)
            else {
                revised += String(sheetData[matchRange.lowerBound..<closingRange.upperBound])
                cursor = closingRange.upperBound
                continue
            }
            let cleanAttributes = typeRegex.stringByReplacingMatches(
                in: attributes,
                range: NSRange(attributes.startIndex..., in: attributes),
                withTemplate: ""
            )
            let value = escapeXML(sharedStrings[index])
            revised += "<\(prefix)c\(cleanAttributes) t=\"inlineStr\"><\(prefix)is><\(prefix)t xml:space=\"preserve\">\(value)</\(prefix)t></\(prefix)is></\(prefix)c>"
            cursor = closingRange.upperBound
        }
        revised += String(sheetData[cursor...])
        return revised
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

struct TranslationAPIConfiguration {
    static let defaultEndpoint = "https://lumos.diandian.info/winky/openai/v1/chat/completions"
    static let defaultModel = "gpt-4o"

    let apiKey: String
    let endpoint: String
    let model: String
    let keySourceDescription: String

    var hasAPIKey: Bool { !apiKey.isEmpty }
}

struct TranslationSettingsError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum TranslationSettingsStore {
    private static let endpointDefaultsKey = "translationAPIEndpoint"
    private static let modelDefaultsKey = "translationAPIModel"
    private static let keychainService = "com.centurygames.one-click-table-export.translation"
    private static let keychainAccount = "translation-api-key"
    private static let legacySuiteName = "com.unity3d.UnityEditor5.x"

    static func load() -> TranslationAPIConfiguration {
        let legacyDefaults = UserDefaults(suiteName: legacySuiteName)
        // The API key belongs to this app and must be entered by each user.
        // Keep the legacy suite only for non-sensitive endpoint/model defaults;
        // never read or fall back to TCST's LanguageTool key.
        let ownKey = keychainValue().map(stripWhitespace)
        let endpoint = UserDefaults.standard.string(forKey: endpointDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyEndpoint = legacyDefaults?.string(forKey: "LanguageTool_ApiUrl")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = UserDefaults.standard.string(forKey: modelDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyModel = legacyDefaults?.string(forKey: "LanguageTool_Model")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = ownKey ?? ""
        let keySource = apiKey.isEmpty ? "未配置" : "本工具钥匙串"
        return TranslationAPIConfiguration(
            apiKey: apiKey,
            endpoint: endpoint?.isEmpty == false ? endpoint! : (legacyEndpoint?.isEmpty == false ? legacyEndpoint! : TranslationAPIConfiguration.defaultEndpoint),
            model: model?.isEmpty == false ? model! : (legacyModel?.isEmpty == false ? legacyModel! : TranslationAPIConfiguration.defaultModel),
            keySourceDescription: keySource
        )
    }

    static func save(apiKeyInput: String, endpoint: String, model: String) throws {
        let cleanEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: cleanEndpoint)?.scheme?.hasPrefix("http") == true else {
            throw TranslationSettingsError(message: "请输入完整的 API URL（以 http:// 或 https:// 开头）。")
        }
        guard !cleanModel.isEmpty else {
            throw TranslationSettingsError(message: "请填写翻译模型名称。")
        }
        let cleanKey = stripWhitespace(apiKeyInput)
        if !cleanKey.isEmpty { try saveKeychainValue(cleanKey) }
        UserDefaults.standard.set(cleanEndpoint, forKey: endpointDefaultsKey)
        UserDefaults.standard.set(cleanModel, forKey: modelDefaultsKey)
    }

    private static func stripWhitespace(_ value: String) -> String {
        value.filter { !$0.isWhitespace && !$0.isNewline }
    }

    private static func keychainValue() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    private static func saveKeychainValue(_ value: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw TranslationSettingsError(message: "无法保存 API Key 到 macOS 钥匙串（错误 \(updateStatus)）。")
        }
        var addition = query
        addition[kSecValueData as String] = data
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TranslationSettingsError(message: "无法保存 API Key 到 macOS 钥匙串（错误 \(addStatus)）。")
        }
    }
}

enum TranslationClient {
    private struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let temperature: Double?
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }

    static func translate(
        key: String,
        sourceText: String,
        sourceLanguage: String,
        targetLanguages: [String],
        configuration: TranslationAPIConfiguration
    ) async throws -> [String: String] {
        guard configuration.hasAPIKey else {
            throw TranslationSettingsError(message: "尚未配置本工具的 API Key，请在“翻译 API 设置”中填写。")
        }
        guard !targetLanguages.isEmpty else { return [:] }
        let prompt = translationPrompt(
            key: key,
            sourceText: sourceText,
            sourceLanguage: sourceLanguage,
            targetLanguages: targetLanguages
        )
        let content = try await request(prompt: prompt, configuration: configuration)
        let results = parse(content: content, targetLanguages: targetLanguages)
        guard !results.isEmpty else {
            throw TranslationSettingsError(message: "翻译服务没有返回可识别的语言代码，请检查模型或 API 设置。")
        }
        return results
    }

    static func test(configuration: TranslationAPIConfiguration) async throws {
        guard configuration.hasAPIKey else {
            throw TranslationSettingsError(message: "尚未配置本工具的 API Key，请在“翻译 API 设置”中填写。")
        }
        _ = try await request(prompt: "Reply with exactly one word: OK", configuration: configuration)
    }

    static func checkConsistency(
        requests: [TranslationConsistencyRequest],
        configuration: TranslationAPIConfiguration
    ) async throws -> [TranslationConsistencyFinding] {
        guard configuration.hasAPIKey else {
            throw TranslationSettingsError(message: "尚未配置本工具的 API Key，请在“翻译 API 设置”中填写。")
        }
        guard !requests.isEmpty else { return [] }
        let content = try await request(
            prompt: consistencyPrompt(requests: requests),
            configuration: configuration
        )
        return try parseConsistency(content: content)
    }

    private static func request(prompt: String, configuration: TranslationAPIConfiguration) async throws -> String {
        guard let url = URL(string: configuration.endpoint) else {
            throw TranslationSettingsError(message: "API URL 无效。")
        }
        let modelName = configuration.model.lowercased()
        let disallowsTemperature = modelName.hasPrefix("gpt-5") || modelName.hasPrefix("o1") || modelName.hasPrefix("o3") || modelName.hasPrefix("o4")
        let body = ChatRequest(
            model: configuration.model,
            messages: [.init(role: "user", content: prompt)],
            temperature: disallowsTemperature ? nil : 0.3
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationSettingsError(message: "翻译服务未返回有效响应。")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw TranslationSettingsError(message: "翻译服务请求失败（HTTP \(httpResponse.statusCode)）。")
        }
        guard let parsed = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = parsed.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw TranslationSettingsError(message: "翻译服务响应格式无法识别。")
        }
        return content
    }

    private static func translationPrompt(
        key: String,
        sourceText: String,
        sourceLanguage: String,
        targetLanguages: [String]
    ) -> String {
        """
        你是游戏本地化翻译专家。请将游戏文案翻译成目标语言。

        规则：
        1. 保留 {0}、{1} 等占位符，不翻译、不改动。
        2. 保留 <color=#...>、</color>、<size>、</size> 等富文本标签，不翻译、不改动。
        3. 文案应简短自然，适合游戏 UI；参考 key 名推断使用场景。
        4. zh-TW 使用台湾地区习惯用语，不要只做简繁转换。
        5. 只返回每行“语言代码: 翻译结果”，不加引号、说明或 Markdown。

        Key: \(key)
        源语言: \(sourceLanguage)
        源文本: \(sourceText)
        目标语言: \(targetLanguages.joined(separator: ", "))
        """
    }

    private static func consistencyPrompt(requests: [TranslationConsistencyRequest]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let payload = String(data: (try? encoder.encode(requests)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        return """
        你是资深游戏本地化 QA。请逐条核对下方 JSON 中的 source_text 与 translations 是否语义一致。

        检查范围：原意、游戏 UI 语境、数值/占位符（如 {0}）、富文本标签（如 <color>）、否定与时态、专有名词。仅报告明确有问题的译文；自然的措辞差异、标点或风格偏好不要报告。请不要因为原文本身为空或无法判断而臆测问题。

        只返回合法 JSON，不能加 Markdown、解释文字或代码围栏，格式必须完全是：
        {"issues":[{"row":3,"language":"ja","reason":"中文简洁说明","suggestion":"建议译文；若无需替换可为空字符串"}]}

        若没有问题，返回 {"issues":[]}。
        `row` 和 `language` 必须与输入一致。只检查输入中存在的 translations，不要为缺失翻译创建问题。

        输入：
        \(payload)
        """
    }

    private static func parseConsistency(content: String) throws -> [TranslationConsistencyFinding] {
        struct Payload: Decodable { let issues: [TranslationConsistencyFinding] }
        let trimmed = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}")
        else {
            throw TranslationSettingsError(message: "一致性检查服务没有返回 JSON 结果。")
        }
        let json = String(trimmed[start...end])
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else {
            throw TranslationSettingsError(message: "一致性检查服务返回的 JSON 格式无法识别。")
        }
        return payload.issues.filter {
            $0.rowIndex > 0
                && !$0.languageCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func parse(content: String, targetLanguages: [String]) -> [String: String] {
        var results: [String: String] = [:]
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            var code = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if code.lowercased() == "zh_tw" || code.lowercased() == "zhtw" { code = "zh-TW" }
            if code.lowercased() == "zh_cn" || code.lowercased() == "zhcn" { code = "zh-CN" }
            guard !value.isEmpty,
                  let target = targetLanguages.first(where: { $0.caseInsensitiveCompare(code) == .orderedSame })
            else { continue }
            results[target] = value
        }
        return results
    }
}

@MainActor
final class LanguageBrowserViewModel: ObservableObject {
    @Published private(set) var workbook: LocalizationWorkbook?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isTranslating = false
    @Published private(set) var isCheckingConsistency = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var actionMessage: String?
    @Published private(set) var consistencyIssues: [TranslationConsistencyIssue] = []
    @Published private(set) var consistencyCheckedEntryCount = 0
    @Published var selectedProjectID: String?
    @Published var selectedEntryID: LocalizationEntry.ID?
    @Published var searchText = ""
    @Published var showsTranslationSettings = false
    @Published var showsConsistencyResults = false
    @Published var entryFilter: TranslationEntryFilter = .all
    @Published private(set) var operationProgress = 0.0
    private var operationTask: Task<Void, Never>?
    private var loadedFingerprint: Data?
    private var conflictingDrafts: Set<String> = []

    private static let selectedLanguageProjectDefaultsKey = "lastLanguageProjectRoot"
    private var drafts: [Int: [String: String]] = [:]
    private var draftOriginals: [Int: [String: String]] = [:]
    @Published private var draftRevision = 0

    init() {
        selectedProjectID = UserDefaults.standard.string(forKey: Self.selectedLanguageProjectDefaultsKey)
    }

    var isBusy: Bool { isLoading || isSaving || isTranslating || isCheckingConsistency }

    var pendingChangeCount: Int { pendingUpdates().count }

    var missingTranslationCellCount: Int {
        translationWorkItems().reduce(0) { $0 + $1.targetLanguages.count }
    }

    var consistencyEligibleEntryCount: Int { consistencyRequests().count }

    var filteredEntries: [LocalizationEntry] {
        guard let workbook else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return workbook.entries.filter { entry in
            let matches = query.isEmpty || entry.key.localizedCaseInsensitiveContains(query)
                || translations(for: entry).values.contains { $0.localizedCaseInsensitiveContains(query) }
            let filter = entryFilter == .all || (entryFilter == .edited && drafts[entry.rowIndex] != nil)
                || (entryFilter == .missing && workbook.languageColumns.contains { translation(for: entry, languageCode: $0.code).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            return matches && filter
        }
    }

    var selectedEntry: LocalizationEntry? {
        guard let selectedEntryID else { return nil }
        return workbook?.entries.first { $0.id == selectedEntryID }
    }

    func ensureProject(available projects: [ExportProject], preferredProjectID: String?) {
        guard !projects.isEmpty else {
            workbook = nil
            selectedEntryID = nil
            return
        }
        let preferredID = preferredProjectID ?? selectedProjectID
            ?? UserDefaults.standard.string(forKey: Self.selectedLanguageProjectDefaultsKey)
        let project = projects.first { $0.id == preferredID } ?? projects.first
        if let project, project.id != selectedProjectID || workbook == nil {
            select(project: project)
        }
    }

    func select(project: ExportProject) {
        guard !isBusy else { return }
        persistDrafts()
        selectedProjectID = project.id
        UserDefaults.standard.set(project.id, forKey: Self.selectedLanguageProjectDefaultsKey)
        load(project: project)
    }

    func reload(available projects: [ExportProject]) {
        guard !isBusy else { return }
        persistDrafts()
        guard let project = projects.first(where: { $0.id == selectedProjectID }) else { return }
        load(project: project)
    }

    func translation(for entry: LocalizationEntry, languageCode: String) -> String {
        drafts[entry.rowIndex]?[languageCode] ?? entry.translations[languageCode] ?? ""
    }

    func translationBinding(for entry: LocalizationEntry, languageCode: String) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.translation(for: entry, languageCode: languageCode) ?? "" },
            set: { [weak self] value in self?.setTranslation(value, for: entry, languageCode: languageCode) }
        )
    }

    func savePendingChanges(afterSave: (() -> Void)? = nil) {
        guard !isBusy else { return }
        guard conflictingDrafts.isEmpty else {
            errorMessage = "有 \(conflictingDrafts.count) 个草稿单元格的原表内容已变化。请在“已修改”中逐格核对并编辑后保存。"
            return
        }
        guard let workbook else {
            errorMessage = "还没有可写入的语言表。"
            return
        }
        let updates = pendingUpdates()
        guard !updates.isEmpty else {
            actionMessage = "没有需要写入的修改。"
            afterSave?()
            return
        }
        let fileURL = workbook.fileURL
        let expectedFingerprint = loadedFingerprint
        isSaving = true
        errorMessage = nil
        actionMessage = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                if let expectedFingerprint, try GridWorkbookIO.fingerprint(fileURL) != expectedFingerprint {
                    throw LanguageWorkbookReaderError(message: "原语言表已被其他操作修改。草稿已保留，请重新读取并核对后保存。")
                }
                return try LanguageWorkbookWriter.write(fileURL: fileURL, updates: updates)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSaving = false
                guard self.workbook?.fileURL == fileURL else { return }
                switch result {
                case .success(let updatedWorkbook):
                    self.workbook = updatedWorkbook
                    self.drafts.removeAll()
                    self.draftOriginals.removeAll()
                    self.loadedFingerprint = try? GridWorkbookIO.fingerprint(fileURL)
                    self.persistDrafts()
                    self.draftRevision &+= 1
                    self.actionMessage = "已直接写入 \(updates.count) 个翻译单元格。"
                    afterSave?()
                case .failure(let error):
                    self.errorMessage = "写入语言表失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func translateAllMissing(
        thenExportProject: ExportProject? = nil,
        exportAction: ((ExportProject) -> Void)? = nil
    ) {
        guard let workbook, !isBusy else { return }
        let workItems = translationWorkItems()
        let missingCount = workItems.reduce(0) { $0 + $1.targetLanguages.count }
        guard !workItems.isEmpty else {
            actionMessage = "所有可翻译语言都已有内容。"
            return
        }
        let configuration = TranslationSettingsStore.load()
        guard configuration.hasAPIKey else {
            errorMessage = "请先在“翻译 API 设置”中填写本工具的 API Key。"
            showsTranslationSettings = true
            return
        }

        isTranslating = true
        errorMessage = nil
        actionMessage = "准备翻译 \(workItems.count) 条词条中的 \(missingCount) 个空白语言…"
        operationProgress = 0
        operationTask = Task { @MainActor [weak self] in
            var translatedCount = 0
            do {
                for (offset, item) in workItems.enumerated() {
                    try Task.checkCancellation()
                    guard let self, self.workbook?.fileURL == workbook.fileURL else { return }
                    self.actionMessage = "正在翻译第 \(offset + 1)/\(workItems.count) 条：\(item.entry.key)"
                    let results = try await TranslationClient.translate(
                        key: item.entry.key,
                        sourceText: item.sourceText,
                        sourceLanguage: item.sourceLanguage,
                        targetLanguages: item.targetLanguages,
                        configuration: configuration
                    )
                    for (code, value) in results {
                        self.setTranslation(value, for: item.entry, languageCode: code)
                    }
                    translatedCount += results.count
                    self.operationProgress = Double(offset + 1) / Double(workItems.count)
                }
                guard let self else { return }
                self.isTranslating = false
                self.actionMessage = "已生成 \(translatedCount) 个缺失翻译，正在直接写入语言表…"
                self.savePendingChanges {
                    if let thenExportProject { exportAction?(thenExportProject) }
                }
            } catch {
                guard let self else { return }
                self.isTranslating = false
                self.actionMessage = translatedCount > 0
                    ? "已生成 \(translatedCount) 个翻译，但尚未写入；可使用“保存全部”保留已完成内容。"
                    : nil
                let stopped = error is CancellationError || (error as? URLError)?.code == .cancelled
                if stopped {
                    self.errorMessage = nil
                    self.actionMessage = "翻译已停止，已完成内容已保留为草稿。再次翻译会继续处理缺失项。"
                } else {
                    self.errorMessage = "批量翻译失败：\(error.localizedDescription)。已完成结果已保留，可保存或继续翻译。"
                }
            }
        }
    }

    func checkTranslationConsistency() {
        guard let workbook, !isBusy else { return }
        let requests = consistencyRequests()
        guard !requests.isEmpty else {
            actionMessage = "没有可用简中或英文原文且含已有译文的词条，无法进行一致性检查。"
            return
        }
        let configuration = TranslationSettingsStore.load()
        guard configuration.hasAPIKey else {
            errorMessage = "请先在“翻译 API 设置”中填写本工具的 API Key。"
            showsTranslationSettings = true
            return
        }

        let batches = stride(from: 0, to: requests.count, by: 12).map {
            Array(requests[$0..<min($0 + 12, requests.count)])
        }
        let requestsByRow = Dictionary(uniqueKeysWithValues: requests.map { ($0.rowIndex, $0) })
        let languageNames = Dictionary(uniqueKeysWithValues: workbook.languageColumns.map { ($0.code, $0.displayName) })
        isCheckingConsistency = true
        consistencyIssues.removeAll()
        consistencyCheckedEntryCount = 0
        showsConsistencyResults = false
        errorMessage = nil
        actionMessage = "准备检查 \(requests.count) 条词条的翻译一致性…"

        operationProgress = 0
        operationTask = Task { @MainActor [weak self] in
            var allFindings: [TranslationConsistencyFinding] = []
            do {
                for (offset, batch) in batches.enumerated() {
                    try Task.checkCancellation()
                    guard let self, self.workbook?.fileURL == workbook.fileURL else { return }
                    self.actionMessage = "正在检查第 \(min(offset * 12 + 1, requests.count))–\(min((offset + 1) * 12, requests.count))/\(requests.count) 条词条…"
                    allFindings += try await TranslationClient.checkConsistency(
                        requests: batch,
                        configuration: configuration
                    )
                    self.operationProgress = Double(offset + 1) / Double(batches.count)
                }
                guard let self else { return }
                var seen = Set<String>()
                var issues: [TranslationConsistencyIssue] = []
                for finding in allFindings {
                    guard let request = requestsByRow[finding.rowIndex],
                          let languageCode = request.translations.keys.first(where: {
                              $0.caseInsensitiveCompare(finding.languageCode) == .orderedSame
                          }),
                          let currentTranslation = request.translations[languageCode],
                          let languageName = languageNames[languageCode],
                          languageCode != request.sourceLanguage
                    else { continue }
                    let identifier = "\(finding.rowIndex)-\(languageCode)"
                    guard seen.insert(identifier).inserted else { continue }
                    issues.append(TranslationConsistencyIssue(
                        rowIndex: finding.rowIndex,
                        key: request.key,
                        sourceLanguage: request.sourceLanguage,
                        sourceText: request.sourceText,
                        targetLanguage: languageCode,
                        targetLanguageName: languageName,
                        currentTranslation: currentTranslation,
                        reason: finding.reason,
                        suggestion: finding.suggestion?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
                self.isCheckingConsistency = false
                self.consistencyCheckedEntryCount = requests.count
                self.consistencyIssues = issues.sorted {
                    $0.rowIndex == $1.rowIndex
                        ? $0.targetLanguage.localizedStandardCompare($1.targetLanguage) == .orderedAscending
                        : $0.rowIndex < $1.rowIndex
                }
                self.actionMessage = issues.isEmpty
                    ? "已检查 \(requests.count) 条词条，AI 未发现明确的翻译偏差。"
                    : "已检查 \(requests.count) 条词条，发现 \(issues.count) 个需要确认的翻译。"
                self.showsConsistencyResults = true
            } catch {
                guard let self else { return }
                self.isCheckingConsistency = false
                let stopped = error is CancellationError || (error as? URLError)?.code == .cancelled
                self.errorMessage = stopped ? nil : "翻译一致性检查失败：\(error.localizedDescription)"
                if stopped { self.actionMessage = "一致性检查已停止。" }
            }
        }
    }

    private func translationWorkItems() -> [TranslationWorkItem] {
        guard let workbook else { return [] }
        return workbook.entries.compactMap { entry in
            guard let source = translationSource(for: entry) else { return nil }
            let targets = workbook.languageColumns.map(\.code).filter { languageCode in
                languageCode != source.language
                    && translation(for: entry, languageCode: languageCode)
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard !targets.isEmpty else { return nil }
            return TranslationWorkItem(
                entry: entry,
                sourceLanguage: source.language,
                sourceText: source.text,
                targetLanguages: targets
            )
        }
    }

    private func consistencyRequests() -> [TranslationConsistencyRequest] {
        guard let workbook else { return [] }
        return workbook.entries.compactMap { entry in
            guard let source = translationSource(for: entry) else { return nil }
            let translations = Dictionary(uniqueKeysWithValues: workbook.languageColumns.compactMap { language -> (String, String)? in
                guard language.code != source.language else { return nil }
                let value = translation(for: entry, languageCode: language.code)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : (language.code, value)
            })
            guard !translations.isEmpty else { return nil }
            return TranslationConsistencyRequest(
                rowIndex: entry.rowIndex,
                key: entry.key,
                sourceLanguage: source.language,
                sourceText: source.text,
                translations: translations
            )
        }
    }

    private func translationSource(for entry: LocalizationEntry) -> (language: String, text: String)? {
        let chinese = translation(for: entry, languageCode: "zh-CN").trimmingCharacters(in: .whitespacesAndNewlines)
        if !chinese.isEmpty { return ("zh-CN", chinese) }
        let english = translation(for: entry, languageCode: "en").trimmingCharacters(in: .whitespacesAndNewlines)
        if !english.isEmpty { return ("en", english) }
        return nil
    }

    private func setTranslation(_ value: String, for entry: LocalizationEntry, languageCode: String) {
        var originals = draftOriginals[entry.rowIndex] ?? entry.translations
        if conflictingDrafts.contains("\(entry.key)/\(languageCode)") { originals[languageCode] = entry.translations[languageCode] }
        draftOriginals[entry.rowIndex] = originals
        conflictingDrafts.remove("\(entry.key)/\(languageCode)")
        var values = drafts[entry.rowIndex] ?? entry.translations
        values[languageCode] = value
        if values == entry.translations {
            drafts.removeValue(forKey: entry.rowIndex)
            draftOriginals.removeValue(forKey: entry.rowIndex)
        } else {
            drafts[entry.rowIndex] = values
        }
        draftRevision &+= 1
        persistDrafts()
    }

    private func translations(for entry: LocalizationEntry) -> [String: String] {
        drafts[entry.rowIndex] ?? entry.translations
    }

    private func pendingUpdates() -> [LocalizationCellUpdate] {
        guard let workbook else { return [] }
        var updates: [LocalizationCellUpdate] = []
        for entry in workbook.entries {
            guard let draft = drafts[entry.rowIndex] else { continue }
            for language in workbook.languageColumns {
                let original = entry.translations[language.code] ?? ""
                let revised = draft[language.code] ?? ""
                guard original != revised else { continue }
                updates.append(LocalizationCellUpdate(
                    rowIndex: entry.rowIndex,
                    columnIndex: language.columnIndex,
                    languageCode: language.code,
                    value: revised
                ))
            }
        }
        return updates
    }

    private func load(project: ExportProject) {
        let projectID = project.id
        let languageFile = project.rootURL.appendingPathComponent("Config/Datas/TbLanguage.xlsx")
        isLoading = true
        errorMessage = nil
        actionMessage = nil
        workbook = nil
        selectedEntryID = nil
        drafts.removeAll()
        draftOriginals.removeAll()
        conflictingDrafts.removeAll()
        consistencyIssues = []; consistencyCheckedEntryCount = 0
        draftRevision &+= 1

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try LanguageWorkbookReader.read(fileURL: languageFile) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectedProjectID == projectID else { return }
                self.isLoading = false
                switch result {
                case .success(let workbook):
                    self.workbook = workbook
                    self.loadedFingerprint = try? GridWorkbookIO.fingerprint(languageFile)
                    self.restoreDrafts()
                    self.normalizeEntrySelection()
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func stopOperation() { operationTask?.cancel() }

    func normalizeEntrySelection() {
        if !filteredEntries.contains(where: { $0.id == selectedEntryID }) { selectedEntryID = filteredEntries.first?.id }
    }

    private func persistDrafts() {
        guard let workbook else { return }
        let saved = workbook.entries.compactMap { entry -> SavedTranslationDraft? in
            guard let values = drafts[entry.rowIndex] else { return nil }
            return SavedTranslationDraft(key: entry.key, originals: draftOriginals[entry.rowIndex] ?? entry.translations, translations: values)
        }
        do { try TranslationDraftStore.save(saved, for: workbook.fileURL) }
        catch { errorMessage = "草稿暂时无法保存到本机：\(error.localizedDescription)" }
    }

    private func restoreDrafts() {
        guard let workbook else { return }
        let saved = TranslationDraftStore.load(for: workbook.fileURL)
        for draft in saved {
            guard let entry = workbook.entries.first(where: { $0.key == draft.key }) else { continue }
            var values = entry.translations
            for (code, value) in draft.translations where draft.originals[code] != value {
                if entry.translations[code] != draft.originals[code] && entry.translations[code] != value {
                    conflictingDrafts.insert("\(entry.key)/\(code)")
                }
                values[code] = value
            }
            if values != entry.translations { drafts[entry.rowIndex] = values; draftOriginals[entry.rowIndex] = draft.originals }
        }
        if !drafts.isEmpty {
            actionMessage = "已恢复 \(pendingChangeCount) 个未保存翻译。"
            if !conflictingDrafts.isEmpty { errorMessage = "其中 \(conflictingDrafts.count) 格的原文已变化，请在“已修改”中核对并编辑后保存。" }
        }
        draftRevision &+= 1
    }
}

@MainActor
final class TranslationSettingsViewModel: ObservableObject {
    @Published var endpoint: String
    @Published var modelName: String
    @Published var apiKeyInput = ""
    @Published private(set) var keyStatus: String
    @Published private(set) var isTesting = false
    @Published private(set) var message: String?
    @Published private(set) var errorMessage: String?

    init() {
        let configuration = TranslationSettingsStore.load()
        endpoint = configuration.endpoint
        modelName = configuration.model
        keyStatus = configuration.hasAPIKey
            ? "API Key 已配置（来源：\(configuration.keySourceDescription)）"
            : "尚未配置 API Key"
    }

    func save() throws {
        try TranslationSettingsStore.save(apiKeyInput: apiKeyInput, endpoint: endpoint, model: modelName)
        apiKeyInput = ""
        let configuration = TranslationSettingsStore.load()
        keyStatus = configuration.hasAPIKey
            ? "API Key 已配置（来源：\(configuration.keySourceDescription)）"
            : "尚未配置 API Key"
        message = "设置已保存。"
        errorMessage = nil
    }

    @discardableResult
    func saveForUI() -> Bool {
        do {
            try save()
            return true
        } catch {
            message = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    func testConnection() {
        do {
            try save()
            let configuration = TranslationSettingsStore.load()
            isTesting = true
            message = nil
            Task { @MainActor [weak self] in
                do {
                    try await TranslationClient.test(configuration: configuration)
                    self?.isTesting = false
                    self?.message = "连接成功。"
                } catch {
                    self?.isTesting = false
                    self?.errorMessage = "连接失败：\(error.localizedDescription)"
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            message = nil
        }
    }
}

struct TranslationSettingsView: View {
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = TranslationSettingsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("翻译设置").font(.title2.weight(.semibold))
            Text("本工具使用独立的 API Key。请每位使用者在这里填写自己的 Key；API URL 和 Model 会保存在本机设置中，Key 会保存在本工具专用的 macOS 钥匙串项目中。工具不会读取或复用 TCST 多语言工具的 API Key。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("API URL", text: $model.endpoint)
                SecureField("本工具 API Key（留空则保留已有 Key）", text: $model.apiKeyInput)
                TextField("Model", text: $model.modelName)
            }
            .formStyle(.grouped)
            Label(model.keyStatus, systemImage: model.keyStatus.hasPrefix("API Key 已") ? "key.fill" : "key.slash")
                .foregroundStyle(model.keyStatus.hasPrefix("API Key 已") ? .green : .secondary)

            if let message = model.message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            HStack {
                Button("关闭") { dismiss() }
                Spacer()
                Button(model.isTesting ? "检测中…" : "检测连接") { model.testConnection() }
                    .disabled(model.isTesting)
                Button("保存") {
                    if model.saveForUI() {
                        onSaved()
                        dismiss()
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isTesting)
            }
        }
        .padding(24)
        .frame(width: 580)
    }

}

struct ProjectTable: Identifiable, Hashable {
    let projectID: ExportProject.ID
    let projectDisplayPath: String
    let fileURL: URL
    let relativeDataPath: String
    let byteCount: Int64
    let modifiedAt: Date?

    var id: String { fileURL.standardizedFileURL.path }
    var name: String { fileURL.lastPathComponent }
    var fileType: String { fileURL.pathExtension.uppercased() }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    var modifiedDescription: String {
        guard let modifiedAt else { return "未知" }
        return Self.modifiedDateFormatter.string(from: modifiedAt)
    }

    private static let modifiedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

struct CachedProjectTable: Codable {
    let projectID: String
    let projectDisplayPath: String
    let filePath: String
    let relativeDataPath: String

    init(_ table: ProjectTable) {
        projectID = table.projectID
        projectDisplayPath = table.projectDisplayPath
        filePath = table.fileURL.path
        relativeDataPath = table.relativeDataPath
    }

    func restoreIfValid(projectsByID: [String: ExportProject]) -> ProjectTable? {
        guard let project = projectsByID[projectID] else { return nil }
        let dataRoot = project.rootURL.appendingPathComponent("Config/Datas", isDirectory: true).standardizedFileURL
        let expectedURL = dataRoot.appendingPathComponent(relativeDataPath).standardizedFileURL
        let storedURL = URL(fileURLWithPath: filePath).standardizedFileURL
        guard expectedURL == storedURL,
              FileManager.default.fileExists(atPath: storedURL.path)
        else { return nil }
        return ProjectTableScanner.makeTable(
            fileURL: storedURL,
            project: project,
            dataRoot: dataRoot,
            relativeDataPath: relativeDataPath
        )
    }
}

struct ProjectTableCatalogCache: Codable {
    let projectIDs: [String]
    let tables: [CachedProjectTable]
}

struct TableTransferError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ProjectTableScanner {
    private static let supportedExtensions: Set<String> = ["xlsx", "xls", "xlsm", "csv"]

    static func scan(projects: [ExportProject]) throws -> [ProjectTable] {
        let manager = FileManager.default
        var tables: [ProjectTable] = []
        let propertyKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]

        for project in projects {
            let dataRoot = project.rootURL.appendingPathComponent("Config/Datas", isDirectory: true).standardizedFileURL
            guard manager.fileExists(atPath: dataRoot.path) else { continue }
            guard let enumerator = manager.enumerator(
                at: dataRoot,
                includingPropertiesForKeys: Array(propertyKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                throw TableTransferError(message: "无法读取工程表格目录：\(dataRoot.path)")
            }

            for case let itemURL as URL in enumerator {
                let values = try? itemURL.resourceValues(forKeys: propertyKeys)
                if values?.isDirectory == true { continue }
                guard values?.isRegularFile == true,
                      supportedExtensions.contains(itemURL.pathExtension.lowercased())
                else { continue }
                let standardizedURL = itemURL.standardizedFileURL
                let relativePath = String(standardizedURL.path.dropFirst(dataRoot.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                tables.append(makeTable(
                    fileURL: standardizedURL,
                    project: project,
                    dataRoot: dataRoot,
                    relativeDataPath: relativePath
                ))
            }
        }
        return sort(tables)
    }

    static func makeTable(
        fileURL: URL,
        project: ExportProject,
        dataRoot: URL,
        relativeDataPath: String? = nil
    ) -> ProjectTable {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modifiedAt = attributes?[.modificationDate] as? Date
        let relativePath = relativeDataPath ?? String(fileURL.standardizedFileURL.path.dropFirst(dataRoot.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ProjectTable(
            projectID: project.id,
            projectDisplayPath: project.displayPath,
            fileURL: fileURL.standardizedFileURL,
            relativeDataPath: relativePath,
            byteCount: byteCount,
            modifiedAt: modifiedAt
        )
    }

    static func sort(_ tables: [ProjectTable]) -> [ProjectTable] {
        tables.sorted {
            let projectComparison = $0.projectDisplayPath.localizedStandardCompare($1.projectDisplayPath)
            if projectComparison != .orderedSame { return projectComparison == .orderedAscending }
            return $0.relativeDataPath.localizedStandardCompare($1.relativeDataPath) == .orderedAscending
        }
    }
}

@MainActor
final class ProjectTableBrowserViewModel: ObservableObject {
    @Published private(set) var tables: [ProjectTable] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var noticeMessage: String?
    @Published private(set) var usingCachedCatalog = false
    @Published private(set) var isImportingContent = false
    @Published private(set) var pendingContentImportPlan: TableContentImportPlan?
    @Published var selectedProjectID: String?
    @Published var selectedTableID: ProjectTable.ID?
    @Published var contentDestinationTableID: ProjectTable.ID?
    @Published var searchText = ""

    private static let selectedTableProjectDefaultsKey = "lastTableProjectRoot"
    private static let tableCatalogCacheDefaultsKey = "projectTableCatalog"
    private var currentProjectIDs: [String] = []
    private var lastTableByProject = UserDefaults.standard.dictionary(forKey: "lastTableByProject") as? [String: String] ?? [:]

    init() {
        selectedProjectID = UserDefaults.standard.string(forKey: Self.selectedTableProjectDefaultsKey)
    }

    var filteredTables: [ProjectTable] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return tables.filter { table in
            let matchesProject = selectedProjectID == nil || table.projectID == selectedProjectID
            let matchesSearch = query.isEmpty
                || table.name.localizedCaseInsensitiveContains(query)
                || table.relativeDataPath.localizedCaseInsensitiveContains(query)
                || table.projectDisplayPath.localizedCaseInsensitiveContains(query)
            return matchesProject && matchesSearch
        }
        .sorted { left, right in
            let projectComparison = left.projectDisplayPath.localizedStandardCompare(right.projectDisplayPath)
            if projectComparison != .orderedSame { return projectComparison == .orderedAscending }
            return left.relativeDataPath.localizedStandardCompare(right.relativeDataPath) == .orderedAscending
        }
    }

    var selectedTable: ProjectTable? {
        guard let selectedTableID else { return nil }
        return tables.first { $0.id == selectedTableID }
    }

    func prepare(available projects: [ExportProject], preferredProjectID: String?) {
        let projectIDs = projects.map(\.id).sorted()
        guard projectIDs != currentProjectIDs else {
            normalizeSelections(projects: projects, preferredProjectID: preferredProjectID)
            return
        }
        currentProjectIDs = projectIDs
        normalizeSelections(projects: projects, preferredProjectID: preferredProjectID)

        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        if let data = UserDefaults.standard.data(forKey: Self.tableCatalogCacheDefaultsKey),
           let cache = try? JSONDecoder().decode(ProjectTableCatalogCache.self, from: data),
           cache.projectIDs.sorted() == projectIDs {
            let cachedTables = ProjectTableScanner.sort(cache.tables.compactMap {
                $0.restoreIfValid(projectsByID: projectsByID)
            })
            if !cachedTables.isEmpty || cache.tables.isEmpty {
                tables = cachedTables
                usingCachedCatalog = true
                errorMessage = nil
                noticeMessage = "已载入上次表格目录；新增、删除或替换表后请点击“刷新表格”。"
                normalizeSelectedTable()
                return
            }
        }
        refresh(available: projects)
    }

    func refresh(available projects: [ExportProject]) {
        guard !isLoading, !isImportingContent else { return }
        currentProjectIDs = projects.map(\.id).sorted()
        isLoading = true
        usingCachedCatalog = false
        errorMessage = nil
        noticeMessage = nil
        let snapshot = projects
        let expectedProjectIDs = currentProjectIDs

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try ProjectTableScanner.scan(projects: snapshot) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentProjectIDs == expectedProjectIDs else { return }
                self.isLoading = false
                switch result {
                case .success(let tables):
                    self.tables = tables
                    self.saveCache(projects: snapshot)
                    self.normalizeSelectedTable()
                    self.noticeMessage = "已读取 \(tables.count) 张配置表。"
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func selectProject(_ id: String?, available projects: [ExportProject]) {
        if selectedProjectID == id { normalizeSelectedTable(); return }
        let previousPath = selectedTable?.relativeDataPath
        selectedProjectID = id
        if let id {
            UserDefaults.standard.set(id, forKey: Self.selectedTableProjectDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedTableProjectDefaultsKey)
        }
        // A selected table always belongs to the previous project filter. Clear
        // it before deriving the new first visible row so detail/import targets
        // can never momentarily retain another project's file URL.
        selectedTableID = tables.first(where: { $0.projectID == id && $0.relativeDataPath == previousPath })?.id
            ?? id.flatMap { lastTableByProject[$0] }
        normalizeSelectedTable()
        normalizeContentDestination()
    }

    func selectTable(_ id: ProjectTable.ID?, available projects: [ExportProject]) {
        selectedTableID = id
        if let id, let project = selectedTable?.projectID {
            lastTableByProject[project] = id
            UserDefaults.standard.set(lastTableByProject, forKey: "lastTableByProject")
        }
        normalizeContentDestination()
    }

    func selectContentDestination(_ id: ProjectTable.ID?) {
        contentDestinationTableID = id
        normalizeContentDestination()
    }

    func openSelectedTable() {
        guard let table = selectedTable else { return }
        if !NSWorkspace.shared.open(table.fileURL) { errorMessage = "无法用默认应用打开该文件。" }
    }

    func contentImportTargets(for source: ProjectTable) -> [ProjectTable] {
        tables.filter {
            $0.id != source.id
                && $0.fileType.lowercased() == "xlsx"
        }
    }

    func beginContentImport() {
        guard let source = selectedTable else { return }
        guard source.fileType.lowercased() == "XLSX" else {
            errorMessage = "当前源表不是 .xlsx，暂不能在工具内导入 Sheet1 内容。"
            return
        }
        guard let destination = contentImportTargets(for: source).first(where: { $0.id == contentDestinationTableID }) else {
            errorMessage = "请先选择一个 .xlsx 目标表。"
            return
        }
        pendingContentImportPlan = TableContentImportPlan(source: source, destination: destination)
    }

    func cancelPendingContentImport() {
        pendingContentImportPlan = nil
    }

    func confirmPendingContentImport(available projects: [ExportProject]) {
        guard let plan = pendingContentImportPlan, !isImportingContent else { return }
        pendingContentImportPlan = nil
        isImportingContent = true
        errorMessage = nil
        noticeMessage = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try WorkbookContentImporter.importSheet1Content(from: plan.source.fileURL, into: plan.destination.fileURL)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isImportingContent = false
                switch result {
                case .success:
                    self.refreshMetadata(for: plan.destination, available: projects)
                    self.noticeMessage = "已将 \(plan.source.projectDisplayPath) · \(plan.source.relativeDataPath) 的 Sheet1 内容导入 \(plan.destination.projectDisplayPath) · \(plan.destination.relativeDataPath)。"
                    self.saveCache(projects: projects)
                case .failure(let error):
                    self.errorMessage = "导入表内容失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func revealSelectedTable() {
        guard let table = selectedTable else { return }
        NSWorkspace.shared.activateFileViewerSelecting([table.fileURL])
    }

    private func normalizeSelections(projects: [ExportProject], preferredProjectID: String?) {
        let validProjectIDs = Set(projects.map(\.id))
        if let selectedProjectID, !validProjectIDs.contains(selectedProjectID) {
            self.selectedProjectID = nil
        }
        if selectedProjectID == nil,
           let preferredProjectID,
           validProjectIDs.contains(preferredProjectID) {
            selectedProjectID = preferredProjectID
        }
        normalizeSelectedTable()
        normalizeContentDestination()
    }

    private func normalizeSelectedTable() {
        let visibleIDs = Set(filteredTables.map(\.id))
        if let selectedTableID, visibleIDs.contains(selectedTableID) { return }
        selectedTableID = filteredTables.first?.id
    }

    private func normalizeContentDestination() {
        guard let source = selectedTable else {
            contentDestinationTableID = nil
            return
        }
        let targets = contentImportTargets(for: source)
        if !targets.contains(where: { $0.id == contentDestinationTableID }) {
            // Prefer the same relative table path in another project, which is
            // the common dual-branch workflow for same-name configuration files.
            contentDestinationTableID = targets.first(where: {
                $0.relativeDataPath == source.relativeDataPath && $0.projectID != source.projectID
            })?.id ?? targets.first?.id
        }
    }

    private func refreshMetadata(for table: ProjectTable, available projects: [ExportProject]) {
        guard let project = projects.first(where: { $0.id == table.projectID }) else { return }
        let dataRoot = project.rootURL.appendingPathComponent("Config/Datas", isDirectory: true).standardizedFileURL
        let refreshed = ProjectTableScanner.makeTable(
            fileURL: table.fileURL,
            project: project,
            dataRoot: dataRoot,
            relativeDataPath: table.relativeDataPath
        )
        tables.removeAll { $0.id == refreshed.id }
        tables.append(refreshed)
        tables = ProjectTableScanner.sort(tables)
    }

    private func saveCache(projects: [ExportProject]) {
        let cache = ProjectTableCatalogCache(
            projectIDs: projects.map(\.id).sorted(),
            tables: tables.map(CachedProjectTable.init)
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: Self.tableCatalogCacheDefaultsKey)
    }

}

enum ExportState: Equatable {
    case ready
    case scanning
    case exporting
    case succeeded(Date)
    case failed(String)

    var description: String {
        switch self {
        case .ready: return "准备就绪"
        case .scanning: return "正在扫描工程…"
        case .exporting: return "正在导表…"
        case .succeeded: return "导表完成"
        case .failed(let reason): return "导表失败：\(reason)"
        }
    }

    var color: Color {
        switch self {
        case .ready, .scanning: return .secondary
        case .exporting: return .orange
        case .succeeded: return .green
        case .failed: return .red
        }
    }
}

final class ProjectScanner: @unchecked Sendable {
    /// Projects are discovered from their actual Luban export entrypoint, instead
    /// of assuming that a Unity root or repository name is the export directory.
    func scan(root: URL) throws -> [ExportProject] {
        var found: [String: ExportProject] = [:]
        let manager = FileManager.default
        let propertyKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]

        guard manager.fileExists(atPath: root.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSFilePathErrorKey: root.path,
                NSLocalizedDescriptionKey: "找不到扫描目录：\(root.path)"
            ])
        }
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(propertyKeys),
            options: options
        ) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [
                NSFilePathErrorKey: root.path,
                NSLocalizedDescriptionKey: "无法读取扫描目录：\(root.path)"
            ])
        }

        for case let itemURL as URL in enumerator {
            let values = try? itemURL.resourceValues(forKeys: propertyKeys)
            if values?.isDirectory == true {
                // Avoid generated/build caches; scan remains recursive for every
                // source folder, including project directories beyond level two.
                if ["Library", "Temp", "Logs", "obj", "node_modules", ".git", "Packages"].contains(itemURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true,
                  itemURL.lastPathComponent == "gen.sh",
                  itemURL.deletingLastPathComponent().lastPathComponent == "Config"
            else { continue }

            let projectRoot = itemURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
            let lubanConfig = projectRoot.appendingPathComponent("Config/luban.conf")
            // Guard against random helper scripts that happen to be named gen.sh.
            guard manager.fileExists(atPath: lubanConfig.path) else { continue }

            let standardizedRoot = root.standardizedFileURL
            let relative = projectRoot.path.hasPrefix(standardizedRoot.path)
                ? String(projectRoot.path.dropFirst(standardizedRoot.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : projectRoot.path
            let project = ExportProject(
                rootURL: projectRoot,
                generatorURL: itemURL.standardizedFileURL,
                displayPath: relative.isEmpty ? projectRoot.lastPathComponent : relative
            )
            found[project.id] = project
        }

        return found.values.sorted {
            $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending
        }
    }
}

@MainActor
final class ExportViewModel: ObservableObject {
    @Published var followsOutput = true
    @Published private(set) var projects: [ExportProject] = []
    @Published var selectedID: ExportProject.ID? {
        didSet {
            // Keep the last valid selection without clearing it during a temporary
            // failed scan. The full standardized path prevents same-name projects
            // in different folders from being confused with each other.
            if let selectedID {
                UserDefaults.standard.set(selectedID, forKey: Self.selectedProjectDefaultsKey)
            }
        }
    }
    @Published private(set) var scanRoot: URL
    @Published private(set) var state: ExportState = .ready
    @Published private(set) var log = ""
    @Published private(set) var hasScanned = false
    @Published private(set) var usingCachedProjectList = false

    private let scanner = ProjectScanner()
    private static let selectedProjectDefaultsKey = "lastSelectedProjectRoot"
    private static let projectListCacheDefaultsKey = "projectListCache"
    private var activeProcess: Process?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init() {
        let defaultRoot = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Project", isDirectory: true)
        if let path = UserDefaults.standard.string(forKey: "scanRoot") {
            scanRoot = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            scanRoot = defaultRoot
        }
        selectedID = UserDefaults.standard.string(forKey: Self.selectedProjectDefaultsKey)
        restoreCachedProjectList()
    }

    var selectedProject: ExportProject? {
        projects.first { $0.id == selectedID }
    }

    var isExporting: Bool {
        if case .exporting = state { return true }
        return false
    }

    func start() {
        // A valid persisted list is displayed immediately. A full recursive scan
        // is now opt-in through “重新扫描”, or occurs only when no cache exists.
        if !hasScanned { scan() }
    }

    func scan() {
        guard !isExporting else { return }
        state = .scanning
        usingCachedProjectList = false
        let root = scanRoot
        let scanner = scanner
        appendLog("\n[\(timestamp())] 开始扫描：\(root.path)\n")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let projects = try scanner.scan(root: root)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.projects = projects
                    self.hasScanned = true
                    self.saveProjectListCache(projects)
                    if !projects.contains(where: { $0.id == self.selectedID }) {
                        self.selectedID = projects.first?.id
                    }
                    self.state = .ready
                    self.appendLog("[\(self.timestamp())] 扫描完成，找到 \(projects.count) 个可导表工程。\n")
                    for project in projects { self.appendLog("  • \(project.displayPath)\n") }
                    if projects.isEmpty {
                        self.appendLog("  未找到 Config/gen.sh + Config/luban.conf；请确认扫描目录。\n")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.projects = []
                    self.selectedID = nil
                    self.hasScanned = true
                    self.state = .failed(error.localizedDescription)
                    self.appendLog("[\(self.timestamp())] 扫描失败：\(error.localizedDescription)\n")
                }
            }
        }
    }

    func chooseScanRoot() {
        guard !isExporting else { return }
        let panel = NSOpenPanel()
        panel.title = "选择包含工程的 Project 目录"
        panel.message = "工具会递归寻找各工程中的 Config/gen.sh"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = scanRoot
        panel.prompt = "使用此目录"
        if panel.runModal() == .OK, let url = panel.url {
            scanRoot = url.standardizedFileURL
            UserDefaults.standard.set(scanRoot.path, forKey: "scanRoot")
            appendLog("\n[\(timestamp())] 扫描目录已切换为：\(scanRoot.path)\n")
            scan()
        }
    }

    func exportSelectedProject() {
        guard let project = selectedProject else { return }
        export(project: project)
    }

    func export(project: ExportProject) {
        guard !isExporting else { return }
        selectedID = project.id
        log = ""
        state = .exporting
        appendLog("[\(timestamp())] 开始导表\n")
        appendLog("工程：\(project.displayPath)\n")
        appendLog("工程目录：\(project.rootURL.path)\n")
        appendLog("脚本：\(project.generatorURL.path)\n\n")
        appendLog("执行目录：\(project.workingDirectoryURL.path)\n\n")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [project.generatorURL.path]
        // Every supported Config/gen.sh uses paths such as WORKSPACE=.. and
        // CONF_ROOT=.; its contract is therefore to run from Config itself.
        process.currentDirectoryURL = project.workingDirectoryURL

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        activeProcess = process
        outputHandle = standardOutput.fileHandleForReading
        errorHandle = standardError.fileHandleForReading
        outputHandle?.readabilityHandler = { [weak self] handle in
            Self.forwardOutput(handle.availableData, to: self)
        }
        errorHandle?.readabilityHandler = { [weak self] handle in
            Self.forwardOutput(handle.availableData, to: self)
        }
        process.terminationHandler = { [weak self] completedProcess in
            let exitCode = completedProcess.terminationStatus
            DispatchQueue.main.async {
                self?.finishProcess(exitCode: exitCode, wasStopped: completedProcess.terminationReason == .uncaughtSignal)
            }
        }

        do {
            try process.run()
        } catch {
            closeOutputHandlers()
            activeProcess = nil
            state = .failed("无法启动导表脚本")
            appendLog("[\(timestamp())] 无法启动：\(error.localizedDescription)\n")
        }
    }

    func stopExport() {
        guard let activeProcess, activeProcess.isRunning else { return }
        appendLog("\n[\(timestamp())] 正在停止导表进程…\n")
        activeProcess.terminate()
    }

    func clearLog() {
        guard !isExporting else { return }
        log = ""
    }

    nonisolated private static func forwardOutput(_ data: Data, to model: ExportViewModel?) {
        guard !data.isEmpty else { return }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        Task { @MainActor in model?.appendLog(text) }
    }

    private func finishProcess(exitCode: Int32, wasStopped: Bool) {
        // Drain tail bytes emitted immediately before process termination.
        if let outputHandle { appendLog(String(decoding: outputHandle.availableData, as: UTF8.self)) }
        if let errorHandle { appendLog(String(decoding: errorHandle.availableData, as: UTF8.self)) }
        closeOutputHandlers()
        activeProcess = nil
        if exitCode == 0 && !wasStopped {
            state = .succeeded(Date())
            appendLog("\n[\(timestamp())] ✓ 导表完成。\n")
        } else if wasStopped {
            state = .failed("已由用户停止")
            appendLog("\n[\(timestamp())] 导表已停止。\n")
        } else {
            state = .failed("退出代码 \(exitCode)")
            appendLog("\n[\(timestamp())] ✗ 导表失败（退出代码 \(exitCode)）。上方日志包含脚本输出和具体错误。\n")
            NSSound.beep()
        }
    }

    private func closeOutputHandlers() {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        outputHandle = nil
        errorHandle = nil
    }

    private func restoreCachedProjectList() {
        guard let data = UserDefaults.standard.data(forKey: Self.projectListCacheDefaultsKey),
              let cache = try? JSONDecoder().decode(ProjectListCache.self, from: data),
              cache.scanRootPath == scanRoot.standardizedFileURL.path
        else { return }

        let validProjects = cache.projects.compactMap { $0.restoreIfValid() }.sorted {
            $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending
        }
        guard !validProjects.isEmpty else { return }

        projects = validProjects
        hasScanned = true
        usingCachedProjectList = true
        if !validProjects.contains(where: { $0.id == selectedID }) {
            selectedID = validProjects.first?.id
        }
        appendLog("[\(timestamp())] 已载入上次扫描的 \(validProjects.count) 个工程；新增或移动工程后请点击“重新扫描”。\n")
    }

    private func saveProjectListCache(_ projects: [ExportProject]) {
        let cache = ProjectListCache(
            scanRootPath: scanRoot.standardizedFileURL.path,
            projects: projects.map(CachedExportProject.init)
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: Self.projectListCacheDefaultsKey)
    }

    private func appendLog(_ text: String) { log += text }
    private func timestamp() -> String { dateFormatter.string(from: Date()) }
}

struct LanguageBrowserView: View {
    let projects: [ExportProject]
    let preferredProjectID: String?
    let exportAction: (ExportProject) -> Void
    @ObservedObject var model: LanguageBrowserViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                entryList
                Divider()
                entryDetail
            }
        }
        .task { model.ensureProject(available: projects, preferredProjectID: preferredProjectID) }
        .onChange(of: projects) { _, newProjects in
            model.ensureProject(available: newProjects, preferredProjectID: preferredProjectID)
        }
        .onChange(of: preferredProjectID) { _, newProjectID in
            model.ensureProject(available: projects, preferredProjectID: newProjectID)
        }
        .onChange(of: model.entryFilter) { _, _ in model.normalizeEntrySelection() }
        .onChange(of: model.searchText) { _, _ in model.normalizeEntrySelection() }
        .sheet(isPresented: $model.showsConsistencyResults) {
            TranslationConsistencyResultsView(
                checkedEntryCount: model.consistencyCheckedEntryCount,
                issues: model.consistencyIssues
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("多语言").font(.title2.weight(.semibold))
                    Text("翻译、手工修改会直接写入工程自己的 TbLanguage.xlsx")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.showsTranslationSettings = true } label: {
                    Label("翻译设置", systemImage: "gearshape")
                }
                Button { model.reload(available: projects) } label: {
                    Label("重新读取", systemImage: "arrow.clockwise")
                }
                .disabled(projects.isEmpty || model.isBusy)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    Button {
                        model.translateAllMissing()
                    } label: {
                        Label(
                            model.isTranslating ? "正在翻译…" : "翻译全部缺失（\(model.missingTranslationCellCount)）",
                            systemImage: "character.bubble"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.missingTranslationCellCount == 0)

                    Button {
                        guard let project = selectedLanguageProject else { return }
                        model.translateAllMissing(thenExportProject: project, exportAction: exportAction)
                    } label: {
                        Label("翻译缺失并导表", systemImage: "play.fill")
                    }
                    .disabled(model.isBusy || model.missingTranslationCellCount == 0 || selectedLanguageProject == nil)

                    Divider().frame(height: 24)

                    Button("保存全部（\(model.pendingChangeCount)）") {
                        model.savePendingChanges()
                    }
                    .disabled(model.isBusy || model.pendingChangeCount == 0)

                    Button("保存并导表") {
                        guard let project = selectedLanguageProject else { return }
                        model.savePendingChanges { exportAction(project) }
                    }
                    .disabled(model.isBusy || selectedLanguageProject == nil)

                    Divider().frame(height: 24)

                    Button {
                        model.checkTranslationConsistency()
                    } label: {
                        Label(
                            model.isCheckingConsistency ? "正在检查…" : "检查翻译一致性",
                            systemImage: "checkmark.text.page"
                        )
                    }
                    .disabled(model.isBusy || model.consistencyEligibleEntryCount == 0)

                    if model.consistencyCheckedEntryCount > 0 {
                        Button("查看结果（\(model.consistencyIssues.count)）") {
                            model.showsConsistencyResults = true
                        }
                        .disabled(model.isBusy)
                    }
                }
                .padding(.vertical, 2)
            }

            if let actionMessage = model.actionMessage {
                Label(actionMessage, systemImage: model.isCheckingConsistency || model.isTranslating || model.isSaving ? "clock" : "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(model.isCheckingConsistency || model.isTranslating || model.isSaving ? Color.secondary : Color.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isTranslating || model.isCheckingConsistency {
                HStack {
                    ProgressView(value: model.operationProgress).frame(maxWidth: .infinity)
                    Text("\(Int(model.operationProgress * 100))%").font(.caption.monospacedDigit())
                    Button("停止") { model.stopOperation() }.controlSize(.small)
                }
            }
            if let errorMessage = model.errorMessage, !model.isLoading {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }

    private var selectedLanguageProject: ExportProject? {
        guard let projectID = model.selectedProjectID else { return nil }
        return projects.first { $0.id == projectID }
    }

    private var languageProjectTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(projects) { project in
                    languageProjectTab(project)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(minWidth: 220, idealWidth: 440, maxWidth: .infinity)
        .disabled(projects.isEmpty || model.isBusy)
    }

    @ViewBuilder
    private func languageProjectTab(_ project: ExportProject) -> some View {
        if project.id == model.selectedProjectID {
            Button { model.select(project: project) } label: {
                Text(project.name).lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(project.displayPath)
        } else {
            Button { model.select(project: project) } label: {
                Text(project.name).lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(project.displayPath)
        }
    }

    private var entryList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("词条").font(.headline)
                Spacer()
                Text("\(model.filteredEntries.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)

            Picker("筛选词条", selection: $model.entryFilter) {
                ForEach(TranslationEntryFilter.allCases, id: \.self) { filter in Text(filter.rawValue).tag(filter) }
            }.pickerStyle(.segmented).padding(.horizontal, 12).padding(.bottom, 8)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索 key 或译文", text: $model.searchText).textFieldStyle(.plain)
            }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 12).padding(.bottom, 8)
            List(selection: $model.selectedEntryID) {
                ForEach(model.filteredEntries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.key).font(.body.weight(.medium))
                        Text(previewText(for: entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                    .tag(entry.id)
                }
            }
            .overlay {
                if model.isLoading {
                    ProgressView("正在读取语言表…")
                } else if let errorMessage = model.errorMessage, model.workbook == nil {
                    ContentUnavailableView(
                        "无法读取语言表",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                    .padding()
                } else if model.workbook != nil && model.filteredEntries.isEmpty {
                    ContentUnavailableView("未找到匹配词条", systemImage: "magnifyingglass")
                } else if projects.isEmpty {
                    ContentUnavailableView("还没有工程", systemImage: "folder.badge.questionmark")
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 340, maxWidth: 400, maxHeight: .infinity)
    }

    private var entryDetail: some View {
        Group {
            if let workbook = model.workbook, let entry = model.selectedEntry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.key).font(.title2.weight(.semibold))
                            Text("Excel 第 \(entry.rowIndex) 行 · \(workbook.sheetName)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(workbook.fileURL.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Text("可直接编辑任意语言；修改后使用上方“保存全部”或“保存并导表”。批量翻译和一致性检查也在上方执行。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Divider()
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(workbook.languageColumns) { language in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(language.displayName).font(.headline)
                                    TextEditor(text: model.translationBinding(for: entry, languageCode: language.code))
                                        .font(.body)
                                        .frame(minHeight: 58)
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                                        }
                                        .disabled(model.isBusy)
                                }
                                if language.id != workbook.languageColumns.last?.id { Divider() }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !model.isLoading && model.errorMessage == nil {
                ContentUnavailableView(
                    "选择一个词条",
                    systemImage: "text.book.closed",
                    description: Text("这里会显示 key 及所有语言内容。")
                )
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewText(for entry: LocalizationEntry) -> String {
        let localized = model.translation(for: entry, languageCode: "zh-CN").isEmpty
            ? model.translation(for: entry, languageCode: "en")
            : model.translation(for: entry, languageCode: "zh-CN")
        return localized.isEmpty ? "（空翻译）" : localized
    }

}

struct TranslationConsistencyResultsView: View {
    let checkedEntryCount: Int
    let issues: [TranslationConsistencyIssue]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("翻译一致性检查").font(.title2.weight(.semibold))
                    Text(issues.isEmpty
                        ? "已检查 \(checkedEntryCount) 条词条，AI 未发现明确的翻译偏差。"
                        : "已检查 \(checkedEntryCount) 条词条，以下 \(issues.count) 项建议人工确认。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }

            if issues.isEmpty {
                ContentUnavailableView(
                    "未发现明确问题",
                    systemImage: "checkmark.seal",
                    description: Text("此结果是 AI 对语义、占位符和富文本标签的检查，不会自动修改语言表。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(issues) { issue in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(issue.key).font(.headline)
                            Spacer()
                            Text("第 \(issue.rowIndex) 行 · \(issue.targetLanguageName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        labeledText("原文（\(issue.sourceLanguage)）", issue.sourceText)
                        labeledText("当前译文（\(issue.targetLanguage)）", issue.currentTranslation)
                        labeledText("AI 判断", issue.reason)
                        if let suggestion = issue.suggestion, !suggestion.isEmpty {
                            labeledText("建议译文", suggestion)
                        }
                    }
                    .padding(.vertical, 7)
                    .textSelection(.enabled)
                }
                .listStyle(.inset)
            }
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 520)
    }

    private func labeledText(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.subheadline)
        }
    }
}

struct ExportScreenView: View {
    @ObservedObject var model: ExportViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                projectList
                Divider()
                logPanel
            }
            Divider()
            footer
        }
        .frame(minWidth: 920, minHeight: 620)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "tablecells.badge.ellipsis")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("表格工具").font(.title2.weight(.semibold))
                Text(model.usingCachedProjectList
                    ? "已载入上次工程列表；新增或移动工程后请重新扫描"
                    : "无需打开 Unity，直接运行工程自己的导表脚本")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.chooseScanRoot() } label: {
                Label("选择 Project 目录", systemImage: "folder")
            }
            .disabled(model.isExporting)
            Button { model.scan() } label: {
                Label("重新扫描", systemImage: "arrow.clockwise")
            }
            .disabled(model.isExporting)
        }
        .padding(20)
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("可导表工程").font(.headline)
                Spacer()
                Text("\(model.projects.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)
            List(selection: $model.selectedID) {
                ForEach(model.projects) { project in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name).font(.body.weight(.medium))
                        Text(project.displayPath).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .padding(.vertical, 5)
                    .tag(project.id)
                }
            }
            .overlay {
                if model.hasScanned && model.projects.isEmpty {
                    ContentUnavailableView(
                        "未找到可导表工程",
                        systemImage: "folder.badge.questionmark",
                        description: Text("扫描范围内需存在 Config/gen.sh 与 Config/luban.conf")
                    )
                    .padding()
                }
            }
        }
        .frame(minWidth: 270, idealWidth: 310, maxWidth: 360)
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("导表日志").font(.headline)
                Spacer()
                Button("清空") { model.clearLog() }
                    .disabled(model.isExporting || model.log.isEmpty)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)
            ScrollView {
                Text(model.log.isEmpty ? "选择工程后点击“导表”。\n\n脚本输出、警告与错误会完整显示在这里。" : model.log)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(model.log.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding([.horizontal, .bottom], 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Circle().fill(model.state.color).frame(width: 9, height: 9)
            Text(model.state.description).foregroundStyle(model.state.color)
            Spacer()
            if model.isExporting {
                Button(role: .destructive) { model.stopExport() } label: {
                    Label("停止", systemImage: "stop.fill")
                }
            } else {
                Button { model.exportSelectedProject() } label: {
                    Label("导表", systemImage: "play.fill").frame(minWidth: 92)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedProject == nil)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
    }
}

struct ContentView: View {
    var body: some View {
        WorkspaceRootView()
    }
}

#if !SMOKE_TEST
@main
struct OneClickTableExportApp: App {
    @NSApplicationDelegateAdaptor(WorkspaceApplicationDelegate.self) var appDelegate
    var body: some Scene {
        Window("表格工具", id: "workspace") { ContentView() }
            .windowResizability(.contentMinSize)
            .defaultSize(width: 1400, height: 860)
    }
}
#else
@main
struct LanguageReaderSmokeTest {
    @MainActor static func main() {
        let paths = Array(CommandLine.arguments.dropFirst())
        if paths.first == "--close-smoke" {
            let app = NSApplication.shared
            let delegate = WorkspaceApplicationDelegate()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.contentView = WorkspaceCloseBehavior.View()
            let button = window.standardWindowButton(.closeButton)!
            precondition(button.target === app && button.action == #selector(NSApplication.terminate(_:)))
            precondition(delegate.applicationShouldTerminateAfterLastWindowClosed(app))
            WorkspaceApplicationDelegate.hasUnsavedWork = { false }
            precondition(delegate.applicationShouldTerminate(app) == .terminateNow)
            WorkspaceApplicationDelegate.hasUnsavedWork = { true }
            for (response, expected) in [(NSApplication.ModalResponse.alertFirstButtonReturn, NSApplication.TerminateReply.terminateCancel),
                                         (.alertSecondButtonReturn, .terminateNow)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { app.stopModal(withCode: response) }
                precondition(delegate.applicationShouldTerminate(app) == expected)
            }
            precondition(window.contentView != nil)
            WorkspaceApplicationDelegate.hasUnsavedWork = nil
            print("关闭按钮退出路由、最后窗口退出策略、无修改退出、取消/确认退出提示通过")
            return
        }
        if paths.first == "--updater-smoke" {
            do { try UpdaterSmokeTests.run() }
            catch { fputs("更新回归失败：\(error.localizedDescription)\n", stderr); Foundation.exit(1) }
            precondition(AppUpdater.isNewer("v1.6.0", than: "1.5.0"))
            precondition(AppUpdater.isNewer("v1.10.0", than: "1.9.0"))
            precondition(!AppUpdater.isNewer("v1.6.0", than: "1.6.0"))
            precondition(!AppUpdater.isNewer("v1.5.0", than: "1.6.0"))
            precondition(!AppUpdater.isNewer("v1.7.0-beta", than: "1.6.0"))
            print("更新版本比较：升级、相同版本、降级、多位版本号与预发布过滤通过")
            return
        }
        if paths.first == "--comparison-smoke", paths.count == 2 {
            do { try WorkspaceSmokeTests.compareAndTabs(paths[1]) }
            catch { fputs("对比回归失败：\(error.localizedDescription)\n", stderr); Foundation.exit(1) }
            return
        }
        if paths.first == "--git-history-smoke", paths.count == 2 {
            do { try WorkspaceSmokeTests.gitHistory(paths[1]) }
            catch { fputs("Git 历史回归失败：\(error.localizedDescription)\n", stderr); Foundation.exit(1) }
            return
        }
        if paths.first == "--workspace-smoke" {
            do { try WorkspaceSmokeTests.run(Array(paths.dropFirst())) }
            catch { fputs("工作区回归失败：\(error.localizedDescription)\n", stderr); Foundation.exit(1) }
            return
        }
        guard !paths.isEmpty else {
            fputs("请提供至少一个 TbLanguage.xlsx 路径。\n", stderr)
            Foundation.exit(64)
        }
        if paths.first == "--catalog" {
            let projects = paths.dropFirst().map { rootPath in
                let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
                return ExportProject(
                    rootURL: rootURL,
                    generatorURL: rootURL.appendingPathComponent("Config/gen.sh"),
                    displayPath: rootURL.lastPathComponent
                )
            }
            do {
                let tables = try ProjectTableScanner.scan(projects: projects)
                print("配置表：\(tables.count)")
                for table in tables where table.name == "TbLanguage.xlsx" {
                    print("  \(table.projectDisplayPath) · \(table.relativeDataPath)")
                }
            } catch {
                fputs("配置表扫描失败：\(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
            return
        }
        if paths.first == "--write-smoke", paths.count == 2 {
            let manager = FileManager.default
            let sourceURL = URL(fileURLWithPath: paths[1])
            let temporaryRoot = manager.temporaryDirectory
                .appendingPathComponent("OneClickTableExport-write-smoke-\(UUID().uuidString)", isDirectory: true)
            defer { try? manager.removeItem(at: temporaryRoot) }
            do {
                try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
                let temporaryWorkbook = temporaryRoot.appendingPathComponent("TbLanguage.xlsx")
                let originalData = try Data(contentsOf: sourceURL)
                try manager.copyItem(at: sourceURL, to: temporaryWorkbook)
                let workbook = try LanguageWorkbookReader.read(fileURL: temporaryWorkbook)
                guard let entry = workbook.entries.first,
                      let japanese = workbook.languageColumns.first(where: { $0.code == "ja" }) else {
                    throw LanguageWorkbookReaderError(message: "测试语言表缺少词条或日文列。")
                }
                let requested = "Smoke <&> \u{0001}{0}"
                let expected = "Smoke <&> {0}"
                let updatedWorkbook = try LanguageWorkbookWriter.write(
                    fileURL: temporaryWorkbook,
                    updates: [.init(rowIndex: entry.rowIndex, columnIndex: japanese.columnIndex, languageCode: japanese.code, value: requested)]
                )
                guard updatedWorkbook.entries.first(where: { $0.rowIndex == entry.rowIndex })?.translations[japanese.code] == expected,
                      try Data(contentsOf: sourceURL) == originalData
                else {
                    throw LanguageWorkbookReaderError(message: "语言表直写验证失败。")
                }
                print("语言表直写：通过（特殊字符保留、无效 XML 控制字符已剔除、源表未改）")
            } catch {
                fputs("语言表直写验证失败：\(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
            return
        }
        if paths.first == "--batch-write-smoke", paths.count == 2 {
            let manager = FileManager.default
            let sourceURL = URL(fileURLWithPath: paths[1])
            let temporaryRoot = manager.temporaryDirectory
                .appendingPathComponent("OneClickTableExport-batch-write-smoke-\(UUID().uuidString)", isDirectory: true)
            defer { try? manager.removeItem(at: temporaryRoot) }
            do {
                try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
                let temporaryWorkbook = temporaryRoot.appendingPathComponent("TbLanguage.xlsx")
                let originalData = try Data(contentsOf: sourceURL)
                try manager.copyItem(at: sourceURL, to: temporaryWorkbook)
                let workbook = try LanguageWorkbookReader.read(fileURL: temporaryWorkbook)
                guard let japanese = workbook.languageColumns.first(where: { $0.code == "ja" }) else {
                    throw LanguageWorkbookReaderError(message: "测试语言表缺少日文列。")
                }
                let sourceEntries = Array(workbook.entries.prefix(120))
                guard !sourceEntries.isEmpty else {
                    throw LanguageWorkbookReaderError(message: "测试语言表没有可写入的词条。")
                }
                let updates = sourceEntries.map { entry in
                    LocalizationCellUpdate(
                        rowIndex: entry.rowIndex,
                        columnIndex: japanese.columnIndex,
                        languageCode: japanese.code,
                        value: "Batch \(entry.rowIndex) <&> \u{0001}{0}"
                    )
                }
                let updatedWorkbook = try LanguageWorkbookWriter.write(fileURL: temporaryWorkbook, updates: updates)
                let allValidated = sourceEntries.allSatisfy { entry in
                    updatedWorkbook.entries.first(where: { $0.rowIndex == entry.rowIndex })?.translations[japanese.code]
                        == "Batch \(entry.rowIndex) <&> {0}"
                }
                guard allValidated, try Data(contentsOf: sourceURL) == originalData else {
                    throw LanguageWorkbookReaderError(message: "批量语言表直写验证失败。")
                }
                print("语言表批量直写：通过（120 个单元格、无效 XML 控制字符已剔除、源表未改）")
            } catch {
                fputs("语言表批量直写验证失败：\(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
            return
        }
        if paths.first == "--wide-batch-write-smoke", paths.count == 2 {
            let manager = FileManager.default
            let sourceURL = URL(fileURLWithPath: paths[1])
            let temporaryRoot = manager.temporaryDirectory
                .appendingPathComponent("OneClickTableExport-wide-batch-write-smoke-\(UUID().uuidString)", isDirectory: true)
            defer { try? manager.removeItem(at: temporaryRoot) }
            do {
                try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
                let temporaryWorkbook = temporaryRoot.appendingPathComponent("TbLanguage.xlsx")
                let originalData = try Data(contentsOf: sourceURL)
                try manager.copyItem(at: sourceURL, to: temporaryWorkbook)
                let workbook = try LanguageWorkbookReader.read(fileURL: temporaryWorkbook)
                let sourceEntries = Array(workbook.entries.prefix(80))
                guard !sourceEntries.isEmpty, !workbook.languageColumns.isEmpty else {
                    throw LanguageWorkbookReaderError(message: "测试语言表缺少可写入的词条或语言列。")
                }

                let requestedValue: (LocalizationEntry, LocalizationLanguageColumn) -> String = { entry, language in
                    "Wide \(entry.rowIndex)/\(language.code) <&> \\\"' {0} {1} <color=#12ABEF>glass</color>\\nLine\\tTab\u{0001} 😀"
                }
                let updates = sourceEntries.flatMap { entry in
                    workbook.languageColumns.map { language in
                        LocalizationCellUpdate(
                            rowIndex: entry.rowIndex,
                            columnIndex: language.columnIndex,
                            languageCode: language.code,
                            value: requestedValue(entry, language)
                        )
                    }
                }
                let updatedWorkbook = try LanguageWorkbookWriter.write(fileURL: temporaryWorkbook, updates: updates)
                let allValidated = updates.allSatisfy { update in
                    updatedWorkbook.entries.first(where: { $0.rowIndex == update.rowIndex })?
                        .translations[update.languageCode]
                        == update.value.replacingOccurrences(of: "\u{0001}", with: "")
                }
                guard allValidated, try Data(contentsOf: sourceURL) == originalData else {
                    throw LanguageWorkbookReaderError(message: "跨语言批量语言表直写验证失败。")
                }
                print("语言表跨语言批量直写：通过（\(updates.count) 个单元格、特殊字符和空单元格均已校验、源表未改）")
            } catch {
                fputs("语言表跨语言批量直写验证失败：\(error.localizedDescription)\\n", stderr)
                Foundation.exit(1)
            }
            return
        }
        if paths.first == "--missing-translation-write-smoke", paths.count == 2 || paths.count == 3 {
            let manager = FileManager.default
            let sourceURL = URL(fileURLWithPath: paths[1])
            let temporaryRoot = manager.temporaryDirectory
                .appendingPathComponent("OneClickTableExport-missing-translation-write-smoke-\(UUID().uuidString)", isDirectory: true)
            defer { try? manager.removeItem(at: temporaryRoot) }
            do {
                try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
                let temporaryWorkbook = temporaryRoot.appendingPathComponent("TbLanguage.xlsx")
                let originalData = try Data(contentsOf: sourceURL)
                try manager.copyItem(at: sourceURL, to: temporaryWorkbook)
                let workbook = try LanguageWorkbookReader.read(fileURL: temporaryWorkbook)

                // Mirror “翻译全部缺失”: prefer Chinese source text, then
                // English, and only write its currently blank target cells.
                let updates = workbook.entries.flatMap { entry -> [LocalizationCellUpdate] in
                    let chinese = entry.translations["zh-CN"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let english = entry.translations["en"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let sourceLanguage = !chinese.isEmpty ? "zh-CN" : (!english.isEmpty ? "en" : nil)
                    guard let sourceLanguage else { return [] }
                    return workbook.languageColumns.compactMap { language in
                        guard language.code != sourceLanguage,
                              (entry.translations[language.code] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else { return nil }
                        return LocalizationCellUpdate(
                            rowIndex: entry.rowIndex,
                            columnIndex: language.columnIndex,
                            languageCode: language.code,
                            value: "Missing \(entry.rowIndex)/\(language.code) <&> \\\"' {0} <color=#12ABEF>glass</color>\\nLine\\tTab\u{0001} 😀"
                        )
                    }
                }
                guard !updates.isEmpty else {
                    print("缺失翻译写入模拟：跳过（当前语言表没有可翻译的空白单元格，源表未改）")
                    return
                }

                let requestedLimit = paths.count == 3 ? Int(paths[2]) : nil
                guard requestedLimit.map({ $0 > 0 }) ?? true else {
                    throw LanguageWorkbookReaderError(message: "测试单元格数量必须是正整数。")
                }
                let selectedUpdates = requestedLimit.map { Array(updates.prefix($0)) } ?? updates
                guard !selectedUpdates.isEmpty else {
                    throw LanguageWorkbookReaderError(message: "测试单元格数量超出当前语言表的可翻译范围。")
                }

                let lastUpdate = selectedUpdates[selectedUpdates.count - 1]
                print("缺失翻译写入模拟：测试至第 \(selectedUpdates.count) 项（Sheet1 第 \(lastUpdate.rowIndex) 行、\(lastUpdate.languageCode)）")
                let updatedWorkbook = try LanguageWorkbookWriter.write(fileURL: temporaryWorkbook, updates: selectedUpdates)
                let allValidated = selectedUpdates.allSatisfy { update in
                    updatedWorkbook.entries.first(where: { $0.rowIndex == update.rowIndex })?
                        .translations[update.languageCode]
                        == update.value.replacingOccurrences(of: "\u{0001}", with: "")
                }
                guard allValidated, try Data(contentsOf: sourceURL) == originalData else {
                    throw LanguageWorkbookReaderError(message: "缺失翻译写入模拟验证失败。")
                }
                print("缺失翻译写入模拟：通过（\(selectedUpdates.count)/\(updates.count) 个当前空白目标单元格、源表未改）")
            } catch {
                fputs("缺失翻译写入模拟失败：\(error.localizedDescription)\\n", stderr)
                Foundation.exit(1)
            }
            return
        }
        if paths.first == "--content-import-smoke", paths.count == 3 {
            let manager = FileManager.default
            let sourceURL = URL(fileURLWithPath: paths[1])
            let targetURL = URL(fileURLWithPath: paths[2])
            let temporaryRoot = manager.temporaryDirectory
                .appendingPathComponent("OneClickTableExport-content-smoke-\(UUID().uuidString)", isDirectory: true)
            defer { try? manager.removeItem(at: temporaryRoot) }
            do {
                try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
                let temporarySource = temporaryRoot.appendingPathComponent("source.xlsx")
                let temporaryTarget = temporaryRoot.appendingPathComponent("target.xlsx")
                let originalSourceData = try Data(contentsOf: sourceURL)
                try manager.copyItem(at: sourceURL, to: temporarySource)
                try manager.copyItem(at: targetURL, to: temporaryTarget)
                let sourceWorkbook = try LanguageWorkbookReader.read(fileURL: temporarySource)
                try WorkbookContentImporter.importSheet1Content(from: temporarySource, into: temporaryTarget)
                let targetWorkbook = try LanguageWorkbookReader.read(fileURL: temporaryTarget)
                guard try Data(contentsOf: temporarySource) == originalSourceData,
                      sourceWorkbook.entries.count == targetWorkbook.entries.count,
                      sourceWorkbook.entries.first?.key == targetWorkbook.entries.first?.key
                else {
                    throw LanguageWorkbookReaderError(message: "Sheet1 内容导入校验失败。")
                }
                print("Sheet1 内容导入：通过（源表未改，目标内容已替换）")
            } catch {
                fputs("Sheet1 内容导入验证失败：\(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
            return
        }
        for path in paths {
            do {
                let workbook = try LanguageWorkbookReader.read(fileURL: URL(fileURLWithPath: path))
                let languageNames = workbook.languageColumns.map(\.displayName).joined(separator: ", ")
                let exampleKey = workbook.entries.first?.key ?? "（无词条）"
                print("\(path)\n  词条：\(workbook.entries.count)\n  语言：\(workbook.languageColumns.count) [\(languageNames)]\n  首个 key：\(exampleKey)")
            } catch {
                fputs("\(path)：\(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
        }
    }
}
#endif
