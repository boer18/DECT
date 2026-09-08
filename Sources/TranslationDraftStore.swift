import CryptoKit
import Foundation

enum TranslationEntryFilter: String, CaseIterable {
    case all = "全部", missing = "缺失", edited = "已修改"
}

struct SavedTranslationDraft: Codable {
    let key: String
    let originals: [String: String]
    let translations: [String: String]
}

enum TranslationDraftStore {
    private static func url(for workbook: URL) -> URL {
        let identifier = SHA256.hash(data: Data(workbook.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OneClickTableExport/translation-drafts/\(identifier).json")
    }
    static func load(for workbook: URL) -> [SavedTranslationDraft] {
        guard let data = try? Data(contentsOf: url(for: workbook)), let entries = try? JSONDecoder().decode([SavedTranslationDraft].self, from: data) else { return [] }
        return entries
    }
    static func save(_ drafts: [SavedTranslationDraft], for workbook: URL) throws {
        let target = url(for: workbook)
        if drafts.isEmpty {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            return
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(drafts).write(to: target, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}
