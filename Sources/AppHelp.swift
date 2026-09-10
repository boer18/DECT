import SwiftUI

struct AppHelpBlock: Identifiable {
    let id = UUID()
    let title: String
    let text: String?
    let bullets: [String]

    init(_ title: String, text: String? = nil, bullets: [String] = []) {
        self.title = title
        self.text = text
        self.bullets = bullets
    }
}

struct AppHelpTopic: Identifiable {
    let id: String
    let title: String
    let icon: String
    let summary: String
    let blocks: [AppHelpBlock]
}

enum AppHelpContent {
    static let topics: [AppHelpTopic] = [
        AppHelpTopic(
            id: "start",
            title: "开始使用",
            icon: "sparkles",
            summary: "表格工具把多个 Unity/Luban 工程的配置表、导表和版本检查集中在一个 macOS 工作区中。",
            blocks: [
                AppHelpBlock("第一次使用", text: "打开工具后，点击顶部“选择 Project 目录”，选择包含一个或多个工程的目录。工具会递归寻找 gen.sh，并检查它所在目录是否有 luban.conf。表格目录由 luban.conf 里的 dataDir 决定。"),
                AppHelpBlock("项目结构示例", text: "传统工程：\n<项目目录>/Config/gen.sh\n<项目目录>/Config/luban.conf\n<项目目录>/Config/Datas/\n\n嵌套工程：\n<仓库>/trunk/LubanConfig/gen.sh\n<仓库>/trunk/LubanConfig/luban.conf\n<仓库>/trunk/LubanConfig/Datas/"),
                AppHelpBlock("项目 Tab", bullets: [
                    "顶部项目 Tab 用来切换当前工程，配置表、多语言和导表日志会跟随当前项目。",
                    "项目列表会保存到本机，下次启动优先读取缓存，不必每次完整扫描；新增或移动工程后再点击“重新扫描工程”。",
                    "同名工程会使用完整路径区分，不会因为名称相同而互相覆盖。"
                ])
            ]
        ),
        AppHelpTopic(
            id: "tables",
            title: "浏览配置表",
            icon: "tablecells",
            summary: "在配置表工作区中快速定位表格，单击预览，双击用系统默认表格应用打开。",
            blocks: [
                AppHelpBlock("查找和收藏", bullets: [
                    "左侧搜索框支持按表名或相对路径查找。",
                    "点击星标收藏常用表，再次点击可以只看收藏。",
                    "列表使用稳定的正常配色和路径顺序，不会因为打开次数改变颜色或排序。"
                ]),
                AppHelpBlock("打开方式", bullets: [
                    "多表并排关闭时，单击表格只在当前预览区切换，不会不断增加标签。",
                    "双击列表中的表格会使用系统默认应用打开原文件。",
                    "“添加表格”可以把其他项目中的同名表或外部表格加入工作区。"
                ]),
                AppHelpBlock("自动刷新", text: "工具会定时检查已打开文件的外部变化。没有未保存编辑时会自动刷新；有未保存编辑时会保留当前内容并提示冲突，不会静默覆盖。")
            ]
        ),
        AppHelpTopic(
            id: "edit",
            title: "编辑、复制与填充",
            icon: "pencil.and.scribble",
            summary: "工具内编辑面向 XLSX 配置表，支持公式、行列选择、复制粘贴、填充柄和撤销重做。",
            blocks: [
                AppHelpBlock("编辑单元格", bullets: [
                    "单击单元格后直接输入，会替换原内容；连续输入文字、数字或中文时会继续追加。",
                    "双击单元格进入带光标的编辑状态，按 Enter 提交。",
                    "公式单元格未选中时显示计算结果，选中后顶部内容栏和当前单元格显示原始公式，可以直接修改。工具本身不负责重新计算公式。"
                ]),
                AppHelpBlock("复制内容", bullets: [
                    "拖选矩形区域后按 ⌘C，再在目标单元格按 ⌘V。复制的是单元格内容和公式，不是整个表文件。",
                    "点击行号可以选择整行，点击列字母可以选择整列，然后复制到其他项目的表格。",
                    "跨项目复制时，先通过“添加表格”打开目标项目的同名表，再粘贴并保存目标表。"
                ]),
                AppHelpBlock("右下角填充柄", bullets: [
                    "拖动选区右下角的小方块可以向下或向右填充；拖动过程中会显示完整待填充区域。",
                    "普通文本默认复制；纯数字、日期，以及文字开头、中间或结尾带编号的内容会自动按序列延续。",
                    "松开后，填充柄旁的“填充选项”可以展开为“复制单元格”或“以序列方式填充”。不展开时使用自动判断。",
                    "多个起始单元格会按各自所在列独立判断，公式会按相对引用规则调整。"
                ]),
                AppHelpBlock("视图调整", bullets: [
                    "工具栏中的缩放按钮、触控板捏合或按住 ⌘/Control 滚轮可以缩放表格；“重置大小”恢复 100%。",
                    "“自适应”可以适配列宽、行高和换行。长文本的测量有上限，不会让一两个异常单元格撑坏整张表。",
                    "冻结行列只影响工具内视图，不会修改 Excel 文件本身的冻结设置。"
                ])
            ]
        ),
        AppHelpTopic(
            id: "multi",
            title: "多表并排",
            icon: "rectangle.split.3x1",
            summary: "适合同时查看两个项目或多个分支中的同名配置表，并把需要的内容互相挪动。",
            blocks: [
                AppHelpBlock("开启和关闭", bullets: [
                    "多表并排默认关闭。关闭时表格以单页预览方式显示，顶部标签用于切换已经打开的表。",
                    "打开“多表并排”后，右侧可以持续添加更多表格，已选中的表格面板会显示蓝色边框。",
                    "每个面板有独立的横向和纵向滚动，不会拖动整个工作区工具栏。"
                ]),
                AppHelpBlock("同名表迁移配置", text: "在当前项目打开源表，点击“添加表格”选择另一个项目的同名表，开启多表并排后框选源表内容并复制，再点击目标表粘贴。最后使用目标表自己的“保存”，不会覆盖整个表文件。"),
                AppHelpBlock("关闭表格", text: "点击表格标签上的叉只关闭该表格标签。若有未保存修改，工具会先询问保存并关闭、取消或不保存。")
            ]
        ),
        AppHelpTopic(
            id: "language",
            title: "多语言工具",
            icon: "character.book.closed",
            summary: "读取当前项目主 TbLanguage.xlsx，批量补齐缺失翻译、保存并导表，还可以做翻译一致性检查。",
            blocks: [
                AppHelpBlock("翻译前设置", text: "第一次使用翻译功能时，工具会提示打开“翻译 API 设置”。每位使用者都需要填写本工具自己的 API Key；Key、API URL 和 Model 会保存在本工具的本机设置中。工具不会读取或复用 TCST 的 Key。"),
                AppHelpBlock("顶部操作", bullets: [
                    "“翻译全部缺失”只处理当前项目中空白的语言单元格。",
                    "“保存全部”把当前草稿直接写回 TbLanguage.xlsx，不生成备份。",
                    "“翻译并导表”完成翻译后自动保存并运行当前项目的导表脚本。",
                    "“AI 一致性检查”检查已有译文与原文含义、占位符和标签是否一致，不会自动修改表格。"
                ]),
                AppHelpBlock("草稿和冲突", text: "翻译结果会先保存在本机草稿中，任务中断或应用重启后可以继续。保存前如果原始语言表被其他程序修改，工具会拦截写入并保留草稿，避免覆盖外部修改。")
            ]
        ),
        AppHelpTopic(
            id: "comparison",
            title: "表格对比",
            icon: "arrow.left.arrow.right",
            summary: "上线前比较历史版本与当前版本的全部配置表数据，完整展示表格并标记增删改。",
            blocks: [
                AppHelpBlock("文件夹对比", bullets: [
                    "选择历史版本目录和当前版本目录，工具会递归匹配所有 XLSX、XLSM、CSV、TSV 等表格。",
                    "选中文件后可以切换工作表查看完整内容，不只显示差异单元格。",
                    "红色表示删除，绿色表示新增，紫色表示修改；变化的行号和列号也会同步着色。"
                ]),
                AppHelpBlock("Git 历史对比", text: "切换到 Git 历史对比后，工具跟随顶部当前项目读取本地 .git、分支和配置表提交。可以按提交或时间选择历史版本，历史快照和当前工作区（包括未提交表格修改）进行比较。工具不会 checkout、pull、reset 或修改项目。"),
                AppHelpBlock("检查和导出", bullets: [
                    "点击“已检查”记录当前差异文件的复核进度，顶部会显示已检查数量。",
                    "支持对比表格搜索、缩放、重置大小和导出完整差异 CSV 报告。",
                    "对比工作区是只读的，不会写入历史目录或当前版本源表。"
                ])
            ]
        ),
        AppHelpTopic(
            id: "export",
            title: "一键导表",
            icon: "play.circle",
            summary: "直接调用工程自己的导表脚本，不需要先打开 Unity；脚本输出和错误会实时显示。",
            blocks: [
                AppHelpBlock("开始导表", text: "选择顶部项目 Tab 后，点击右上角“导表”。如果当前项目在工具内有未保存的表格或多语言修改，工具会先保存对应内容，再运行配置目录中的 gen.sh。"),
                AppHelpBlock("日志内容", bullets: [
                    "工程目录、配置目录、数据目录、脚本路径和执行目录。",
                    "检测到的 Luban Runtime；对于 net7.0 等旧版 Luban，必要时会显示本次导表启用的 .NET 兼容模式。",
                    "脚本标准输出和错误输出，包括 dotnet、Luban、权限和文件不存在等具体错误。",
                    "成功、停止或失败状态，以及失败时的退出代码。"
                ]),
                AppHelpBlock("常见失败", text: "tapcoloroasis 等旧版 Luban 工程会自动尝试使用兼容的较新 .NET Runtime；如果本机没有任何可用 Runtime，仍会把原始错误显示在日志中。工具不会自动修改工程生成文件，也不会启动 Unity。")
            ]
        ),
        AppHelpTopic(
            id: "settings",
            title: "设置与更新",
            icon: "gearshape",
            summary: "系统顶部菜单栏和窗口内设置入口都可以管理路径、翻译 API、版本说明和更新。",
            blocks: [
                AppHelpBlock("系统顶部菜单栏", bullets: [
                    "“表格工具”菜单包含选择 Project 目录、重新扫描工程、翻译 API 设置、版本与更新说明和检查更新。",
                    "系统“帮助”菜单中可以打开本帮助窗口，也可以使用 ⌘⇧?。",
                    "系统“设置表格工具…”入口提供翻译 API 设置，适合不打开多语言页签时修改 Key。"
                ]),
                AppHelpBlock("自动更新", text: "工具会在启动时和运行期间定期检查 GitHub 正式 Release。发现新版本后会显示版本号、Build 和更新说明，并在确认没有未保存内容或运行中任务时提供“安装并重启”。"),
                AppHelpBlock("当前版本", text: "当前版本号和 Build 可以在“版本与更新说明”窗口中查看。更新包来自项目的 GitHub Releases，安装前会校验 ZIP、应用标识、版本和签名。")
            ]
        ),
        AppHelpTopic(
            id: "troubleshooting",
            title: "常见问题",
            icon: "questionmark.circle",
            summary: "遇到工程识别、输入、刷新或更新问题时，可以先从这里排查。",
            blocks: [
                AppHelpBlock("找不到项目", text: "确认选择的是包含工程的 Project 根目录，而不是某个工程内部的 Config 或 LubanConfig 目录。工程必须有 gen.sh、同目录 luban.conf，并且 dataDir 指向实际存在的表格目录。"),
                AppHelpBlock("找不到语言表", text: "多语言工具优先寻找当前工程数据根目录下的 TbLanguage.xlsx。如果工程把主语言表放在更深的子目录，也会递归寻找；框架和故事语言表不会被误当作主表。"),
                AppHelpBlock("表格显示不完整", bullets: [
                    "使用表格工具栏的缩放或“重置大小”。",
                    "通过“自适应”调整列宽和行高；极长文本可以在内容栏展开查看全文。",
                    "如果是对比表，确认当前选择的是对应工作表，而不是只看左侧文件差异列表。"
                ]),
                AppHelpBlock("更新后没有重启", text: "先退出当前运行的旧版本，再从“应用程序”或程序坞重新打开表格工具。安装过程不会强制结束正在运行的实例，以避免丢失未保存内容。")
            ]
        )
    ]
}

@MainActor
final class AppHelpViewModel: ObservableObject {
    @Published var selection = "start"
    @Published var query = ""
}

struct AppHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = AppHelpViewModel()

    private var visibleTopics: [AppHelpTopic] {
        let normalized = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return AppHelpContent.topics }
        return AppHelpContent.topics.filter { topic in
            topic.title.localizedCaseInsensitiveContains(normalized)
                || topic.summary.localizedCaseInsensitiveContains(normalized)
                || topic.blocks.contains { block in
                    block.title.localizedCaseInsensitiveContains(normalized)
                        || (block.text?.localizedCaseInsensitiveContains(normalized) == true)
                        || block.bullets.contains { $0.localizedCaseInsensitiveContains(normalized) }
                }
        }
    }

    private var selectedTopic: AppHelpTopic? {
        visibleTopics.first { $0.id == model.selection } ?? visibleTopics.first
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("表格工具帮助") {
                    ForEach(visibleTopics) { topic in
                        Label(topic.title, systemImage: topic.icon)
                            .tag(topic.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $model.query, placement: .sidebar, prompt: "搜索帮助")
            .navigationTitle("帮助")
        } detail: {
            if let topic = selectedTopic {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(topic.title, systemImage: topic.icon)
                                .font(.largeTitle.weight(.semibold))
                                .symbolRenderingMode(.hierarchical)
                            Text(topic.summary)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        ForEach(topic.blocks) { block in
                            VStack(alignment: .leading, spacing: 9) {
                                Text(block.title)
                                    .font(.title3.weight(.semibold))
                                if let text = block.text {
                                    Text(text)
                                        .font(.body)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                ForEach(Array(block.bullets.enumerated()), id: \.offset) { _, bullet in
                                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                                        Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                                        Text(bullet)
                                            .font(.body)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding(34)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button("关闭") { dismiss() }
                    }
                }
            } else {
                ContentUnavailableView("没有匹配的帮助内容", systemImage: "magnifyingglass", description: Text("尝试搜索其他关键词。"))
            }
        }
        .onChange(of: model.query) { _, _ in
            if selectedTopic == nil { model.selection = AppHelpContent.topics.first?.id ?? "start" }
        }
        .frame(minWidth: 900, minHeight: 620)
    }
}
