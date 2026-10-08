import AppKit

private final class MoyeReaderDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class MoyePageSlot: NSView {
    let imageView = NSImageView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    var index: Int
    var pageClick: ((NSEvent) -> Void)?

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
    private enum Mode: String { case spread, vertical }
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
    private let modeControl = NSSegmentedControl(labels: ["横向双页", "竖向阅读"], trackingMode: .selectOne, target: nil, action: nil)
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
    private var pageFrames: [NSRect] = []
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
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = document
        stage.addSubview(scrollView)
        for index in 0..<totalPages {
            let slot = MoyePageSlot(index: index)
            slot.pageClick = { [weak self] event in self?.handlePageClick(event) }
            document.addSubview(slot)
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
        modeControl.selectedSegment = mode == .spread ? 0 : 1
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
        modeControl.frame = NSRect(x: right - 204, y: 10, width: 204, height: 36); right -= 216
        titleField.frame = NSRect(x: 104, y: 30, width: max(80, right - 110), height: 21)
        hintField.frame = NSRect(x: 104, y: 9, width: max(80, right - 110), height: 18)
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
        return max(0.05, size.width / max(1, size.height))
    }
    private func layoutSpread() {
        scrollView.isHidden = true
        let start = spreadStart
        let rightRatio = ratio(at: start)
        let leftRatio = start + 1 < totalPages ? ratio(at: start + 1) : rightRatio
        let gap: CGFloat = 10
        let height = max(1, min(stage.bounds.height - 24, (stage.bounds.width - 32 - gap) / (rightRatio + leftRatio)))
        let leftWidth = height * leftRatio, rightWidth = height * rightRatio
        let x = (stage.bounds.width - leftWidth - rightWidth - gap) / 2
        let y = (stage.bounds.height - height) / 2
        spreadSlots[0].frame = NSRect(x: x + leftWidth + gap, y: y, width: rightWidth, height: height)
        spreadSlots[1].frame = NSRect(x: x, y: y, width: leftWidth, height: height)
        for (offset, slot) in spreadSlots.enumerated() {
            slot.index = start + offset
            slot.isHidden = start + offset >= totalPages
            slot.imageView.setAccessibilityLabel("第 \(start + offset + 1) 页 · \(offset == 0 ? "右页" : "左页")")
            slot.imageView.identifier = NSUserInterfaceItemIdentifier("reader-page-\(start + offset + 1)")
        }
    }
    private func layoutVertical() {
        spreadSlots.forEach { $0.isHidden = true }
        scrollView.isHidden = false
        let oldFrames = pageFrames
        let oldOffset = scrollView.contentView.bounds.minY
        let anchor = oldFrames.indices.contains(currentPage) ? oldOffset - oldFrames[currentPage].minY : 0
        scrollView.frame = stage.bounds
        let width = scrollView.contentSize.width
        let pageWidth = max(1, min(1000, width - 32))
        pageFrames.removeAll(keepingCapacity: true)
        var y: CGFloat = 12
        for index in 0..<totalPages {
            let height = pageWidth / ratio(at: index)
            let rect = NSRect(x: (width - pageWidth) / 2, y: y, width: pageWidth, height: height)
            pageSlots[index].frame = rect
            pageFrames.append(rect)
            y += height + 12
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(scrollView.contentSize.height, y))
        if pageFrames.indices.contains(currentPage) {
            let offset = pageFrames[currentPage].minY + (scrollToCurrent ? 0 : anchor)
            let maxOffset = max(0, document.bounds.height - scrollView.contentSize.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(maxOffset, offset))))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        scrollToCurrent = false
    }

    private func visibleIndices() -> [Int] {
        if mode == .spread { return [spreadStart, spreadStart + 1].filter { $0 < totalPages } }
        let visible = scrollView.contentView.bounds
        return pageFrames.indices.filter { pageFrames[$0].intersects(visible) }
    }
    private func refreshVisiblePages() {
        guard totalPages > 0 else { return }
        let visible = visibleIndices()
        var wanted = visible
        if let first = visible.first, let last = visible.last {
            wanted += Array(max(0, first - 2)...min(totalPages - 1, last + 3))
        }
        let active = Set(wanted)
        let visibleSet = Set(visible)
        visibleImages = visibleImages.filter { visibleSet.contains($0.key) }
        prefetchAttempted.formIntersection(active)
        for index in visible where visibleImages[index] == nil {
            visibleImages[index] = cache.object(forKey: NSNumber(value: index))
        }
        // A quick page turn should prioritize the new visible spread over stale prefetches.
        let cancelled = loadQueue.filter { !active.contains($0) }
        loadQueue.removeAll { !active.contains($0) }
        cancelled.forEach { pendingLoads.remove($0) }
        if mode == .spread {
            for (offset, slot) in spreadSlots.enumerated() {
                let index = spreadStart + offset
                guard index < totalPages else { continue }
                slot.display(visibleImages[index], failed: failed.contains(index))
            }
        } else {
            for index in pageSlots.indices {
                let image = visibleImages[index]
                pageSlots[index].display(image, failed: failed.contains(index))
            }
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
        while activeLoads < 4, !loadQueue.isEmpty {
            let index = loadQueue.removeFirst()
            activeLoads += 1
            loader(index) { [weak self] image in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.activeLoads -= 1
                    self.pendingLoads.remove(index)
                    if let image {
                        let oldRatio = self.ratio(at: index)
                        self.sizes[index] = image.size
                        self.cache.setObject(image, forKey: NSNumber(value: index), cost: Int(max(1, image.size.width * image.size.height * 4)))
                        if self.visibleIndices().contains(index) { self.visibleImages[index] = image }
                        self.failed.remove(index)
                        if abs(oldRatio - self.ratio(at: index)) > 0.0001 { self.needsLayout = true }
                    } else { self.failed.insert(index) }
                    self.refreshVisiblePages()
                }
            }
        }
    }
    private func scrolled() {
        guard mode == .vertical, !isLayingOut, !pageFrames.isEmpty else { return }
        let mark = scrollView.contentView.bounds.minY + min(80, scrollView.contentSize.height * 0.15)
        let page = pageFrames.lastIndex(where: { $0.minY <= mark }) ?? 0
        if currentPage != page { currentPage = page; onPageChanged?(page); updateControls() }
        refreshVisiblePages()
    }
    private func updateControls() {
        let hasNextChapter = chapterIndex + 1 < chapterCount && onNextChapter != nil
        let hasPreviousChapter = chapterIndex > 0 && onPreviousChapter != nil
        let atChapterEnd = mode == .spread ? spreadStart + 2 >= totalPages : currentPage + 1 >= totalPages
        if mode == .spread {
            let start = spreadStart
            let end = min(start + 2, totalPages)
            let range = end == start + 1 ? "\(end)" : "\(start + 1)–\(end)"
            counterField.stringValue = totalPages > 0 ? "第 \(range) / \(totalPages) 页" : "没有可用页面"
            hintField.stringValue = "从右到左 · ← 下一组 · → 上一组 · V 切换 · F 全屏"
            nextButton.title = "下一组"
            previousButton.title = "上一组"
            nextButton.isEnabled = start + 2 < totalPages
            previousButton.isEnabled = start > 0
        } else {
            counterField.stringValue = totalPages > 0 ? "第 \(currentPage + 1) / \(totalPages) 页" : "没有可用页面"
            hintField.stringValue = "竖向连续阅读 · 滚动浏览 · V 切换双页 · F 全屏"
            nextButton.title = "下一页"
            previousButton.title = "上一页"
            nextButton.isEnabled = currentPage + 1 < totalPages
            previousButton.isEnabled = currentPage > 0
        }
        if atChapterEnd && hasNextChapter {
            nextButton.title = "下一章"
            nextButton.isEnabled = true
            nextButton.toolTip = "本章已到最后一页，继续翻页进入下一章"
        } else { nextButton.toolTip = mode == .spread ? "下一组 · ← 或空格" : "下一页 · ← 或空格" }
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
        modeControl.selectedSegment = mode == .spread ? 0 : 1
    }
    private func move(_ forward: Bool) {
        guard !chapterLoading else { return }
        let next: Int
        if mode == .spread { next = spreadStart + (forward ? 2 : -2) }
        else { next = currentPage + (forward ? 1 : -1) }
        if forward, next >= totalPages { nextChapter(nil); return }
        guard next >= 0, next < totalPages else { return }
        currentPage = next
        scrollToCurrent = true
        onPageChanged?(next)
        updateControls()
        needsLayout = true
        window?.makeFirstResponder(self)
    }
    private func handlePageClick(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        if chromeHidden { revealTemporarily(); return }
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
        if let control = sender as? NSSegmentedControl { mode = control.selectedSegment == 0 ? .spread : .vertical }
        else { mode = mode == .spread ? .vertical : .spread }
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
        return ["visible": visible, "displayed": displayed, "retained": visibleImages.keys.sorted(), "activeLoads": activeLoads, "queuedLoads": loadQueue.count, "mode": mode.rawValue, "chromeHidden": chromeHidden, "temporarilyRevealed": temporarilyRevealed]
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
