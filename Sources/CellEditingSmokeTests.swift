#if SMOKE_TEST
import AppKit

@MainActor
enum CellEditingSmokeTests {
    static func run() throws {
        let sheet = GridSheet(name: "Sheet1", archivePath: "xl/worksheets/sheet1.xml")
        let sentence = "正在编辑的单元格会临时扩展，以便完整查看和修改这段较长的配置文本。"
        var cells = Dictionary(uniqueKeysWithValues: (0..<40).flatMap { row in
            (0..<8).map { column in
                (GridAddress(row: row, column: column), GridCell(text: "R\(row + 1)C\(column + 1)", formula: false))
            }
        })
        cells[GridAddress(row: 2, column: 1)] = GridCell(text: sentence, formula: false)
        let snapshot = GridSnapshot(fileURL: URL(fileURLWithPath: "/tmp/cell-editing-smoke.xlsx"),
            fingerprint: Data(), sheets: [sheet], sheet: sheet, cells: cells, rowCount: 40, columnCount: 8)
        let model = GridEditorModel(); model.snapshot = snapshot
        let grid = FrozenGridView(model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = grid; window.makeKeyAndOrderFront(nil)
        grid.frame = NSRect(x: 0, y: 0, width: 760, height: 420)
        grid.layoutSubtreeIfNeeded()
        defer { window.makeFirstResponder(nil); window.orderOut(nil) }
        func settle() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03)) }
        func begin(row: Int, column: Int) throws -> (CellGridTable, NSTextView, NSClipView) {
            model.select(row: row, column: column, extending: false)
            grid.update(); grid.layoutSubtreeIfNeeded()
            guard let region = grid.regions.first(where: {
                $0.range.contains(row) && $0.table.tableColumns.contains { $0.identifier.rawValue == String(column) }
            }), let localColumn = region.table.tableColumns.firstIndex(where: { $0.identifier.rawValue == String(column) }) else {
                throw WorkspaceError(message: "编辑测试找不到目标单元格")
            }
            let table = region.table
            table.scrollRowToVisible(row - table.rowOffset); table.scrollColumnToVisible(localColumn)
            let cell = table.frameOfCell(atColumn: localColumn, row: row - table.rowOffset)
            let point = table.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
            let click = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1)!
            table.mouseDown(with: click); grid.update(); settle()
            guard let text = table.currentEditor() as? NSTextView, let clip = text.superview as? NSClipView else {
                throw WorkspaceError(message: "双击未保留原生单元格编辑器")
            }
            try WorkspaceSmokeTests.require(text.isFieldEditor && clip.superview === grid,
                "编辑框未在当前表格面板上展开")
            return (table, text, clip)
        }
        func replace(_ text: NSTextView, with value: String) {
            text.insertText(value, replacementRange: NSRange(location: 0, length: text.string.utf16.count))
            settle()
        }
        func checkBounds(_ clip: NSClipView) throws {
            try WorkspaceSmokeTests.require(clip.frame.minX >= 0 && clip.frame.maxX <= grid.bounds.maxX + 0.5 &&
                clip.frame.minY >= 0 && clip.frame.maxY <= grid.bounds.maxY + 0.5,
                "临时编辑框超出了当前表格面板：\(clip.frame)")
        }
        let (table, text, clip) = try begin(row: 2, column: 1)
        let originalCell = table.frameOfCell(atColumn: table.editedColumn, row: table.editedRow)
        let originalWidth = table.tableColumns[table.editedColumn].width
        try WorkspaceSmokeTests.require(clip.frame.width > originalCell.width && clip.frame.height <= originalCell.height + 5,
            "中等长度单行文本未优先横向扩展：\(clip.frame)")
        let longText = String(repeating: sentence, count: 12)
        replace(text, with: longText)
        window.makeFirstResponder(text)
        try checkBounds(clip)
        try WorkspaceSmokeTests.require(clip.frame.height > originalCell.height && !text.string.contains("\n"),
            "长文本未自动折行，或显示折行改写了原文")
        var lineCount = 0
        text.layoutManager?.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: text.layoutManager?.numberOfGlyphs ?? 0)) { _, _, _, _, _ in
            lineCount += 1
        }
        try WorkspaceSmokeTests.require(lineCount > 1, "长文本的原生布局仍为单行截断")
        let unbroken = String(repeating: "ABCDEFGHIJ", count: 100)
        replace(text, with: unbroken)
        try WorkspaceSmokeTests.require(clip.frame.height > originalCell.height && text.string == unbroken,
            "无空格长文本被截断或未折行")
        text.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: text.selectedRange())
        table.resizeCellEditor()
        try WorkspaceSmokeTests.require(text.hasMarkedText(), "临时尺寸变化打断了中文输入法组合")
        text.insertText("中", replacementRange: text.markedRange())
        try WorkspaceSmokeTests.require(!text.hasMarkedText() && text.string.hasSuffix("中"), "中文候选字提交失败")
        replace(text, with: longText)
        let shiftReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)!
        NSApp.sendEvent(shiftReturn); settle()
        try WorkspaceSmokeTests.require(text.string == longText + "\n" && table.editedRow >= 0,
            "展开编辑时 Shift+Enter 未插入真实换行：length=\(text.string.utf16.count)/\(longText.utf16.count) suffix=\(String(reflecting: String(text.string.suffix(12)))) row=\(table.editedRow) responder=\(window.firstResponder === text)")
        replace(text, with: String(repeating: sentence, count: 120))
        try checkBounds(clip)
        try WorkspaceSmokeTests.require(text.frame.height > clip.bounds.height && clip.bounds.minY > 0,
            "超出窗口高度的长文本没有保留完整滚动内容或光标不可见")
        replace(text, with: longText)
        if let bitmap = grid.bitmapImageRepForCachingDisplay(in: grid.bounds) {
            grid.cacheDisplay(in: grid.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/dect-expanded-editing.png"))
        }
        text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        settle()
        try WorkspaceSmokeTests.require(table.editedRow == -1 && table.currentEditor() == nil &&
            model.inputText(GridAddress(row: 2, column: 1)) == longText,
            "Enter 未正确提交，或自动折行改变了保存内容")
        try WorkspaceSmokeTests.require(table.tableColumns[2].width == originalWidth &&
            abs(table.rect(ofRow: 2).height - (model.displayRowHeight(2) + 1) * model.zoom) < 0.5,
            "结束编辑后列宽或行高被永久改变")

        // Clicking another cell must still commit through the native delegate.
        let (again, againText, _) = try begin(row: 3, column: 2)
        replace(againText, with: "click commit")
        window.makeFirstResponder(again)
        try WorkspaceSmokeTests.require(model.inputText(GridAddress(row: 3, column: 2)) == "click commit",
            "移出编辑框未提交文本")
        let (multilineTable, multilineText, _) = try begin(row: 4, column: 2)
        replace(multilineText, with: "第一行\n第二行\n第三行")
        try WorkspaceSmokeTests.require(multilineText.string == "第一行\n第二行\n第三行", "粘贴的真实换行被替换成空格")
        multilineText.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try WorkspaceSmokeTests.require(multilineTable.editedRow == -1 &&
            model.inputText(GridAddress(row: 4, column: 2)) == "第一行\n第二行\n第三行", "多行文本提交丢失换行")
        let (_, reopenedText, _) = try begin(row: 4, column: 2)
        try WorkspaceSmokeTests.require(reopenedText.string == "第一行\n第二行\n第三行", "重新编辑丢失原有换行")
        window.makeFirstResponder(nil)

        let beforeAbort = model.inputText(GridAddress(row: 5, column: 2))
        let (abortedTable, abortedText, abortedClip) = try begin(row: 5, column: 2)
        replace(abortedText, with: "discarded edit")
        try WorkspaceSmokeTests.require(abortedTable.abortEditing() && abortedTable.editedRow == -1 &&
            abortedClip.superview !== grid && model.inputText(GridAddress(row: 5, column: 2)) == beforeAbort,
            "取消编辑未清除临时区域或错误提交了内容")
        let (_, afterAbortText, _) = try begin(row: 5, column: 2)
        try WorkspaceSmokeTests.require(afterAbortText.string == beforeAbort, "取消后重新编辑状态异常")
        window.makeFirstResponder(nil)

        model.frozenRows = 1; model.frozenColumns = 1; model.setZoom(1.5)
        grid.update(); grid.layoutSubtreeIfNeeded()
        let (frozenTable, frozenText, frozenClip) = try begin(row: 0, column: 0)
        replace(frozenText, with: longText)
        try checkBounds(frozenClip)
        try WorkspaceSmokeTests.require(frozenClip.frame.height > grid.regions[0].scroll.frame.height &&
            frozenClip.frame.width > grid.regions[0].scroll.frame.width,
            "冻结区域裁切了展开编辑框")
        grid.frame.size = NSSize(width: 420, height: 270)
        grid.needsLayout = true; grid.layoutSubtreeIfNeeded(); settle()
        try checkBounds(frozenClip)
        frozenText.doCommand(by: #selector(NSResponder.insertTab(_:)))
        settle()
        try WorkspaceSmokeTests.require(model.inputText(GridAddress(row: 0, column: 0)) == longText,
            "冻结区域 Tab 提交失败")
        window.makeFirstResponder(nil)
        try WorkspaceSmokeTests.require(frozenTable.editedRow == -1,
            "结束冻结区域编辑后原生编辑状态未恢复")
        print("单元格展开编辑：横向扩展、自动折行、超长滚动、中文组合、Shift+Enter、Enter/Tab/移焦提交、冻结区域、150% 缩放和窗口缩小通过；未访问真实配置表。")
    }
}
#endif
