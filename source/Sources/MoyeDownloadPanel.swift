import AppKit

final class MoyeDownloadPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let detail: ComicDetail
    private let destination: URL
    private let loader: MoyeChapterLoader
    private let titleField: NSTextField
    private let countField = label("", size: 15, color: .secondaryLabelColor)
    private let toggleButton = MoyeGlassButton(title: "取消全选", target: nil, action: nil)
    private let startButton = MoyeGlassButton(title: "开始下载", target: nil, action: nil)
    private let cancelButton = MoyeGlassButton(title: "关闭", target: nil, action: nil)
    private let list = NSScrollView()
    private let document = NSView()
    private let progress = NSProgressIndicator()
    private let status = NSTextField(wrappingLabelWithString: "请选择需要下载的章节，默认全部勾选。")
    private let chapterStatus = NSTextField(wrappingLabelWithString: "")
    private var checks: [NSButton] = []
    private var selected: [(Int, ComicChapter)] = []
    private var chapterIndex = 0
    private var pages: ComicPageSet?
    private var imageQueue: [(Int, URL)] = []
    private var active = 0
    private var processed = 0
    private var completedPages = 0
    private var failures = 0
    private var chapterFailures = 0
    private var scratch: URL?
    private var archive: URL?
    private var process: Process?
    private let ioQueue = DispatchQueue(label: "moye.download.files", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false
    private var requests: [MoyeImageRequest] = []
    private(set) var isRunning = false
    var onStatus: ((String, Bool) -> Void)?

    init(detail: ComicDetail, destination: URL, parent: NSView) {
        self.detail = detail; self.destination = destination
        loader = MoyeChapterLoader(parent: parent)
        titleField = NSTextField(wrappingLabelWithString: detail.title)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 740, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "章节下载"; panel.delegate = self; panel.isReleasedWhenClosed = false
        panel.appearance = MoyeAppearance.appearance
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 740, height: 600))
        content.wantsLayer = true; content.layer?.backgroundColor = color(0.95, 0.95, 0.98).cgColor
        panel.contentView = content
        titleField.font = .systemFont(ofSize: 22, weight: .bold); titleField.maximumNumberOfLines = 3
        titleField.frame = NSRect(x: 26, y: 491, width: 688, height: 82); content.addSubview(titleField)
        countField.frame = NSRect(x: 26, y: 451, width: 470, height: 24); content.addSubview(countField)
        toggleButton.frame = NSRect(x: 572, y: 443, width: 142, height: 40); toggleButton.target = self; toggleButton.action = #selector(toggleAll); toggleButton.identifier = NSUserInterfaceItemIdentifier("download-select-all"); content.addSubview(toggleButton)
        list.frame = NSRect(x: 26, y: 152, width: 688, height: 278)
        list.hasVerticalScroller = true; list.autohidesScrollers = true; list.drawsBackground = false; list.documentView = document
        document.frame = NSRect(x: 0, y: 0, width: 670, height: max(278, CGFloat(detail.chapters.count) * 42))
        for (index, chapter) in detail.chapters.enumerated() {
            let chapterTitle = chapter.title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let button = NSButton(checkboxWithTitle: chapterTitle.isEmpty ? "第 \(index + 1) 话" : chapterTitle, target: self, action: #selector(selectionChanged))
            button.font = .systemFont(ofSize: 16); button.state = .on
            button.cell?.wraps = false; button.cell?.usesSingleLineMode = true; button.cell?.lineBreakMode = .byTruncatingTail
            button.frame = NSRect(x: 12, y: document.frame.height - CGFloat(index + 1) * 42, width: 642, height: 38)
            button.tag = index; button.identifier = NSUserInterfaceItemIdentifier("download-chapter-\(index)"); button.toolTip = chapter.title
            document.addSubview(button); checks.append(button)
        }
        content.addSubview(list)
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 100
        progress.frame = NSRect(x: 26, y: 389, width: 688, height: 18); progress.isHidden = true; content.addSubview(progress)
        chapterStatus.font = .systemFont(ofSize: 17, weight: .semibold); chapterStatus.maximumNumberOfLines = 3
        chapterStatus.frame = NSRect(x: 26, y: 270, width: 688, height: 92); chapterStatus.isHidden = true; content.addSubview(chapterStatus)
        status.font = .systemFont(ofSize: 15); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 4
        status.frame = NSRect(x: 26, y: 83, width: 688, height: 58); status.identifier = NSUserInterfaceItemIdentifier("download-progress-status"); content.addSubview(status)
        startButton.frame = NSRect(x: 394, y: 22, width: 186, height: 46); startButton.target = self; startButton.action = #selector(start); startButton.identifier = NSUserInterfaceItemIdentifier("download-start"); content.addSubview(startButton)
        cancelButton.frame = NSRect(x: 592, y: 22, width: 122, height: 46); cancelButton.target = self; cancelButton.action = #selector(cancelOrClose); cancelButton.identifier = NSUserInterfaceItemIdentifier("download-cancel"); content.addSubview(cancelButton)
        updateSelection()
        list.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - list.contentSize.height)))
    }
    func show(relativeTo window: NSWindow?) {
        if let window { panel.setFrameOrigin(NSPoint(x: window.frame.midX - panel.frame.width / 2, y: window.frame.midY - panel.frame.height / 2)) }
        panel.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { panel.orderOut(nil); return false }
    @objc private func selectionChanged() { updateSelection() }
    private func updateSelection() {
        let count = checks.filter { $0.state == .on }.count
        countField.stringValue = "已选 \(count) / \(checks.count) 章"
        toggleButton.title = count == checks.count ? "取消全选" : "全选章节"
        startButton.isEnabled = count > 0
    }
    @objc private func toggleAll() { let all = checks.allSatisfy { $0.state == .on }; checks.forEach { $0.state = all ? .off : .on }; updateSelection() }
    @objc private func start() {
        guard !isRunning else { return }
        selected = checks.filter { $0.state == .on }.map { ($0.tag, detail.chapters[$0.tag]) }
        guard !selected.isEmpty else { return }
        do { scratch = try MoyeRuntimeData.makeTemporaryDirectory() } catch { status.stringValue = "无法创建下载目录：\(error.localizedDescription)"; return }
        lock.lock(); cancelled = false; lock.unlock()
        isRunning = true; chapterIndex = 0; failures = 0; chapterFailures = 0; completedPages = 0
        chapterStatus.isHidden = false
        list.isHidden = true; toggleButton.isHidden = true; startButton.isHidden = true; progress.isHidden = false
        cancelButton.title = "取消下载"; countField.stringValue = "已选择 \(selected.count) 章 · 保存为作品名称 ZIP"
        status.stringValue = "准备下载…"; nextChapter()
    }
    private func nextChapter() {
        guard isRunning else { return }
        guard chapterIndex < selected.count else { zip() ; return }
        progress.isIndeterminate = true; progress.startAnimation(nil)
        let chapter = selected[chapterIndex].1
        chapterStatus.stringValue = "正在读取第 \(chapterIndex + 1) / \(selected.count) 章\n\(chapter.title)"
        report("读取章节 · \(chapterIndex + 1)/\(selected.count)")
        loader.load(chapter) { [weak self] pages in
            guard let self, self.isRunning else { return }
            guard let pages else { self.chapterFailures += 1; self.chapterIndex += 1; self.nextChapter(); return }
            self.pages = pages; self.processed = 0; self.active = 0
            self.imageQueue = Array(pages.urls.enumerated())
            self.progress.stopAnimation(nil); self.progress.isIndeterminate = false
            self.updateProgress(); self.pump()
        }
    }
    private func pump() {
        guard isRunning, let pages, let scratch else { return }
        while active < 4, !imageQueue.isEmpty {
            let (index, url) = imageQueue.removeFirst(); active += 1
            let chapter = selected[chapterIndex]; let selectedChapter = chapterIndex
            let request = OnlineMainView.fetchImage(url: url, referer: chapter.1.url) { [weak self] data in
                guard let self else { return }
                self.ioQueue.async {
                    var ok = false
                    let image = autoreleasepool {
                        data.flatMap { ComicImageDecoder.downloadImage($0, imageURL: url, albumID: pages.albumID, scrambleID: pages.scrambleID) }
                    }
                    self.lock.lock()
                    if !self.cancelled, let image {
                        let name = String(format: "%03d_%04d.%@", chapter.0 + 1, index + 1, image.fileExtension)
                        do { try image.data.write(to: scratch.appendingPathComponent(name), options: .atomic); ok = true } catch {}
                    }
                    self.lock.unlock()
                    let success = ok
                    DispatchQueue.main.async {
                        guard self.isRunning, self.chapterIndex == selectedChapter else { return }
                        self.active -= 1; self.processed += 1
                        if success { self.completedPages += 1 } else { self.failures += 1 }
                        self.updateProgress()
                        if self.active == 0, self.imageQueue.isEmpty { self.requests.removeAll(); self.chapterIndex += 1; self.nextChapter() }
                        else { self.pump() }
                    }
                }
            }
            requests.append(request)
        }
    }
    private func updateProgress() {
        let total = pages?.urls.count ?? 0
        let fraction = Double(processed) / Double(max(1, total))
        let percent = 100 * (Double(chapterIndex) + fraction) / Double(max(1, selected.count))
        progress.doubleValue = percent
        chapterStatus.stringValue = "第 \(chapterIndex + 1) / \(selected.count) 章 · \(Int(percent))%\n本章 \(processed) / \(total) 页"
        let text = "已下载 \(completedPages) 页" + (failures > 0 ? " · \(failures) 页失败" : "")
        status.stringValue = text + "\n取消后会删除本次下载的临时图片及未完成压缩包。"
        report("\(Int(percent))% · \(text)")
    }
    private func report(_ text: String) { onStatus?(text, isRunning) }
    private func zip() {
        guard completedPages > 0, let scratch else { finish(message: "没有下载到可用页面，文件未保存。"); return }
        chapterStatus.stringValue = "正在打包 ZIP · \(completedPages) 页"
        report("正在打包 · \(completedPages) 页")
        progress.doubleValue = 100
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]).sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard files.count == completedPages, files.allSatisfy({ file in
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true &&
                    file.lastPathComponent.range(of: "^[0-9]+_[0-9]+\\.[A-Za-z0-9]+$", options: .regularExpression) != nil
            }) else { finish(message: "下载文件检查失败，压缩包未保存。"); return }
        } catch { finish(message: "无法读取下载文件：\(error.localizedDescription)"); return }
        let archive = MoyeRuntimeData.temporaryRoot.appendingPathComponent("Download-\(UUID().uuidString).zip"); self.archive = archive
        let process = Process(); self.process = process
        // This isolated directory has just been checked to contain only completed page files.
        // Pass the directory rather than thousands of filenames to avoid the OS argument limit.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); process.arguments = ["-q", "-X", "-r", archive.path, "."]; process.currentDirectoryURL = scratch
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in DispatchQueue.main.async {
            guard let self, self.isRunning else { try? FileManager.default.removeItem(at: archive); return }
            self.process = nil
            do {
                guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
                var target = self.destination; var suffix = 2
                while FileManager.default.fileExists(atPath: target.path) { target = self.destination.deletingLastPathComponent().appendingPathComponent(self.destination.deletingPathExtension().lastPathComponent + " (\(suffix)).zip"); suffix += 1 }
                try FileManager.default.moveItem(at: archive, to: target)
                let incomplete = self.failures + self.chapterFailures > 0
                let bytes = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                self.finish(message: (incomplete ? "部分下载完成" : "下载完成") + " · \(self.completedPages) 页 · \(size)" + (incomplete ? " · \(self.failures) 页、\(self.chapterFailures) 章失败" : ""))
                self.status.stringValue = "已保存：\(target.lastPathComponent)\n\(target.deletingLastPathComponent().path)"; self.status.toolTip = target.path
            } catch { self.finish(message: "保存失败：\(error.localizedDescription)") }
        } }
        do { try process.run() } catch { finish(message: "打包失败：\(error.localizedDescription)") }
    }
    private func finish(message: String) {
        isRunning = false; loader.cancel(); requests.removeAll()
        if let scratch { try? FileManager.default.removeItem(at: scratch) }; scratch = nil
        if let archive { try? FileManager.default.removeItem(at: archive) }; archive = nil
        chapterStatus.stringValue = message; status.stringValue = message
        cancelButton.title = "关闭"; countField.stringValue = "所选章节下载结果"
        report(message)
    }
    @objc private func cancelOrClose() { if isRunning { cancel() } else { panel.orderOut(nil) } }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        isRunning = false; loader.cancel(); requests.forEach { $0.cancel() }; requests.removeAll(); imageQueue.removeAll()
        if process?.isRunning == true { process?.terminate() }; process = nil
        let scratch = self.scratch, archive = self.archive; self.scratch = nil; self.archive = nil
        ioQueue.sync { if let scratch { try? FileManager.default.removeItem(at: scratch) }; if let archive { try? FileManager.default.removeItem(at: archive) } }
        progress.stopAnimation(nil); progress.isIndeterminate = false; progress.doubleValue = 0
        chapterStatus.stringValue = "下载已取消"; status.stringValue = "本次临时图片和未完成压缩包已清除。"
        cancelButton.title = "关闭"; report("下载已取消 · 已清除本次文件")
    }
    func dismiss() { panel.orderOut(nil) }
}
