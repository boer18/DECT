import SwiftUI

/// Display preferences are keyed by the stable project path, independently of
/// discovery caches. Temporarily missing projects keep their names and order.
struct ProjectPresentationPreferences: Codable {
    var orderedIDs: [String] = []
    var remarks: [String: String] = [:]
    private static let defaultsKey = "projectPresentationPreferences"

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    func apply(to projects: [ExportProject]) -> [ExportProject] {
        var ranks: [String: Int] = [:]
        for (index, id) in orderedIDs.enumerated() where ranks[id] == nil { ranks[id] = index }
        return projects.map { project in
            var result = project
            let remark = remarks[project.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            result.remarkName = remark.flatMap { $0.isEmpty ? nil : $0 }
            return result
        }.sorted { left, right in
            let a = ranks[left.id] ?? Int.max, b = ranks[right.id] ?? Int.max
            if a != b { return a < b }
            return left.displayPath.localizedStandardCompare(right.displayPath) == .orderedAscending
        }
    }

    mutating func update(from projects: [ExportProject]) {
        // Preserve hidden slots when a project is absent from the scan root.
        let visible = Set(projects.map(\.id))
        var replacement = projects.map(\.id).makeIterator()
        var seen = Set<String>()
        orderedIDs = orderedIDs.filter { seen.insert($0).inserted }.map { id in
            visible.contains(id) ? (replacement.next() ?? id) : id
        }
        orderedIDs.append(contentsOf: replacement)
        for project in projects {
            let remark = project.remarkName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            remarks[project.id] = remark.isEmpty ? nil : remark
        }
    }
}

@MainActor
final class ProjectManagementDraft: ObservableObject {
    @Published var projects: [ExportProject]
    init(projects: [ExportProject]) { self.projects = projects }

    func move(_ id: String, by offset: Int) {
        guard let index = projects.firstIndex(where: { $0.id == id }),
              projects.indices.contains(index + offset) else { return }
        projects.swapAt(index, index + offset)
    }
}

struct ProjectManagementPanel: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var exporter: ExportViewModel
    @StateObject private var draft: ProjectManagementDraft

    init(exporter: ExportViewModel) {
        self.exporter = exporter
        _draft = StateObject(wrappedValue: ProjectManagementDraft(projects: exporter.projects))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("管理项目").font(.title2.bold())
            Text("用上下箭头调整显示顺序；备注留空时显示原工程名。设置保存在这台 Mac 上。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($draft.projects) { $project in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.originalName).font(.body.weight(.medium))
                                Text(project.rootURL.path).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle).help(project.rootURL.path)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            TextField("项目备注名", text: Binding(
                                get: { project.remarkName ?? "" },
                                set: { project.remarkName = $0 }
                            )).textFieldStyle(.roundedBorder).frame(width: 210)
                            Button { draft.move(project.id, by: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(draft.projects.first?.id == project.id).help("向前移动")
                            Button { draft.move(project.id, by: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(draft.projects.last?.id == project.id).help("向后移动")
                        }.padding(.vertical, 12)
                        Divider()
                    }
                }
            }.frame(height: 340)
            HStack {
                Button("恢复默认顺序") {
                    draft.projects.sort { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending }
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    exporter.updateProjectPresentation(draft.projects)
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 720)
    }

}
