import AppKit
import Combine
import SwiftUI

enum WorkspaceMenuAction: Equatable {
    case chooseScanRoot
    case rescanProjects
    case translationSettings
    case updateNotes
    case checkForUpdates
}

@MainActor
final class WorkspaceMenuRouter: ObservableObject {
    @Published var pendingAction: WorkspaceMenuAction?
}

@MainActor
final class TableWorkspaceModel: ObservableObject {
    @Published var openIDs: [String] = []
    @Published var activeID: String?
    private var previewID: String?
    @Published var split = false
    @Published var favorites = Set(UserDefaults.standard.stringArray(forKey: "favoriteConfigTables") ?? [])
    @Published var onlyFavorites = false
    @Published var peerSearch = ""
    @Published var pickerProjectID: String?
    @Published var showsPeerPicker = false
    private var documents: [String: GridEditorModel] = [:]
    private var metadata: [String: ProjectTable] = [:]
    private var observers: [String: AnyCancellable] = [:]
    private var monitor: AnyCancellable?
    init() {
        monitor = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self else { return }
            for id in self.openIDs { self.documents[id]?.refreshIfChanged() }
        }
    }
    var hasPendingChanges: Bool { documents.values.contains { $0.hasPendingChanges } }
    var isBusy: Bool { documents.values.contains(where: \.isBusy) }
    func editor(_ id: String) -> GridEditorModel? { documents[id] }
    func table(_ id: String) -> ProjectTable? { metadata[id] }
    func preview(_ table: ProjectTable) {
        guard !split else { open(table); return }
        guard !openIDs.contains(table.id) else { activeID = table.id; return }
        if let id = previewID, documents[id]?.hasPendingChanges == false {
            remove(id)
        }
        open(table)
        previewID = table.id
    }
    func open(_ table: ProjectTable) {
        metadata[table.id] = table
        if documents[table.id] == nil {
            let editor = GridEditorModel(); documents[table.id] = editor
            observers[table.id] = editor.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            editor.load(table.fileURL)
        }
        if !openIDs.contains(table.id) { openIDs.append(table.id) }
        activeID = table.id
    }
    func openFile(_ file: URL, label: String) {
        open(ProjectTable(projectID: "", projectDisplayPath: label, fileURL: file,
                          relativeDataPath: file.lastPathComponent, byteCount: 0, modifiedAt: nil))
    }
    func close(_ id: String) {
        guard let editor = documents[id], !editor.isBusy else { return }
        if editor.hasPendingChanges {
            let alert = NSAlert()
            alert.messageText = "关闭前保存 \(metadata[id]?.name ?? "表格")？"
            let detail = editor.insertions.isEmpty
                ? "此表有 \(editor.changes.count) 个未保存修改。"
                : "此表有 \(editor.changes.count) 个单元格修改和 \(editor.insertions.count) 次行列调整未保存。"
            alert.informativeText = detail
            alert.addButton(withTitle: "保存并关闭"); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "不保存")
            let result = alert.runModal()
            if result == .alertFirstButtonReturn { editor.save { self.remove(id) }; return }
            if result != .alertThirdButtonReturn { return }
        }
        remove(id)
    }
    private func remove(_ id: String) {
        let index = openIDs.firstIndex(of: id) ?? 0
        openIDs.removeAll { $0 == id }
        if activeID == id { activeID = openIDs.isEmpty ? nil : openIDs[min(index, openIDs.count - 1)] }
        observers[id] = nil; documents[id] = nil; metadata[id] = nil
    }
    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        UserDefaults.standard.set(Array(favorites), forKey: "favoriteConfigTables")
    }
    func saveProject(_ project: ExportProject, completion: @escaping () -> Void) {
        let editors = documents.values.filter { $0.snapshot?.fileURL.path.hasPrefix(project.rootURL.path + "/") == true && $0.hasPendingChanges }
        func next(_ offset: Int) {
            guard offset < editors.count else { completion(); return }
            editors[offset].save { next(offset + 1) }
        }
        next(0)
    }
}

struct TableWorkspaceView: View {
    let projects: [ExportProject]
    let projectID: String?
    @ObservedObject var catalog: ProjectTableBrowserViewModel
    @ObservedObject var workspace: TableWorkspaceModel
    let exportAction: (ExportProject) -> Void
    var visibleTables: [ProjectTable] {
        catalog.filteredTables.filter { !workspace.onlyFavorites || workspace.favorites.contains($0.id) }
            .sorted { $0.relativeDataPath.localizedStandardCompare($1.relativeDataPath) == .orderedAscending }
    }
    var body: some View {
        GeometryReader { geometry in
            HSplitView {
                sidebar.frame(minWidth: 210, idealWidth: 240, maxWidth: 310, maxHeight: .infinity)
                VStack(spacing: 0) {
                    HStack {
                        Label("表格工作区", systemImage: "rectangle.split.3x1").font(.subheadline.weight(.medium))
                        Spacer()
                        Text("外部修改自动刷新").font(.caption).foregroundStyle(.secondary)
                        Button { workspace.showsPeerPicker = true } label: { Label("添加表格", systemImage: "plus") }
                        Toggle("多表并排", isOn: $workspace.split).toggleStyle(.switch).controlSize(.small)
                    }.padding(12)
                    Divider()
                    tabBar
                    Divider()
                    if workspace.openIDs.isEmpty {
                        ContentUnavailableView("选择配置表", systemImage: "tablecells", description: Text("单击在工具内编辑，双击用默认表格应用打开。"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        GeometryReader { area in
                            if workspace.split {
                                ScrollView(.horizontal) {
                                    HStack(spacing: 1) {
                                        ForEach(workspace.openIDs, id: \.self) { id in
                                            pane(id).frame(width: max(390, (area.size.width - CGFloat(workspace.openIDs.count - 1)) / CGFloat(max(1, workspace.openIDs.count))), height: max(1, area.size.height - 14))
                                        }
                                    }.frame(height: max(1, area.size.height - 14)).background(Color(nsColor: .separatorColor))
                                }.frame(width: area.size.width, height: area.size.height).clipped()
                            } else if let id = workspace.activeID {
                                pane(id).frame(width: area.size.width, height: area.size.height)
                            }
                        }
                    }
                }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task { prepare() }
        .onChange(of: projectID) { _, _ in prepare() }
        .onChange(of: catalog.tables.count) { _, _ in openInitial() }
        .popover(isPresented: $workspace.showsPeerPicker) {
            VStack(alignment: .leading, spacing: 12) {
                Text("添加到工作区").font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        Button("全部") { workspace.pickerProjectID = nil }
                        ForEach(projects) { project in Button(project.name) { workspace.pickerProjectID = project.id } }
                    }.controlSize(.small)
                }
                Text(workspace.pickerProjectID.flatMap { id in projects.first { $0.id == id }?.name } ?? "全部项目").font(.caption).foregroundStyle(.secondary)
                TextField("搜索表名或路径", text: $workspace.peerSearch).textFieldStyle(.roundedBorder)
                List {
                    ForEach(catalog.tables.filter {
                        (workspace.pickerProjectID == nil || $0.projectID == workspace.pickerProjectID)
                        && (workspace.peerSearch.isEmpty || $0.relativeDataPath.localizedCaseInsensitiveContains(workspace.peerSearch))
                    }) { table in
                        Button {
                            workspace.open(table); workspace.showsPeerPicker = false
                        } label: {
                            VStack(alignment: .leading) {
                                Text(table.name); Text("\(table.projectDisplayPath) · \(table.relativeDataPath)").font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                Button("从文件选择…") {
                    let panel = NSOpenPanel(); panel.allowedFileTypes = ["xlsx"]; panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK { for url in panel.urls { workspace.openFile(url, label: url.deletingLastPathComponent().lastPathComponent) }; workspace.showsPeerPicker = false }
                }
            }.padding(16).frame(width: 450, height: 480)
        }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("配置表").font(.headline)
                Text("\(visibleTables.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { workspace.onlyFavorites.toggle() } label: { Image(systemName: workspace.onlyFavorites ? "star.fill" : "star") }.help("只看收藏")
                Button { catalog.refresh(available: projects) } label: { Image(systemName: "arrow.clockwise") }.disabled(catalog.isLoading)
            }.padding(12)
            TextField("搜索表名或路径", text: $catalog.searchText).textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.bottom, 8)
            List(selection: Binding(get: { catalog.selectedTableID }, set: { id in
                catalog.selectTable(id, available: projects)
                if let table = catalog.selectedTable { workspace.preview(table) }
            })) {
                ForEach(visibleTables) { table in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(table.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            if table.relativeDataPath != table.name { Text(table.relativeDataPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 2)
                        if workspace.favorites.contains(table.id) { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.orange) }
                    }.padding(.vertical, 5).contentShape(Rectangle()).tag(table.id)
                        .simultaneousGesture(TapGesture(count: 1).onEnded { workspace.preview(table) })
                        .simultaneousGesture(TapGesture(count: 2).onEnded { NSWorkspace.shared.open(table.fileURL) })
                        .contextMenu {
                            Button(workspace.favorites.contains(table.id) ? "取消收藏" : "收藏") { workspace.toggleFavorite(table.id) }
                            Button("在工具内打开") { workspace.open(table) }
                            Button("外部打开") { NSWorkspace.shared.open(table.fileURL) }
                            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([table.fileURL]) }
                        }
                }
            }.listStyle(.plain).scrollContentBackground(.hidden).background(Color(nsColor: .textBackgroundColor)).frame(maxHeight: .infinity)
            Text("单击编辑 · 双击外部打开 · 右键收藏").font(.caption2).foregroundStyle(.secondary).padding(10)
        }.background(Color(nsColor: .textBackgroundColor))
    }
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(workspace.openIDs, id: \.self) { id in
                    HStack(spacing: 6) {
                        Button { workspace.activeID = id } label: {
                            Text("\(workspace.table(id)?.projectDisplayPath ?? "") · \(workspace.table(id)?.name ?? "")\(workspace.editor(id)?.hasPendingChanges == true ? " ●" : "")")
                                .font(.caption).lineLimit(1)
                        }.buttonStyle(.plain)
                        Button { workspace.close(id) } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain).help("关闭此表")
                    }.padding(8).background(workspace.activeID == id ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }
            }.padding(8)
        }.frame(height: workspace.openIDs.isEmpty ? 0 : 45)
    }
    @ViewBuilder private func pane(_ id: String) -> some View {
        if let editor = workspace.editor(id), let table = workspace.table(id) {
            GridEditorPane(model: editor, title: table.projectDisplayPath,
                exportAction: projects.first(where: { $0.id == table.projectID }).map { project in { exportAction(project) } },
                showsSelectionBorder: workspace.split && workspace.activeID == id)
                .id(id).frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { [weak workspace] in
                    editor.onActivate = { [weak workspace] in workspace?.activeID = id }
                }
        }
    }
    private func prepare() {
        catalog.prepare(available: projects, preferredProjectID: projectID)
        catalog.selectProject(projectID, available: projects)
        openInitial()
    }
    private func openInitial() {
        if workspace.openIDs.isEmpty, let table = catalog.selectedTable { workspace.preview(table) }
    }
}

// Route the main window's close button through the normal quit confirmation
// before closing anything, so cancelling keeps the workspace visible.
// SwiftUI may replace the window delegate and the standard close action after
// the view is attached, so both routes are repaired whenever the window comes
// back to the front and once more on the next run-loop turns.
final class WorkspaceCloseDelegateProxy: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    private let requestTermination: () -> Void
    private var isRequestingTermination = false

    init(original: NSWindowDelegate?, requestTermination: @escaping () -> Void) {
        self.original = original
        self.requestTermination = requestTermination
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isRequestingTermination else { return true }
        isRequestingTermination = true
        requestTermination()
        DispatchQueue.main.async { [weak self] in self?.isRequestingTermination = false }
        // NSApplication.terminate(_:) decides whether the application may
        // quit. The window must remain open if that decision is cancelled.
        return false
    }

    override func responds(to selector: Selector) -> Bool {
        if selector == #selector(NSWindowDelegate.windowShouldClose(_:)) { return true }
        return original?.responds(to: selector) == true || super.responds(to: selector)
    }

    override func forwardingTarget(for selector: Selector) -> Any? {
        if let original, original.responds(to: selector) { return original }
        return super.forwardingTarget(for: selector)
    }
}

struct WorkspaceCloseBehavior: NSViewRepresentable {
    final class View: NSView {
        private let onTerminate: () -> Void
        private var closeObserver: NSObjectProtocol?
        private var delegateProxy: WorkspaceCloseDelegateProxy?

        init(onTerminate: @escaping () -> Void = { NSApplication.shared.terminate(nil) }) {
            self.onTerminate = onTerminate
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = nil
            guard let window else { return }
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.installCloseRoute()
            }
            installCloseRoute()
            // The standard buttons can be created after the representable is
            // attached. Retry after SwiftUI/AppKit finish that window pass.
            DispatchQueue.main.async { [weak self] in self?.installCloseRoute() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.installCloseRoute()
            }
        }

        func installCloseRoute() {
            guard let window else { return }
            if let button = window.standardWindowButton(.closeButton) {
                button.target = NSApplication.shared
                button.action = #selector(NSApplication.terminate(_:))
            }
            if let current = window.delegate as? WorkspaceCloseDelegateProxy {
                delegateProxy = current
            } else {
                let proxy = WorkspaceCloseDelegateProxy(
                    original: window.delegate,
                    requestTermination: onTerminate
                )
                delegateProxy = proxy
                window.delegate = proxy
            }
        }

        // Used by the smoke test to exercise the default NSWindow close path
        // without terminating the test process.
        @discardableResult
        func simulateWindowShouldCloseForTesting() -> Bool {
            installCloseRoute()
            return delegateProxy?.windowShouldClose(window!) ?? true
        }
    }

    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ nsView: View, context: Context) { nsView.installCloseRoute() }
}

final class WorkspaceApplicationDelegate: NSObject, NSApplicationDelegate {
    static var hasUnsavedWork: (() -> Bool)?
    // The updater has already validated the new bundle and handed replacement
    // to the detached installer. At that point updater.busy must not be
    // interpreted as unsaved user work, otherwise the installer waits for an
    // application that is waiting for its own termination confirmation.
    static var isTerminatingForUpdate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.isTerminatingForUpdate = false
        UpdateInstaller.acknowledgeLaunch()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.isTerminatingForUpdate { return .terminateNow }
        guard Self.hasUnsavedWork?() == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "还有未保存的表格修改或正在执行的任务"
        alert.informativeText = "选择继续编辑可回到工作区保存。翻译草稿已保存在本机，可在下次打开时恢复。"
        alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct WorkspaceRootView: View {
    @EnvironmentObject private var menuRouter: WorkspaceMenuRouter
    @StateObject private var updater = AppUpdater()
    @StateObject private var exporter = ExportViewModel()
    @StateObject private var language = LanguageBrowserViewModel()
    @StateObject private var catalog = ProjectTableBrowserViewModel()
    @StateObject private var workspace = TableWorkspaceModel()
    @StateObject private var comparison = FolderComparisonModel()
    @AppStorage("workspaceSection") private var section = "tables"
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Label("表格工具", systemImage: "square.grid.3x3.fill").font(.headline).foregroundStyle(.tint)
                Picker("工作区", selection: $section) {
                    Text("配置表").tag("tables"); Text("表格对比").tag("compare"); Text("多语言").tag("language"); Text("导表日志").tag("export")
                }.pickerStyle(.segmented).frame(width: 390)
                Spacer()
                Menu {
                    Button("选择 Project 目录…") { exporter.chooseScanRoot() }
                    Button("重新扫描工程") { exporter.scan() }
                    Button("翻译 API 设置…") { language.showsTranslationSettings = true }
                    Divider()
                    Text("版本 \(AppUpdater.currentVersion)")
                    Button("版本与更新说明…") { updater.showsPanel = true; Task { await updater.check() } }
                    Button("检查更新…") { Task { await updater.check() } }
                } label: { Image(systemName: "gearshape") }.help("工具设置").disabled(exporter.isExporting || language.isBusy)
                Button { exportCurrent() } label: {
                    Label(exporter.isExporting ? "正在导表…" : "导表", systemImage: "play.fill")
                }.buttonStyle(.borderedProminent).disabled(exporter.selectedProject == nil || exporter.isExporting || language.isBusy || workspace.isBusy)
                    .keyboardShortcut(.return, modifiers: .command)
            }.padding(.horizontal, 18).padding(.vertical, 12)
            HStack(spacing: 8) {
                Text("项目").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(exporter.projects) { project in
                            Button { exporter.selectedID = project.id } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(project.id == exporter.selectedID ? Color.accentColor : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                                    Text(project.name).font(.system(size: 12, weight: project.id == exporter.selectedID ? .semibold : .regular))
                                }.padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(project.id == exporter.selectedID ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).help(project.rootURL.path)
                        }
                    }
                }
                .disabled(exporter.isExporting || language.isBusy)
                if let project = exporter.selectedProject {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([project.rootURL]) } label: { Image(systemName: "folder") }.help("打开当前项目")
                }
            }.padding(.horizontal, 18).padding(.bottom, 10)
            Divider()
            Group {
                switch section {
                case "tables":
                    TableWorkspaceView(projects: exporter.projects, projectID: exporter.selectedID, catalog: catalog, workspace: workspace, exportAction: runExport)
                case "compare":
                    FolderComparisonView(model: comparison, project: exporter.selectedProject, openFiles: { old, new in
                        if let old { workspace.openFile(old, label: "历史版本") }
                        if let new { workspace.openFile(new, label: "当前版本") }
                        section = "tables"
                    })
                case "language":
                    LanguageBrowserView(projects: exporter.projects, preferredProjectID: exporter.selectedID, exportAction: runExport, model: language)
                default: ExportLogWorkspace(model: exporter)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                Circle().fill(exporter.state.color).frame(width: 6, height: 6)
                Text(exporter.state.description).font(.caption)
                if exporter.isExporting { Button("查看日志") { section = "export" }.buttonStyle(.link) }
                Spacer()
                Text(exporter.selectedProject?.displayPath ?? "请选择工程").font(.caption).foregroundStyle(.secondary)
                Text("·  ⌘↩ 导表").font(.caption).foregroundStyle(.tertiary)
            }.padding(.horizontal, 18).padding(.vertical, 8)
        }
        .frame(minWidth: 1120, minHeight: 700)
        .background(WorkspaceCloseBehavior())
        .sheet(isPresented: $updater.showsPanel) { AppUpdatePanel(updater: updater).interactiveDismissDisabled(updater.busy) }
        .sheet(isPresented: $language.showsTranslationSettings) {
            TranslationSettingsView(onSaved: { })
        }
        .onChange(of: menuRouter.pendingAction) { _, action in
            handleMenuAction(action)
        }
        .task {
            exporter.start()
            updater.mayRestart = { !workspace.hasPendingChanges && !workspace.isBusy && !exporter.isExporting && !language.isBusy && language.pendingChangeCount == 0 && !comparison.isRunning }
            updater.start()
            WorkspaceApplicationDelegate.hasUnsavedWork = { workspace.hasPendingChanges || workspace.isBusy || exporter.isExporting || language.isBusy || language.pendingChangeCount > 0 || comparison.isRunning || updater.busy }
        }
    }
    private func handleMenuAction(_ action: WorkspaceMenuAction?) {
        guard let action else { return }
        menuRouter.pendingAction = nil
        switch action {
        case .chooseScanRoot:
            exporter.chooseScanRoot()
        case .rescanProjects:
            exporter.scan()
        case .translationSettings:
            language.showsTranslationSettings = true
        case .updateNotes:
            updater.showsPanel = true
            Task { await updater.check() }
        case .checkForUpdates:
            Task { await updater.check() }
        }
    }
    private func exportCurrent() {
        if let project = exporter.selectedProject { runExport(project) }
    }
    private func runExport(_ project: ExportProject) {
        guard !exporter.isExporting, !workspace.isBusy, !language.isBusy else { return }
        let finish = { workspace.saveProject(project) { exporter.export(project: project); section = "export" } }
        if language.selectedProjectID == project.id && language.pendingChangeCount > 0 { language.savePendingChanges(afterSave: finish) }
        else { finish() }
    }
}

struct ExportLogWorkspace: View {
    @ObservedObject var model: ExportViewModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("导表日志").font(.headline)
                Spacer()
                Toggle("跟随最新输出", isOn: $model.followsOutput).toggleStyle(.checkbox)
                Button("复制日志") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.log, forType: .string) }.disabled(model.log.isEmpty)
                Button("清空") { model.clearLog() }.disabled(model.isExporting || model.log.isEmpty)
                if model.isExporting { Button("停止导表", role: .destructive) { model.stopExport() } }
            }.padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.log.isEmpty ? "点击右上角“导表”开始。脚本输出和报错会显示在这里。" : model.log)
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
                    Color.clear.frame(height: 1).id("tail")
                }.onChange(of: model.log) { _, _ in if model.followsOutput { proxy.scrollTo("tail", anchor: .bottom) } }
            }.background(Color(nsColor: .textBackgroundColor))
        }
    }
}
