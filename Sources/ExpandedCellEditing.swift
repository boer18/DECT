import AppKit

/// Resize AppKit's existing field editor, keeping its delegate, selection and
/// input-method session intact. The native clip view sits above the grid while
/// editing so frozen rows/columns cannot clip the expanded text.
@MainActor
final class ExpandedCellEditingSession {
    let textView: NSTextView
    private weak var table: CellGridTable?
    private weak var host: FrozenGridView?
    private let clip: NSClipView
    private weak var originalParent: NSView?
    private let originalClipFrame: NSRect
    private let originalClipBounds: NSRect
    private let originalTextFrame: NSRect
    private let originalAutoresizing: NSView.AutoresizingMask
    private let originalHorizontalResize: Bool
    private let originalVerticalResize: Bool
    private let originalMinSize: NSSize
    private let originalMaxSize: NSSize
    private let originalContainerSize: NSSize
    private let originalWidthTracks: Bool
    private let originalHeightTracks: Bool
    private let originalLineBreakMode: NSLineBreakMode
    private let originalParagraphStyle: NSParagraphStyle?
    private let originalTypingAttributes: [NSAttributedString.Key: Any]
    private let originalInset: NSSize
    private let originalClipBackground: NSColor
    private let originalClipDrawsBackground: Bool
    private let originalTextBackground: NSColor
    private let originalTextDrawsBackground: Bool
    private var observations: [NSObjectProtocol] = []
    private var resizing = false
    private var restored = false

    init?(table: CellGridTable, textView: NSTextView, host: FrozenGridView) {
        guard let clip = textView.superview as? NSClipView,
              let parent = clip.superview,
              let container = textView.textContainer else { return nil }
        self.table = table; self.textView = textView; self.host = host
        self.clip = clip; originalParent = parent
        originalClipFrame = clip.frame; originalClipBounds = clip.bounds
        originalTextFrame = textView.frame; originalAutoresizing = clip.autoresizingMask
        originalHorizontalResize = textView.isHorizontallyResizable
        originalVerticalResize = textView.isVerticallyResizable
        originalMinSize = textView.minSize; originalMaxSize = textView.maxSize
        originalContainerSize = container.containerSize
        originalWidthTracks = container.widthTracksTextView
        originalHeightTracks = container.heightTracksTextView
        originalLineBreakMode = container.lineBreakMode
        originalParagraphStyle = textView.defaultParagraphStyle
        originalTypingAttributes = textView.typingAttributes
        originalInset = textView.textContainerInset
        originalClipBackground = clip.backgroundColor
        originalClipDrawsBackground = clip.drawsBackground
        originalTextBackground = textView.backgroundColor
        originalTextDrawsBackground = textView.drawsBackground

        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        container.widthTracksTextView = false; container.heightTracksTextView = false
        container.lineBreakMode = .byWordWrapping
        let paragraph = (textView.defaultParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        textView.defaultParagraphStyle = paragraph
        textView.textStorage?.addAttribute(.paragraphStyle, value: paragraph,
                                          range: NSRange(location: 0, length: textView.string.utf16.count))
        textView.typingAttributes[.paragraphStyle] = paragraph
        textView.textContainerInset = NSSize(width: 3 * (table.editor?.zoom ?? 1), height: 3 * (table.editor?.zoom ?? 1))
        clip.drawsBackground = true; clip.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true; textView.backgroundColor = .textBackgroundColor
        clip.autoresizingMask = []
        host.addSubview(clip, positioned: .above, relativeTo: nil)

        let observedViews = [table.enclosingScrollView?.contentView, host].compactMap { $0 }
        for view in observedViews {
            observations.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resize() }
            })
        }
        if let window = table.window {
            observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resize() }
            })
        }
        resize()
    }

    deinit {
        observations.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func resize() {
        guard !restored, !resizing, let table, let host,
              table.editedRow >= 0, table.editedColumn >= 0,
              let container = textView.textContainer,
              let layout = textView.layoutManager else { return }
        resizing = true
        defer { resizing = false }
        var available = host.bounds.insetBy(dx: 2, dy: 2)
        let headerHeight = host.regions.compactMap { $0.table.headerView?.frame.height }.max() ?? 0
        available.origin.y += headerHeight
        available.size.height -= headerHeight
        guard available.width > 0, available.height > 0 else { return }
        let cell = table.convert(table.frameOfCell(atColumn: table.editedColumn, row: table.editedRow), to: host)
        let font = textView.font ?? NSFont.systemFont(ofSize: 12 * (table.editor?.zoom ?? 1))
        let longestLine = textView.string.components(separatedBy: .newlines).reduce(CGFloat(0)) {
            max($0, ($1 as NSString).size(withAttributes: [.font: font]).width)
        }
        let inset = textView.textContainerInset
        let x = min(max(cell.minX, available.minX), available.maxX - min(cell.width, available.width))
        let width = min(available.maxX - x, max(cell.width, ceil(longestLine) + 2 * inset.width + 2 * container.lineFragmentPadding + 4))
        container.containerSize = NSSize(width: max(1, width - 2 * inset.width), height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let textHeight = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        let fullHeight = max(cell.height, ceil(textHeight + 2 * inset.height + 2))
        let height = min(fullHeight, available.height)
        let y = min(max(cell.minY, available.minY), available.maxY - height)
        let origin = clip.bounds.origin
        clip.frame = NSRect(x: x, y: y, width: width, height: height)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: fullHeight)
        clip.bounds = NSRect(x: 0, y: min(max(0, origin.y), max(0, fullHeight - height)), width: width, height: height)
        textView.scrollRangeToVisible(NSRange(location: textView.selectedRange().location, length: 0))
        clip.needsDisplay = true
    }

    func restore() {
        guard !restored else { return }
        restored = true
        observations.forEach { NotificationCenter.default.removeObserver($0) }
        observations.removeAll()
        // NSTableView expects its original editor hierarchy when it commits or
        // cancels. Restore it before calling the native textDidEndEditing.
        originalParent?.addSubview(clip, positioned: .above, relativeTo: nil)
        clip.frame = originalClipFrame; clip.bounds = originalClipBounds
        clip.autoresizingMask = originalAutoresizing
        clip.drawsBackground = originalClipDrawsBackground; clip.backgroundColor = originalClipBackground
        textView.drawsBackground = originalTextDrawsBackground; textView.backgroundColor = originalTextBackground
        textView.isHorizontallyResizable = originalHorizontalResize
        textView.isVerticallyResizable = originalVerticalResize
        textView.minSize = originalMinSize; textView.maxSize = originalMaxSize
        textView.textContainerInset = originalInset
        textView.defaultParagraphStyle = originalParagraphStyle
        textView.typingAttributes = originalTypingAttributes
        if let container = textView.textContainer {
            container.widthTracksTextView = originalWidthTracks
            container.heightTracksTextView = originalHeightTracks
            container.containerSize = originalContainerSize
            container.lineBreakMode = originalLineBreakMode
        }
        textView.frame = originalTextFrame
    }
}
