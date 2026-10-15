import AppKit

private final class MoyeReaderDocument: NSView {
    override var isFlipped: Bool { true }
}

// The view stays close to the viewport size even when the original page is very tall.
// Drawing the whole image through the clip avoids a giant backing layer or a cropped bitmap.
private final class MoyeReaderImageView: NSImageView {
    var drawingRect: NSRect? { didSet { if drawingRect != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        image?.draw(in: drawingRect ?? bounds, from: .zero, operation: .sourceOver,
                    fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}

private final class MoyePageSlot: NSView {
    let imageView = MoyeReaderImageView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    var index: Int
    var pageClick: ((NSEvent) -> Void)?
    override var isFlipped: Bool { true }

    init(index: Int) {
        self.index = index
        super.init(frame: .zero)
        wantsLayer = true
        imageView.wantsLayer = true
        imageView.animates = false
        imageView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.setAccessibilityLabel("第 \(index + 1) 页")
        imageView.identifier = NSUserInterfaceItemIdentifier("reader-page-\(index + 1)")
        addSubview(imageView)
        placeholder.font = .systemFont(ofSize: 17, weight: .medium)
        placeholder.textColor = NSColor(white: 0.76, alpha: 1)
        placeholder.alignment = .center
        placeholder.maximumNumberOfLines = 3
        addSubview(placeholder)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func display(_ image: NSImage?, failed: Bool) {
        // Reassigning the same large NSImage on every scroll/reflow forces a redraw.
        if imageView.image !== image { imageView.image = image }
        let hidePlaceholder = image != nil
        if placeholder.isHidden != hidePlaceholder { placeholder.isHidden = hidePlaceholder }
        if !hidePlaceholder {
            let text = failed ? "第 \(index + 1) 页暂时无法加载\n请点工具栏中的“重试”" : "第 \(index + 1) 页 · 正在加载…"
            if placeholder.stringValue != text { placeholder.stringValue = text }
        }
    }
    override func layout() {
        super.layout()
        imageView.frame = bounds
        placeholder.frame = NSRect(x: 10, y: max(0, (bounds.height - 70) / 2), width: max(0, bounds.width - 20), height: 70)
    }
    override func mouseDown(with event: NSEvent) { pageClick?(event) }
}

final class MoyeComicReaderView: NSView {
    typealias PageLoader = (Int, @escaping (NSImage?) -> Void) -> Void
    private enum Mode: String, CaseIterable { case spread, vertical, webtoon }
    private struct ReadingPosition { let page: Int; let fraction: CGFloat }
    private static let modeKey = "MoyeReader.ReadingMode"
    private let totalPages: Int
    private let chapterIndex: Int
    private let chapterCount: Int
    private let chapterTitle: String
    private let loader: PageLoader
    private let toolbar = NSView()
    private let footer = NSView()
    private let stage = NSView()
    private let scrollView = NSScrollView()
    private let document = MoyeReaderDocument()
    private let titleField = NSTextField(labelWithString: "")
    private let hintField = NSTextField(labelWithString: "")
    private let counterField = NSTextField(labelWithString: "")
    private let chapterField = NSTextField(labelWithString: "")
    private let modeControl = NSSegmentedControl(labels: ["横向双页", "竖向阅读", "长条漫画"], trackingMode: .selectOne, target: nil, action: nil)
    private let backButton = MoyeGlassButton(frame: .zero)
    private let fullscreenButton = MoyeGlassButton(frame: .zero)
    private let chromeButton = MoyeGlassButton(frame: .zero)
    private let downloadButton = MoyeGlassButton(frame: .zero)
    private let progressButton = MoyeGlassButton(frame: .zero)
    private let retryButton = MoyeGlassButton(frame: .zero)
    private let nextButton = MoyeGlassButton(frame: .zero)
    private let previousButton = MoyeGlassButton(frame: .zero)
    private let nextChapterButton = MoyeGlassButton(frame: .zero)
    private let previousChapterButton = MoyeGlassButton(frame: .zero)
    private var pageSlots: [MoyePageSlot] = []
    private var spreadSlots: [MoyePageSlot] = []
    private var spreadScrolls = false
    private var spreadPageFrames: [NSRect] = []
    private var spreadLayoutStart: Int?
    private var lastSpreadAtTop: Bool?
    private var lastSpreadAtBottom: Bool?
    private var pageFrames: [NSRect] = []
    private var renderedIndices = Set<Int>()
    private var savedContinuousPosition: ReadingPosition?
    private var pendingPosition: ReadingPosition?
    private var lastAtTop: Bool?
    private var lastAtBottom: Bool?
    private var sizes: [Int: NSSize] = [:]
    private let cache = NSCache<NSNumber, NSImage>()
    // NSCache may evict at any time; displayed pages must not depend on it.
    private var visibleImages: [Int: NSImage] = [:]
    private var prefetchAttempted: Set<Int> = []
    private var failed: Set<Int> = []
    private var pendingLoads: Set<Int> = []
    private var loadQueue: [Int] = []
    private var activeLoads = 0
    private var mode: Mode
    private(set) var currentPage: Int
    private var chromeHidden = false
    private var temporarilyRevealed = false
    private var revealGeneration = UUID()
    private var clickMonitor: Any?
    private var isLayingOut = false
    private var scrollToCurrent = true
    private var chapterLoading = false
    private var chapterMessage: String?
    private var observers: [NSObjectProtocol] = []
    var onDownload: (() -> Void)?
    var onProgress: (() -> Void)?
    var onBack: (() -> Void)?
    var onPageChanged: ((Int) -> Void)?
    var onNextChapter: (() -> Void)? { didSet { updateControls() } }
    var onPreviousChapter: (() -> Void)? { didSet { updateControls() } }
    var hidesChrome: Bool { chromeHidden }

    init(title: String, pageCount: Int, initialPage: Int = 0, chapterIndex: Int = 0, chapterCount: Int = 1, chapterTitle: String = "", chromeInitiallyHidden: Bool = false, loader: @escaping PageLoader) {
        self.totalPages = max(0, pageCount)
        self.chapterCount = max(1, chapterCount)
        self.chapterIndex = max(0, min(chapterIndex, max(0, chapterCount - 1)))
        self.chapterTitle = chapterTitle.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        self.currentPage = max(0, min(initialPage, max(0, pageCount - 1)))
        self.loader = loader
        self.mode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(Mode.init(rawValue:)) ?? .spread
        self.chromeHidden = chromeInitiallyHidden
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.055, green: 0.06, blue: 0.075, alpha: 1).cgColor
        cache.countLimit = 24
        cache.totalCostLimit = 160 * 1024 * 1024
        stage.wantsLayer = true
        stage.layer?.backgroundColor = layer?.backgroundColor
        addSubview(stage)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = document
        stage.addSubview(scrollView)
        for index in 0..<totalPages {
            let slot = MoyePageSlot(index: index)
            slot.pageClick = { [weak self] event in self?.handlePageClick(event) }
            pageSlots.append(slot)
        }
        for _ in 0..<2 {
            let slot = MoyePageSlot(index: 0)
            slot.pageClick = { [weak self] event in self?.handlePageClick(event) }
            stage.addSubview(slot)
            spreadSlots.append(slot)
        }
        configureBar(toolbar)
        configureBar(footer)
        addSubview(toolbar)
        addSubview(footer)
        titleField.stringValue = title
        titleField.toolTip = title
        titleField.font = .systemFont(ofSize: 16, weight: .semibold)
        titleField.textColor = .white
        titleField.lineBreakMode = .byTruncatingTail
        toolbar.addSubview(titleField)
        hintField.font = .systemFont(ofSize: 12, weight: .medium)
        hintField.textColor = NSColor(white: 0.76, alpha: 1)
        hintField.lineBreakMode = .byTruncatingTail
        toolbar.addSubview(hintField)
        counterField.font = .systemFont(ofSize: 15, weight: .semibold)
        counterField.textColor = .white
        counterField.alignment = .center
        footer.addSubview(counterField)
        chapterField.font = .systemFont(ofSize: 13, weight: .medium)
        chapterField.textColor = NSColor(white: 0.78, alpha: 1)
        chapterField.alignment = .center
        chapterField.lineBreakMode = .byTruncatingTail
        footer.addSubview(chapterField)
        configureButton(backButton, "返回", "chevron.backward", #selector(goBack(_:)), in: toolbar, id: "reader-back")
        configureButton(fullscreenButton, "全屏", "arrow.up.left.and.arrow.down.right", #selector(toggleFullscreen(_:)), in: toolbar, id: "reader-fullscreen")
        configureButton(chromeButton, "隐藏工具栏", "rectangle.compress.vertical", #selector(toggleChrome(_:)), in: toolbar, id: "reader-hide-toolbar")
        chromeButton.toolTip = "隐藏后单击画面临时显示，点还原工具栏固定显示 · Tab"
        configureButton(downloadButton, "下载", "arrow.down.to.line", #selector(download(_:)), in: toolbar, id: "reader-download")
        configureButton(progressButton, "下载进度", "chart.bar.fill", #selector(showProgress(_:)), in: toolbar, id: "reader-download-progress")
        progressButton.isHidden = true
        configureButton(retryButton, "重试", "arrow.clockwise", #selector(retryPages(_:)), in: toolbar, id: "reader-retry")
        configureButton(nextButton, "下一组", "chevron.left", #selector(nextPages(_:)), in: footer, id: "reader-next")
        configureButton(previousButton, "上一组", "chevron.right", #selector(previousPages(_:)), in: footer, id: "reader-previous")
        configureButton(nextChapterButton, "下一章", "chevron.left.2", #selector(nextChapter(_:)), in: footer, id: "reader-next-chapter")
        configureButton(previousChapterButton, "上一章", "chevron.right.2", #selector(previousChapter(_:)), in: footer, id: "reader-previous-chapter")
        nextChapterButton.toolTip = "下一章 · N 或 ⌥←"
        previousChapterButton.toolTip = "上一章 · P 或 ⌥→"
        nextChapterButton.setAccessibilityLabel("下一章节，快捷键 N 或 Option 加左方向键")
        previousChapterButton.setAccessibilityLabel("上一章节，快捷键 P 或 Option 加右方向键")
        modeControl.target = self
        modeControl.action = #selector(changeMode(_:))
        modeControl.font = .systemFont(ofSize: 14, weight: .semibold)
        modeControl.selectedSegment = Mode.allCases.firstIndex(of: mode) ?? 0
        modeControl.identifier = NSUserInterfaceItemIdentifier("reader-mode")
        toolbar.addSubview(modeControl)
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in self?.scrolled() })
        updateControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) }; if let clickMonitor { NSEvent.removeMonitor(clickMonitor) } }
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.makeFirstResponder(self)
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.window === self.window, self.chromeHidden else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                if self.temporarilyRevealed && (self.toolbar.frame.contains(point) || self.footer.frame.contains(point)) { return event }
                self.revealTemporarily()
                return nil
            }
        }
        if window.styleMask.contains(.fullScreen) { chromeHidden = true }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            self?.chromeHidden = true
            self?.updateFullscreenTitle()
            self?.needsLayout = true
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            self?.chromeHidden = false
            self?.updateFullscreenTitle()
            self?.needsLayout = true
        })
        updateFullscreenTitle()
        needsLayout = true
    }

    private func configureBar(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 0.97).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
    }
    private func configureButton(_ button: NSButton, _ title: String, _ symbol: String, _ action: Selector, in parent: NSView, id: String) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 14, weight: .semibold)
        button.contentTintColor = .white
        button.target = self
        button.action = action
        button.identifier = NSUserInterfaceItemIdentifier(id)
        parent.addSubview(button)
    }

    override func layout() {
        super.layout()
        isLayingOut = true
        defer { isLayingOut = false }
        toolbar.isHidden = chromeHidden && !temporarilyRevealed
        footer.isHidden = chromeHidden && !temporarilyRevealed
        chromeButton.title = chromeHidden ? "还原工具栏" : "隐藏工具栏"
        let topInset: CGFloat = chromeHidden ? 0 : 76
        let bottomInset: CGFloat = chromeHidden ? 0 : (chapterCount > 1 ? 78 : 60)
        stage.frame = NSRect(x: 0, y: bottomInset, width: bounds.width, height: max(1, bounds.height - topInset - bottomInset))
        toolbar.frame = NSRect(x: 12, y: bounds.height - 66, width: bounds.width - 24, height: 56)
        let w = toolbar.bounds.width
        backButton.frame = NSRect(x: 8, y: 10, width: 90, height: 36)
        var right = w - 10
        chromeButton.frame = NSRect(x: right - 138, y: 10, width: 138, height: 36); right -= 146
        fullscreenButton.frame = NSRect(x: right - 116, y: 10, width: 116, height: 36); right -= 124
        retryButton.frame = NSRect(x: right - 90, y: 10, width: 90, height: 36); right -= 98
        downloadButton.frame = NSRect(x: right - 92, y: 10, width: 92, height: 36); right -= 100
        if !progressButton.isHidden { progressButton.frame = NSRect(x: right - 112, y: 10, width: 112, height: 36); right -= 120 }
        modeControl.frame = NSRect(x: right - 288, y: 10, width: 288, height: 36); right -= 300
        titleField.frame = NSRect(x: 104, y: 30, width: max(0, right - 110), height: 21)
        hintField.frame = NSRect(x: 104, y: 9, width: max(0, right - 110), height: 18)
        if chapterCount > 1 {
            footer.frame = NSRect(x: max(12, (bounds.width - 840) / 2), y: 10, width: min(840, bounds.width - 24), height: 60)
            nextChapterButton.frame = NSRect(x: 8, y: 12, width: 116, height: 36)
            nextButton.frame = NSRect(x: 132, y: 12, width: 104, height: 36)
            previousChapterButton.frame = NSRect(x: footer.bounds.width - 124, y: 12, width: 116, height: 36)
            previousButton.frame = NSRect(x: footer.bounds.width - 236, y: 12, width: 104, height: 36)
            let centerWidth = max(0, footer.bounds.width - 488)
            chapterField.frame = NSRect(x: 244, y: 33, width: centerWidth, height: 19)
            counterField.frame = NSRect(x: 244, y: 9, width: centerWidth, height: 22)
        } else {
            footer.frame = NSRect(x: max(12, (bounds.width - 500) / 2), y: 10, width: min(500, bounds.width - 24), height: 44)
            nextButton.frame = NSRect(x: 8, y: 4, width: 112, height: 36)
            previousButton.frame = NSRect(x: footer.bounds.width - 120, y: 4, width: 112, height: 36)
            counterField.frame = NSRect(x: 124, y: 12, width: max(0, footer.bounds.width - 248), height: 22)
        }
        if mode == .spread { layoutSpread() } else { layoutVertical() }
        refreshVisiblePages()
    }

    private var spreadStart: Int { (currentPage / 2) * 2 }
    private func ratio(at index: Int) -> CGFloat {
        let size = sizes[index] ?? NSSize(width: 720, height: 1000)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return 0.72 }
        return size.width / size.height
    }
    private func layoutSpread() {
        let start = spreadStart
        guard start < totalPages else { spreadSlots.forEach { $0.isHidden = true }; return }
        let position = pendingPosition ?? spreadPosition()
        spreadScrolls = (start..<min(start + 2, totalPages)).contains { sizes[$0] != nil && ratio(at: $0) <= 1.0 / 3.0 }
        if spreadScrolls {
            layoutScrollableSpread(position: position)
        } else {
            layoutFittedSpread()
        }
        spreadLayoutStart = start
        pendingPosition = nil
        scrollToCurrent = false
        lastSpreadAtTop = spreadScrolls ? scrollView.contentView.bounds.minY <= 0 : nil
        lastSpreadAtBottom = spreadScrolls ? spreadAtBottom : nil
        updateControls()
    }
    private func layoutFittedSpread() {
        scrollView.isHidden = true
        spreadPageFrames.removeAll()
        let start = spreadStart
        let rightRatio = ratio(at: start)
        let leftRatio = start + 1 < totalPages ? ratio(at: start + 1) : 0
        let height = max(1, min(stage.bounds.height - 24, (stage.bounds.width - 32) / (rightRatio + leftRatio)))
        let leftWidth = height * leftRatio, rightWidth = height * rightRatio
        let x = (stage.bounds.width - leftWidth - rightWidth) / 2
        let scale = window?.backingScaleFactor ?? 2
        let seam = ((x + leftWidth) * scale).rounded() / scale
        let y = (stage.bounds.height - height) / 2
        spreadSlots[0].frame = NSRect(x: seam, y: y, width: rightWidth, height: height)
        spreadSlots[1].frame = NSRect(x: seam - leftWidth, y: y, width: leftWidth, height: height)
        for (offset, slot) in spreadSlots.enumerated() {
            if slot.superview !== stage { stage.addSubview(slot) }
            slot.index = start + offset
            slot.imageView.drawingRect = nil
            slot.isHidden = start + offset >= totalPages
            slot.imageView.setAccessibilityLabel("第 \(start + offset + 1) 页 · \(offset == 0 ? "右页" : "左页")")
            slot.imageView.identifier = NSUserInterfaceItemIdentifier("reader-page-\(start + offset + 1)")
        }
    }
    private func layoutScrollableSpread(position: ReadingPosition?) {
        scrollView.isHidden = false
        scrollView.frame = stage.bounds
        let width = scrollView.contentSize.width
        let count = min(2, totalPages - spreadStart)
        let pageWidth = max(1, count == 2 ? (width - 32) / 2 : min(1000, width - 32))
        let scale = window?.backingScaleFactor ?? 2
        let seam = (width * scale / 2).rounded() / scale
        spreadPageFrames = (0..<count).map { offset in
            NSRect(x: count == 1 ? (width - pageWidth) / 2 : (offset == 0 ? seam : seam - pageWidth),
                   y: 0, width: pageWidth, height: pageWidth / ratio(at: spreadStart + offset))
        }
        let height = max(scrollView.contentSize.height, spreadPageFrames.map(\.maxY).max() ?? 0)
        document.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let offset: CGFloat
        if let position, (spreadStart..<spreadStart + count).contains(position.page) {
            offset = spreadPageFrames[position.page - spreadStart].height * position.fraction
        } else { offset = 0 }
        let maximum = max(0, height - scrollView.contentSize.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, offset))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        for (offset, slot) in spreadSlots.enumerated() {
            if slot.superview !== document { document.addSubview(slot) }
            slot.index = spreadStart + offset
            slot.imageView.identifier = NSUserInterfaceItemIdentifier("reader-page-\(slot.index + 1)")
            slot.imageView.setAccessibilityLabel("第 \(slot.index + 1) 页 · \(offset == 0 ? "右页" : "左页")，可上下滚动")
        }
        refreshSpreadFrames()
    }
    private func spreadPosition() -> ReadingPosition? {
        guard spreadScrolls, spreadLayoutStart == spreadStart,
              let offset = spreadPageFrames.indices.max(by: { spreadPageFrames[$0].height < spreadPageFrames[$1].height }) else { return nil }
        let height = spreadPageFrames[offset].height
        return ReadingPosition(page: spreadStart + offset, fraction: max(0, min(1, scrollView.contentView.bounds.minY / max(1, height))))
    }
    private func bufferedViewport() -> NSRect {
        let viewport = scrollView.contentView.bounds
        let top = max(0, floor((viewport.minY - viewport.height) / 512) * 512)
        let bottom = ceil((viewport.maxY + viewport.height) / 512) * 512
        return NSRect(x: 0, y: top, width: document.bounds.width, height: bottom - top)
    }
    private func refreshSpreadFrames() {
        let buffer = bufferedViewport()
        for (offset, slot) in spreadSlots.enumerated() {
            guard spreadPageFrames.indices.contains(offset) else { slot.isHidden = true; continue }
            let full = spreadPageFrames[offset]
            let clipped = full.intersection(buffer)
            slot.isHidden = clipped.isNull || clipped.height <= 0
            guard !slot.isHidden else { continue }
            if slot.frame != clipped { slot.frame = clipped }
            slot.imageView.drawingRect = NSRect(x: 0, y: full.minY - clipped.minY, width: full.width, height: full.height)
        }
    }
    private func layoutVertical() {
        spreadSlots.forEach {
            $0.isHidden = true; $0.display(nil, failed: false)
            if $0.superview !== stage { stage.addSubview($0) }
        }
        scrollView.isHidden = false
        let anchor = pendingPosition ?? (scrollToCurrent ? ReadingPosition(page: currentPage, fraction: 0) : continuousPosition())
        scrollView.frame = stage.bounds
        let width = scrollView.contentSize.width
        let pageWidth = max(1, min(1000, width - 32))
        pageFrames.removeAll(keepingCapacity: true)
        let gap: CGFloat = mode == .webtoon ? 0 : 12
        var y: CGFloat = gap
        for index in 0..<totalPages {
            let height = pageWidth / ratio(at: index)
            let rect = NSRect(x: (width - pageWidth) / 2, y: y, width: pageWidth, height: height)
            pageFrames.append(rect)
            y += height + gap
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(scrollView.contentSize.height, y))
        if let anchor, pageFrames.indices.contains(anchor.page) {
            let rect = pageFrames[anchor.page]
            let offset = rect.minY + rect.height * anchor.fraction
            let maxOffset = max(0, document.bounds.height - scrollView.contentSize.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(maxOffset, offset))))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        scrollToCurrent = false
        pendingPosition = nil
        updateCurrentPage()
    }

    private func pageIndex(at y: CGFloat) -> Int {
        var low = 0, high = pageFrames.count
        while low < high {
            let middle = (low + high) / 2
            if pageFrames[middle].maxY <= y { low = middle + 1 } else { high = middle }
        }
        return min(low, max(0, pageFrames.count - 1))
    }
    private func indices(intersecting rect: NSRect) -> [Int] {
        guard !pageFrames.isEmpty, rect.height > 0 else { return [] }
        var index = pageIndex(at: rect.minY)
        var result: [Int] = []
        while index < pageFrames.count, pageFrames[index].minY < rect.maxY {
            if pageFrames[index].intersects(rect) { result.append(index) }
            index += 1
        }
        return result
    }
    private func continuousPosition() -> ReadingPosition? {
        guard !pageFrames.isEmpty else { return nil }
        let offset = scrollView.contentView.bounds.minY
        let index = pageIndex(at: offset)
        let rect = pageFrames[index]
        return ReadingPosition(page: index, fraction: max(0, min(1, (offset - rect.minY) / max(1, rect.height))))
    }
    private func visibleIndices() -> [Int] {
        if mode == .spread { return [spreadStart, spreadStart + 1].filter { $0 < totalPages } }
        return indices(intersecting: scrollView.contentView.bounds)
    }
    private func refreshVisiblePages() {
        guard totalPages > 0 else { return }
        let visible = visibleIndices()
        // Quantize the buffer so trackpad scrolling moves existing layers instead of repainting every pixel.
        let renderRect = bufferedViewport()
        let rendered = mode == .spread ? visible : indices(intersecting: renderRect)
        var wanted = rendered
        if let first = rendered.first, let last = rendered.last {
            let extra = mode == .spread ? 2 : 1
            wanted = Array(max(0, first - extra)...min(totalPages - 1, last + extra))
        }
        let active = Set(wanted)
        let visibleSet = Set(visible)
        let renderSet = Set(rendered)
        visibleImages = visibleImages.filter { renderSet.contains($0.key) }
        prefetchAttempted.formIntersection(active)
        for index in rendered where visibleImages[index] == nil {
            visibleImages[index] = cache.object(forKey: NSNumber(value: index))
        }
        // A quick page turn should prioritize the new visible spread over stale prefetches.
        let cancelled = loadQueue.filter { !active.contains($0) }
        loadQueue.removeAll { !active.contains($0) }
        cancelled.forEach { pendingLoads.remove($0) }
        if mode == .spread {
            for index in renderedIndices { pageSlots[index].removeFromSuperview(); pageSlots[index].display(nil, failed: false) }
            renderedIndices.removeAll()
            for (offset, slot) in spreadSlots.enumerated() {
                let index = spreadStart + offset
                guard index < totalPages else { continue }
                slot.display(visibleImages[index], failed: failed.contains(index))
            }
        } else {
            for index in renderedIndices.subtracting(renderSet) {
                pageSlots[index].removeFromSuperview()
                pageSlots[index].display(nil, failed: false)
            }
            for index in rendered {
                let rect = pageFrames[index]
                let clipped = rect.intersection(renderRect)
                let slot = pageSlots[index]
                if slot.superview == nil { document.addSubview(slot) }
                if slot.frame != clipped { slot.frame = clipped }
                slot.imageView.drawingRect = NSRect(x: 0, y: rect.minY - clipped.minY, width: rect.width, height: rect.height)
                slot.display(visibleImages[index], failed: failed.contains(index))
            }
            renderedIndices = renderSet
        }
        for index in wanted where visibleImages[index] == nil && cache.object(forKey: NSNumber(value: index)) == nil && !failed.contains(index) && !pendingLoads.contains(index) && (visibleSet.contains(index) || !prefetchAttempted.contains(index)) {
            pendingLoads.insert(index)
            prefetchAttempted.insert(index)
            loadQueue.append(index)
        }
        loadQueue.sort { visibleSet.contains($0) && !visibleSet.contains($1) }
        pumpLoads()
        retryButton.isEnabled = !failed.isEmpty
    }
    private func pumpLoads() {
        while activeLoads < (mode == .spread ? 4 : 2), !loadQueue.isEmpty {
            let index = loadQueue.removeFirst()
            activeLoads += 1
            loader(index) { [weak self] image in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.activeLoads -= 1
                    self.pendingLoads.remove(index)
                    if let image {
                        image.cacheMode = .never
                        let oldRatio = self.ratio(at: index)
                        self.sizes[index] = image.size
                        self.cache.setObject(image, forKey: NSNumber(value: index), cost: Int(max(1, image.size.width * image.size.height * 4)))
                        let isRendered = self.mode == .spread ? self.visibleIndices().contains(index) : self.renderedIndices.contains(index)
                        if isRendered { self.visibleImages[index] = image }
                        self.failed.remove(index)
                        if abs(oldRatio - self.ratio(at: index)) > 0.0001 {
                            self.needsLayout = true
                            self.pumpLoads()
                            return
                        }
                    } else { self.failed.insert(index) }
                    self.refreshVisiblePages()
                }
            }
        }
    }
    private func scrolled() {
        guard !isLayingOut else { return }
        if mode == .spread {
            guard spreadScrolls else { return }
            refreshSpreadFrames()
            let atTop = scrollView.contentView.bounds.minY <= 0
            let atBottom = spreadAtBottom
            if lastSpreadAtTop != atTop || lastSpreadAtBottom != atBottom { updateControls() }
            lastSpreadAtTop = atTop; lastSpreadAtBottom = atBottom
            return
        }
        guard !pageFrames.isEmpty else { return }
        updateCurrentPage()
        refreshVisiblePages()
    }
    private func updateCurrentPage() {
        guard !pageFrames.isEmpty else { return }
        let page = pageIndex(at: scrollView.contentView.bounds.minY + 1)
        let atTop = scrollView.contentView.bounds.minY <= 0
        let atBottom = scrollView.contentView.bounds.maxY >= document.bounds.maxY - 1
        let pageChanged = currentPage != page
        let boundaryChanged = lastAtTop != atTop || lastAtBottom != atBottom
        lastAtTop = atTop; lastAtBottom = atBottom
        if pageChanged { currentPage = page; onPageChanged?(page) }
        if pageChanged || boundaryChanged { updateControls() }
    }
    private var spreadAtBottom: Bool { scrollView.contentView.bounds.maxY >= document.bounds.maxY - 1 }
    private func updateControls() {
        let hasNextChapter = chapterIndex + 1 < chapterCount && onNextChapter != nil
        let hasPreviousChapter = chapterIndex > 0 && onPreviousChapter != nil
        let atChapterEnd = mode == .spread ? spreadStart + 2 >= totalPages && (!spreadScrolls || spreadAtBottom) : scrollView.contentView.bounds.maxY >= document.bounds.maxY - 1
        if mode == .spread {
            let start = spreadStart
            let end = min(start + 2, totalPages)
            let range = end == start + 1 ? "\(end)" : "\(start + 1)–\(end)"
            counterField.stringValue = totalPages > 0 ? "第 \(range) / \(totalPages) 页" : "没有可用页面"
            let moreBelow = spreadScrolls && !spreadAtBottom
            let moreAbove = spreadScrolls && scrollView.contentView.bounds.minY > 0
            hintField.stringValue = spreadScrolls ? "双页长图 · 上下滚动 · 读到底再翻组 · V 切换 · F 全屏" : "从右到左 · ← 下一组 · → 上一组 · V 切换 · F 全屏"
            nextButton.title = moreBelow ? "下一屏" : "下一组"
            previousButton.title = moreAbove ? "上一屏" : "上一组"
            nextButton.isEnabled = moreBelow || start + 2 < totalPages
            previousButton.isEnabled = moreAbove || start > 0
        } else {
            counterField.stringValue = totalPages > 0 ? "第 \(currentPage + 1) / \(totalPages) 页" : "没有可用页面"
            hintField.stringValue = (mode == .webtoon ? "长条无缝阅读" : "竖向连续阅读") + " · 滚动 / 空格浏览 · V 切换模式 · F 全屏"
            nextButton.title = "下一屏"
            previousButton.title = "上一屏"
            nextButton.isEnabled = !atChapterEnd
            previousButton.isEnabled = scrollView.contentView.bounds.minY > 0
        }
        if atChapterEnd && hasNextChapter {
            nextButton.title = "下一章"
            nextButton.isEnabled = true
            nextButton.toolTip = "本章已到最后一页，继续翻页进入下一章"
        } else { nextButton.toolTip = mode == .spread && !spreadScrolls ? "下一组 · ← 或空格" : "向下滚动一屏；读到底后继续翻页 · ←、空格或 Page Down" }
        if chapterLoading { nextButton.isEnabled = false; previousButton.isEnabled = false }
        nextChapterButton.isHidden = chapterCount <= 1
        previousChapterButton.isHidden = chapterCount <= 1
        chapterField.isHidden = chapterCount <= 1
        nextChapterButton.isEnabled = hasNextChapter && !chapterLoading
        previousChapterButton.isEnabled = hasPreviousChapter && !chapterLoading
        chapterField.stringValue = chapterMessage ?? ("第 \(chapterIndex + 1) / \(chapterCount) 章" + (chapterTitle.isEmpty ? "" : " · " + chapterTitle))
        chapterField.toolTip = chapterField.stringValue
        if chapterCount > 1 { hintField.stringValue += " · N 下一章 · P 上一章" }
        hintField.toolTip = hintField.stringValue
        modeControl.selectedSegment = Mode.allCases.firstIndex(of: mode) ?? 0
    }
    private func move(_ forward: Bool) {
        guard !chapterLoading else { return }
        if mode != .spread {
            let clip = scrollView.contentView
            let maxOffset = max(0, document.bounds.height - scrollView.contentSize.height)
            if forward, clip.bounds.minY >= maxOffset - 1 { nextChapter(nil); return }
            scrollContinuously(by: (forward ? 1 : -1) * clip.bounds.height * 0.9)
            return
        }
        if spreadScrolls {
            let clip = scrollView.contentView
            if forward && !spreadAtBottom || !forward && clip.bounds.minY > 0 {
                scrollContinuously(by: (forward ? 1 : -1) * clip.bounds.height * 0.9)
                return
            }
        }
        let next = spreadStart + (forward ? 2 : -2)
        if forward, next >= totalPages { nextChapter(nil); return }
        guard next >= 0, next < totalPages else { return }
        currentPage = next
        scrollToCurrent = true
        onPageChanged?(next)
        updateControls()
        needsLayout = true
        window?.makeFirstResponder(self)
    }
    private func scrollContinuously(by distance: CGFloat) {
        let clip = scrollView.contentView
        let maxOffset = max(0, document.bounds.height - scrollView.contentSize.height)
        clip.scroll(to: NSPoint(x: 0, y: max(0, min(maxOffset, clip.bounds.minY + distance))))
        scrollView.reflectScrolledClipView(clip)
        scrolled()
        window?.makeFirstResponder(self)
    }
    private func handlePageClick(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        if chromeHidden { revealTemporarily(); return }
        if mode != .spread { return }
        let location = stage.convert(event.locationInWindow, from: nil)
        if location.x < stage.bounds.width * 0.45 { move(true) }
        else if location.x > stage.bounds.width * 0.55 { move(false) }
        else { toggleChrome(nil) }
    }
    @objc private func nextPages(_ sender: Any?) { move(true) }
    @objc private func previousPages(_ sender: Any?) { move(false) }
    @objc private func nextChapter(_ sender: Any?) {
        guard !chapterLoading, chapterIndex + 1 < chapterCount else { return }
        window?.makeFirstResponder(self)
        onNextChapter?()
    }
    @objc private func previousChapter(_ sender: Any?) {
        guard !chapterLoading, chapterIndex > 0 else { return }
        window?.makeFirstResponder(self)
        onPreviousChapter?()
    }
    func showChapterLoading(_ title: String) {
        chapterLoading = true
        chapterMessage = "正在打开：" + title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        updateControls()
        if chromeHidden { revealTemporarily() }
    }
    func finishChapterLoading(message: String) {
        chapterLoading = false
        chapterMessage = message
        updateControls()
        if chromeHidden { revealTemporarily() }
    }
    @objc private func goBack(_ sender: Any?) { onBack?() }
    @objc private func retryPages(_ sender: Any?) {
        prefetchAttempted.subtract(failed)
        failed.removeAll()
        refreshVisiblePages()
        window?.makeFirstResponder(self)
    }
    @objc private func changeMode(_ sender: Any?) {
        let previousMode = mode
        if mode != .spread { savedContinuousPosition = continuousPosition() }
        else if let position = spreadPosition() { savedContinuousPosition = position }
        if let control = sender as? NSSegmentedControl, Mode.allCases.indices.contains(control.selectedSegment) { mode = Mode.allCases[control.selectedSegment] }
        else { mode = Mode.allCases[((Mode.allCases.firstIndex(of: mode) ?? 0) + 1) % Mode.allCases.count] }
        if let position = savedContinuousPosition,
           position.page == currentPage || (previousMode == .spread && position.page / 2 == currentPage / 2) {
            pendingPosition = position
            if mode != .spread { currentPage = position.page }
        }
        else { pendingPosition = ReadingPosition(page: currentPage, fraction: 0) }
        UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        scrollToCurrent = true
        updateControls()
        needsLayout = true
        window?.makeFirstResponder(self)
    }
    private func revealTemporarily() {
        temporarilyRevealed = true; revealGeneration = UUID()
        let run = revealGeneration
        needsLayout = true
        window?.makeFirstResponder(self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.chromeHidden, self.revealGeneration == run else { return }
            self.temporarilyRevealed = false; self.needsLayout = true
        }
    }
    func updateDownloadStatus(_ running: Bool) { progressButton.isHidden = !running; needsLayout = true }
    @objc private func download(_ sender: Any?) { onDownload?() }
    @objc private func showProgress(_ sender: Any?) { onProgress?() }
    @objc private func toggleChrome(_ sender: Any?) {
        chromeHidden.toggle()
        temporarilyRevealed = false; revealGeneration = UUID()
        needsLayout = true
        window?.makeFirstResponder(self)
    }
    @objc private func toggleFullscreen(_ sender: Any?) {
        window?.makeFirstResponder(self)
        window?.toggleFullScreen(nil)
    }
    private func updateFullscreenTitle() { fullscreenButton.title = window?.styleMask.contains(.fullScreen) == true ? "退出全屏" : "全屏" }
#if MOYE_READER_DIAGNOSTICS
    func verificationSnapshot() -> [String: Any] {
        let visible = visibleIndices()
        let displayed = mode == .spread ? spreadSlots.filter { !$0.isHidden && $0.imageView.image != nil }.map(\.index) : visible.filter { pageSlots[$0].imageView.image != nil }
        func record(_ rect: NSRect) -> [String: CGFloat] { ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height] }
        return ["visible": visible, "displayed": displayed, "retained": visibleImages.keys.sorted(),
                "activeLoads": activeLoads, "queuedLoads": loadQueue.count, "mode": mode.rawValue,
                "chromeHidden": chromeHidden, "temporarilyRevealed": temporarilyRevealed,
                "spreadFrames": spreadSlots.filter { !$0.isHidden }.map { record($0.frame) },
                "spreadScrollable": spreadScrolls, "spreadPageFrames": spreadPageFrames.map(record),
                "pageFrames": pageFrames.map(record), "rendered": renderedIndices.sorted(),
                "renderedFrames": renderedIndices.sorted().map { record(pageSlots[$0].frame) },
                "viewport": record(scrollView.contentView.bounds), "stage": record(stage.frame),
                "documentHeight": document.bounds.height]
    }
#endif
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.option), modifiers.intersection([.command, .control, .shift]).isEmpty {
            if event.keyCode == 123 { if !event.isARepeat { nextChapter(nil) }; return }
            if event.keyCode == 124 { if !event.isARepeat { previousChapter(nil) }; return }
        }
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 123: move(true)
        case 124: move(false)
        case 121: move(true)
        case 116: move(false)
        case 125: if mode != .spread || spreadScrolls { scrollContinuously(by: 80) } else { super.keyDown(with: event) }
        case 126: if mode != .spread || spreadScrolls { scrollContinuously(by: -80) } else { super.keyDown(with: event) }
        case 48: toggleChrome(nil)
        case 53:
            if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
            else if chromeHidden { toggleChrome(nil) }
            else { onBack?() }
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": changeMode(nil)
            case "f": toggleFullscreen(nil)
            case "n": if !event.isARepeat { nextChapter(nil) }
            case "p": if !event.isARepeat { previousChapter(nil) }
            case " ": move(true)
            default: super.keyDown(with: event)
            }
        }
    }
}
