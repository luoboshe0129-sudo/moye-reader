import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

private func moyeDiagnostic(_ event: String) {
#if MOYE_DIAGNOSTICS
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MoyeReader-verification.log")
    let line = Data("\(Date().timeIntervalSince1970) \(event)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(line)
        try? handle.close()
    } else { try? line.write(to: url) }
#endif
}

private enum ComicSessionStore {
    private static func fileURL(host: String) -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("MoyeShelf/SiteSessions", isDirectory: true).appendingPathComponent(host + ".plist")
    }

    static func save(_ cookies: [HTTPCookie], host: String) {
        guard let url = fileURL(host: host) else { return }
        let selected = cookies.filter {
            let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return (domain == host || host.hasSuffix("." + domain)) && !["password", "pwd", "pass"].contains($0.name.lowercased())
        }
        guard selected.contains(where: { $0.name == "AVS" }) else { return }
        let records = selected.map { cookie -> [String: Any] in
            var record: [String: Any] = [:]
            for (key, value) in cookie.properties ?? [:] {
                if let value = value as? URL { record[key.rawValue] = value.absoluteString }
                else { record[key.rawValue] = value }
            }
            return record
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try PropertyListSerialization.data(fromPropertyList: records, format: .binary, options: 0)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            moyeDiagnostic("session.saved.cookies=\(selected.count)")
        } catch { moyeDiagnostic("session.save.failed") }
    }

    static func restore(host: String, into store: WKHTTPCookieStore, completion: @escaping () -> Void) {
        guard let url = fileURL(host: host), let data = try? Data(contentsOf: url),
              let records = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [[String: Any]] else { completion(); return }
        let group = DispatchGroup()
        for record in records {
            let properties = Dictionary(uniqueKeysWithValues: record.map { (HTTPCookiePropertyKey($0.key), $0.value) })
            guard let cookie = HTTPCookie(properties: properties), cookie.expiresDate.map({ $0 > Date() }) ?? true else { continue }
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            guard domain == host || host.hasSuffix("." + domain) else { continue }
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }
}

private struct ComicResult: Identifiable {
    let id: String
    let title: String
    let author: String
    let metadata: String
    let coverURL: URL?
    let url: URL
}

struct ComicChapter: Identifiable {
    let id: String
    let title: String
    let url: URL
}

struct ComicDetail {
    let title: String
    let author: String
    let description: String
    let coverURL: URL?
    let chapters: [ComicChapter]
}

struct ComicPageSet {
    let urls: [URL]
    let albumID: Int
    let scrambleID: Int
}

private enum ComicSiteRoute: String, CaseIterable {
    case internationalVIP = "18comic.vip"
    case internationalINK = "18comic.ink"
    case southeastAsiaOne = "jmcomic-zzz.one"
    case southeastAsiaORG = "jmcomic-zzz.org"

    static let preferenceKey = "MoyeShelf.SiteRoute"
    static var selected: ComicSiteRoute {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(ComicSiteRoute.init(rawValue:)) ?? .internationalVIP
    }

    var rootURL: URL { URL(string: "https://\(rawValue)")! }
    var displayTitle: String {
        switch self {
        case .internationalVIP: return "国际线路 · 18comic.vip"
        case .internationalINK: return "国际线路 · 18comic.ink"
        case .southeastAsiaOne: return "东南亚线路 · jmcomic-zzz.one"
        case .southeastAsiaORG: return "东南亚线路 · jmcomic-zzz.org"
        }
    }
}

private final class WeakComicScriptHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

final class OnlineMainView: NSView, WKNavigationDelegate, WKScriptMessageHandler, NSTextFieldDelegate {
    private weak var owner: MoyeWindowController?
    private var siteRoute = ComicSiteRoute.selected
    private var rootURL: URL { siteRoute.rootURL }
    private let engine: WKWebView
    private let scriptHandler = WeakComicScriptHandler()
    private let titleLabel = NSTextField(labelWithString: "墨夜阅读器")
    private let searchField = MoyeCenteredTextField()
    private let searchIcon = NSImageView(image: symbol("magnifyingglass", size: 21) ?? NSImage())
    private let clearSearchButton: NSButton
    private let searchProgress = NSProgressIndicator()
    private let searchPanel = MoyeSearchBar(frame: .zero)
    private let downloadLocationCard = glassView(radius: 20, material: .hudWindow)
    private let downloadLocationTitle = label("下载位置", size: 15, weight: .semibold)
    private let downloadLocationLabel = label("", size: 13, color: .secondaryLabelColor)
    private let chooseDownloadFolderButton: NSButton
    private let openDownloadFolderButton: NSButton
    private let searchButton: NSButton
    private let loginButton: NSButton
    private let themeButton: NSButton
    private let statusLabel = NSTextField(labelWithString: "输入作品名、作者名或 JM 车号开始搜索")
    private let resultCountLabel = NSTextField(labelWithString: "漫画作品")
    private let columnsLabel = NSTextField(labelWithString: "每行显示")
    private let columnButtons: [NSButton]
    private let dayRankingButton: NSButton
    private let monthRankingButton: NSButton
    private let rangeRankingButton: NSButton
    private let monthRangeCard = MoyeMonthRangeControls(frame: .zero)
    private let viewSortButton: NSButton
    private let likeSortButton: NSButton
    private var rankingButtons: [NSButton] { [dayRankingButton, monthRankingButton, rangeRankingButton, viewSortButton, likeSortButton] }
    private var rankingPeriod = "t"
    private var orderBy = "mv"
    private var browsingRanking = true
    private var activeSearchQuery = ""
    private var rankingTitle: String { rankingPeriod == "range" ? "月份热榜" : rankingPeriod == "m" ? "每月热看" : "每日热看" }
    private var orderTitle: String { orderBy == "tf" ? "点赞数" : "观看数" }
    private let backButton: NSButton
    private let downloadButton: NSButton
    private let scrollView = NSScrollView()
    private let canvas = ComicResultsCanvas()
    private let background = NSVisualEffectView()
    private let headerCard = glassView(radius: 24, material: .hudWindow)
    private var detailCanvas: ComicDetailCanvas?
    private var readerView: MoyeComicReaderView?
    private var currentResults: [ComicResult] = []
    private var publicationDates: [String: String] = [:]
    private var selectedResult: ComicResult?
    private var selectedDetail: ComicDetail?
    private var autoReadAlbumID: String?
    private var selectedPageSet: ComicPageSet?
    private var loginPanel: NativeLoginPanel?
    private var accountPanel: MoyeAccountPanel?
    private var authenticatedUsername: String?
    private var loginAttemptID = UUID()
    private var loginDeadline: Date?
    private var loginEngine: WKWebView?
    private var loginPending: LoginRequest = .idle
    private var sessionVerifier: WKWebView?
    private var sessionVerificationID = UUID()
    private var sessionVerificationTimeout: DispatchWorkItem?
    private var downloadNavigationID = UUID()
    private var resetScrollToTop = false
    private var columns = UserDefaults.standard.integer(forKey: "MoyeShelf.ComicColumns")
    private var currentPage = 1
    private var listingURL: URL?
    private var listingGeneration = UUID()
    private var pending: PendingRequest = .idle
    private var closing = false
    private var isClosing: Bool { closing }
    private var downloadPanel: MoyeDownloadPanel?
    private let downloadProgressButton = MoyeGlassButton(title: "下载进度", target: nil, action: nil)
    private let collapseButton = MoyeGlassButton(title: "收起筛选", target: nil, action: nil)
    private var functionsCollapsed = false
    private var autoCompact = false
    private var isArranging = false
    private var scrollObserver: NSObjectProtocol?
    private var bookLoader: MoyeChapterLoader?
    private var chapterNavigationID = UUID()
#if MOYE_DIAGNOSTICS
    private var scrollTransitions: [[String: Any]] = []
#endif

    private enum PendingRequest {
        case idle
        case search(String)
        case monthRanking(UUID)
        case detail(ComicResult)
        case photo(ComicChapter, ComicResult)
    }

    private enum LoginRequest {
        case idle
        case page(String, String)
        case outcome(String)
    }

    init(frame: NSRect, owner: MoyeWindowController, initialQuery: String? = nil) {
        self.owner = owner
        if columns == 0 { columns = 2 }
        let config = Self.webConfiguration()
        engine = WKWebView(frame: .zero, configuration: config)
        searchButton = iconButton("搜索", symbolName: "arrow.right", target: nil, action: #selector(search(_:)), identifier: "comic-search-submit")
        clearSearchButton = iconButton("", symbolName: "xmark", target: nil, action: #selector(clearSearch(_:)), identifier: "comic-search-clear")
        chooseDownloadFolderButton = iconButton("更改位置", symbolName: "folder.badge.gearshape", target: nil, action: #selector(chooseDownloadFolder(_:)), identifier: "download-location-change")
        openDownloadFolderButton = iconButton("打开文件夹", symbolName: "folder", target: nil, action: #selector(openDownloadFolder(_:)), identifier: "download-location-open")
        loginButton = iconButton("登录账号", symbolName: "person.crop.circle", target: nil, action: #selector(showLogin(_:)))
        themeButton = iconButton(MoyeAppearance.isDark ? "深色模式" : "浅色模式", symbolName: MoyeAppearance.isDark ? "moon.stars.fill" : "sun.max.fill", target: nil, action: #selector(toggleTheme(_:)))
        themeButton.toolTip = "当前为" + (MoyeAppearance.isDark ? "深色模式" : "浅色模式") + "，点击切换"
        backButton = iconButton("返回结果", symbolName: "chevron.left", target: nil, action: #selector(goBack(_:)))
        downloadButton = iconButton("下载作品", symbolName: "arrow.down.to.line", target: nil, action: #selector(downloadAlbum(_:)))
        dayRankingButton = iconButton("每日热看", symbolName: "flame", target: nil, action: #selector(chooseRanking(_:)), identifier: "ranking-t")
        rangeRankingButton = iconButton("月份榜单", symbolName: "calendar.badge.clock", target: nil, action: #selector(chooseRanking(_:)), identifier: "ranking-range")
        monthRankingButton = iconButton("每月热看", symbolName: "calendar", target: nil, action: #selector(chooseRanking(_:)), identifier: "ranking-m")
        viewSortButton = iconButton("观看数", symbolName: "eye", target: nil, action: #selector(chooseOrder(_:)), identifier: "order-mv")
        likeSortButton = iconButton("点赞数", symbolName: "heart", target: nil, action: #selector(chooseOrder(_:)), identifier: "order-tf")
        columnButtons = (1...3).map { number in
            let button = MoyeGlassButton(frame: .zero)
            button.title = "\(number) 列"
            button.action = #selector(setColumns(_:))
            button.identifier = NSUserInterfaceItemIdentifier("columns-\(number)")
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 14, weight: .semibold)
            return button
        }
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = color(0.93, 0.94, 0.98).cgColor
        background.material = .underWindowBackground
        background.blendingMode = .withinWindow
        background.state = .active
        addSubview(background)
        background.addSubview(GlowOrb(frame: .zero, fill: color(0.70, 0.77, 1.0, 0.34), blur: 52))
        background.addSubview(GlowOrb(frame: .zero, fill: color(0.98, 0.66, 0.61, 0.25), blur: 50))
        background.addSubview(headerCard)
        headerCard.blendingMode = .withinWindow
        headerCard.material = .sidebar
        headerCard.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 31, weight: .bold)
        titleLabel.textColor = color(0.16, 0.16, 0.20)
        headerCard.addSubview(titleLabel)

        loginButton.target = self
        themeButton.target = self
        searchButton.target = self
        clearSearchButton.target = self
        chooseDownloadFolderButton.target = self
        openDownloadFolderButton.target = self
        backButton.target = self
        downloadButton.target = self
        for button in columnButtons { button.target = self }
        monthRangeCard.onApply = { [weak self] in self?.loadMonthRangeRanking() }
        monthRangeCard.onCancel = { [weak self] in self?.cancelMonthRanking() }
        addSubview(monthRangeCard)
        for button in rankingButtons { button.target = self; button.font = .systemFont(ofSize: 14, weight: .semibold); addSubview(button) }
        loginButton.font = .systemFont(ofSize: 15, weight: .semibold)
        themeButton.font = .systemFont(ofSize: 14, weight: .semibold)
        headerCard.addSubview(loginButton)
        headerCard.addSubview(themeButton)

        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.font = .systemFont(ofSize: 18, weight: .medium)
        searchField.textColor = .labelColor
        searchField.placeholderString = "作品名、作者名或 JM 车号"
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.identifier = NSUserInterfaceItemIdentifier("comic-search-input")
        searchField.setAccessibilityLabel("搜索作品名、作者名或 JM 车号")
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.imageScaling = .scaleProportionallyDown
        clearSearchButton.toolTip = "清空搜索"
        clearSearchButton.layer?.backgroundColor = NSColor.clear.cgColor
        clearSearchButton.layer?.borderWidth = 0
        searchButton.contentTintColor = .white
        searchButton.layer?.backgroundColor = color(0.46, 0.34, 0.66).cgColor
        searchButton.layer?.cornerRadius = 17
        searchProgress.style = .spinning
        searchProgress.controlSize = .small
        searchProgress.isDisplayedWhenStopped = false
        searchPanel.addSubview(searchIcon)
        searchPanel.addSubview(searchField)
        searchPanel.addSubview(clearSearchButton)
        searchPanel.addSubview(searchButton)
        searchPanel.addSubview(searchProgress)
        addSubview(searchPanel)

        downloadLocationCard.addSubview(downloadLocationTitle)
        downloadLocationCard.blendingMode = .withinWindow
        downloadLocationCard.material = .sidebar
        downloadLocationCard.layer?.masksToBounds = true
        downloadLocationLabel.lineBreakMode = .byTruncatingMiddle
        downloadLocationLabel.setAccessibilityLabel("当前下载位置")
        downloadLocationCard.addSubview(downloadLocationLabel)
        downloadLocationCard.addSubview(chooseDownloadFolderButton)
        downloadLocationCard.addSubview(openDownloadFolderButton)
        addSubview(downloadLocationCard)
        updateDownloadLocation()

        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.textColor = color(0.38, 0.39, 0.45)
        resultCountLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        resultCountLabel.textColor = color(0.24, 0.24, 0.29)
        columnsLabel.font = .systemFont(ofSize: 14, weight: .medium)
        columnsLabel.textColor = color(0.42, 0.42, 0.47)
        addSubview(statusLabel)
        addSubview(resultCountLabel)
        addSubview(columnsLabel)
        addSubview(backButton)
        addSubview(downloadButton)
        for button in columnButtons { addSubview(button) }

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = canvas
        canvas.delegate = self
        addSubview(scrollView)
        collapseButton.target = self
        collapseButton.action = #selector(toggleFunctions(_:))
        collapseButton.identifier = NSUserInterfaceItemIdentifier("listing-collapse")
        addSubview(collapseButton)
        downloadProgressButton.target = self
        downloadProgressButton.action = #selector(showDownloadProgress(_:))
        downloadProgressButton.identifier = NSUserInterfaceItemIdentifier("download-progress-open")
        downloadProgressButton.isHidden = true
        downloadLocationCard.addSubview(downloadProgressButton)
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in self?.resultsScrolled() }

        engine.navigationDelegate = self
        scriptHandler.delegate = self
        engine.configuration.userContentController.add(scriptHandler, name: "moyeSearch")
        engine.configuration.userContentController.add(scriptHandler, name: "moyeMonthProgress")
        engine.configuration.userContentController.add(scriptHandler, name: "moyePhoto")
        engine.configuration.userContentController.add(scriptHandler, name: "moyeDetail")
        engine.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        engine.alphaValue = 0.001
        engine.isHidden = true
        engine.setAccessibilityElement(false)
        engine.setAccessibilityHidden(true)
        engine.frame = NSRect(x: -4000, y: -4000, width: 1440, height: 1100)
        addSubview(engine, positioned: .below, relativeTo: background)

        updateColumnButtons()
        showResultsState()
        searchField.stringValue = initialQuery ?? ""
        clearSearchButton.isHidden = searchField.stringValue.isEmpty
        restoreSiteSession()
#if MOYE_DIAGNOSTICS
        pollVerification()
#endif
        if initialQuery == nil { DispatchQueue.main.async { [weak self] in self?.loadRanking() } }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var searchQuery: String { searchField.stringValue }

    func prepareToClose() {
        closing = true
        downloadPanel?.cancel(); downloadPanel?.dismiss(); downloadPanel = nil
        bookLoader?.cancel(); bookLoader = nil
        MoyeReadingCache.shared.requestedChapters.removeAll()
        cancelMonthRanking()
        pending = .idle
        listingGeneration = UUID()
        downloadNavigationID = UUID()
        engine.stopLoading()
        endLoginRequest()
        endSessionVerification()
        loginPanel?.dismiss()
        accountPanel?.dismiss()
        readerView?.removeFromSuperview()
        readerView = nil
        selectedPageSet = nil
        currentResults.removeAll()
        publicationDates.removeAll()
        canvas.setResults([], columns: columns)
    }

    func reloadSearchAfterAppearanceChange(from source: OnlineMainView) {
        monthRangeCard.copySelection(from: source.monthRangeCard)
        rankingPeriod = source.rankingPeriod
        orderBy = source.orderBy
        browsingRanking = source.browsingRanking
        activeSearchQuery = source.activeSearchQuery
        currentPage = source.currentPage
        currentResults = source.currentResults
        downloadPanel = source.downloadPanel
        source.downloadPanel = nil
        if let panel = downloadPanel { configureDownloadStatus(panel); downloadProgressButton.isHidden = false }
        publicationDates = source.publicationDates
        canvas.setResults(currentResults, columns: columns)
        statusLabel.stringValue = source.statusLabel.stringValue
        showResultsState()
        if source.isLoadingListing {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.browsingRanking { self.loadRanking() }
                else { self.performSearch(self.activeSearchQuery, page: self.currentPage) }
            }
        }
    }

    static func webConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let controller = WKUserContentController()
        let css = """
        .adsbygoogle, [id*='ad-container' i], [class*='advertisement' i], [class*='ad-banner' i], iframe[src*='doubleclick' i], iframe[src*='adservice' i], .popunder, .popup-ad { display:none !important; visibility:hidden !important; }
        """
        let script = """
        (()=>{const css=\(String(reflecting: css));const install=()=>{const root=document.documentElement;if(!root)return false;if(!document.getElementById('moye-clean-view')){const s=document.createElement('style');s.id='moye-clean-view';s.textContent=css;(document.head||root).appendChild(s)}return true};if(!install()){const wait=new MutationObserver(()=>{if(install())wait.disconnect()});wait.observe(document,{childList:true,subtree:true})}else{new MutationObserver(install).observe(document.documentElement,{childList:true,subtree:true})}window.alert=(message)=>{try{window.webkit.messageHandlers.moyeLoginAlert.postMessage(String(message||''))}catch(_){}};window.open=()=>null;})();
        """
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let searchNotifier = """
        (()=>{if(!location.pathname.startsWith('/search/photos')&&!location.pathname.startsWith('/albums'))return;try{const results=\(searchScript);window.webkit.messageHandlers.moyeSearch.postMessage({results,sourceURL:location.href})}catch(e){}})();
        """
        controller.addUserScript(WKUserScript(source: searchNotifier, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let photoNotifier = """
        (()=>{if(!location.pathname.startsWith('/photo/'))return;try{const pages=\(photoScript);if(pages.urls.length)window.webkit.messageHandlers.moyePhoto.postMessage(pages)}catch(_){}})();
        """
        controller.addUserScript(WKUserScript(source: photoNotifier, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let detailNotifier = """
        (()=>{if(!location.pathname.startsWith('/album/'))return;try{const detail=\(detailScript);if(detail.chapters.length)window.webkit.messageHandlers.moyeDetail.postMessage(detail)}catch(_){}})();
        """
        controller.addUserScript(WKUserScript(source: detailNotifier, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController = controller
        let rules = """
        [
          {"trigger":{"url-filter":".*","if-domain":["doubleclick.net","*.doubleclick.net","googlesyndication.com","*.googlesyndication.com","googleadservices.com","*.googleadservices.com","popads.net","*.popads.net","popcash.net","*.popcash.net","exoclick.com","*.exoclick.com","juicyads.com","*.juicyads.com","trafficjunky.net","*.trafficjunky.net"]},"action":{"type":"block"}}
        ]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "moye-ad-filter", encodedContentRuleList: rules) { list, _ in
            if let list { controller.add(list) }
        }
        return configuration
    }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        engine.configuration.userContentController.removeScriptMessageHandler(forName: "moyeSearch")
        engine.configuration.userContentController.removeScriptMessageHandler(forName: "moyePhoto")
    }

    override func layout() {
        super.layout()
        if let readerView { readerView.frame = bounds; writeVerification(); return }
        isArranging = true
        defer { isArranging = false }
        let documentView = scrollView.documentView
        let oldDistance = documentView?.isFlipped == true ? max(0, scrollView.contentView.bounds.minY) : max(0, (documentView?.frame.height ?? 0) - scrollView.contentSize.height - scrollView.contentView.bounds.minY)
        background.frame = bounds
        let orbs = background.subviews.compactMap { $0 as? GlowOrb }
        if orbs.indices.contains(0) { orbs[0].frame = NSRect(x: -135, y: bounds.height - 350, width: 360, height: 360) }
        if orbs.indices.contains(1) { orbs[1].frame = NSRect(x: bounds.width - 260, y: -130, width: 410, height: 410) }
        let left: CGFloat = 28, right = bounds.width - 28, contentWidth = right - left
        let listing = backButton.isHidden
        let compact = listing && autoCompact
        headerCard.isHidden = compact
        searchPanel.isHidden = compact
        statusLabel.isHidden = compact
        collapseButton.isHidden = !listing
        collapseButton.title = compact ? "显示搜索与筛选" : (functionsCollapsed ? "展开筛选" : "收起筛选")
        headerCard.frame = NSRect(x: left, y: bounds.height - 100, width: contentWidth, height: 76)
        titleLabel.frame = NSRect(x: 24, y: 20, width: 340, height: 38)
        loginButton.frame = NSRect(x: contentWidth - 166, y: 16, width: 146, height: 44)
        themeButton.frame = NSRect(x: contentWidth - 324, y: 16, width: 146, height: 44)
        searchPanel.frame = NSRect(x: left, y: bounds.height - 192, width: contentWidth, height: 74)
        searchIcon.frame = NSRect(x: 23, y: 25, width: 24, height: 24)
        searchButton.frame = NSRect(x: contentWidth - 126, y: 12, width: 112, height: 50)
        clearSearchButton.frame = NSRect(x: contentWidth - 174, y: 19, width: 36, height: 36)
        searchField.frame = NSRect(x: 62, y: 12, width: max(120, contentWidth - 246), height: 50)
        searchProgress.frame = NSRect(x: contentWidth - 202, y: 29, width: 16, height: 16)
        statusLabel.frame = NSRect(x: left + 4, y: bounds.height - 223, width: contentWidth - 8, height: 22)
        var resultTop = bounds.height - 318
        if listing {
            let summaryY = bounds.height - (compact ? 60 : 260)
            resultCountLabel.frame = NSRect(x: left + 4, y: summaryY + 5, width: contentWidth - 200, height: 26)
            collapseButton.frame = NSRect(x: right - 176, y: summaryY, width: 176, height: 38)
            let filtersVisible = !compact && !functionsCollapsed
            rankingButtons.forEach { $0.isHidden = !filtersVisible }
            columnsLabel.isHidden = !filtersVisible
            columnButtons.forEach { $0.isHidden = !filtersVisible }
            monthRangeCard.isHidden = !filtersVisible || !(browsingRanking && rankingPeriod == "range")
            let toolbarY = summaryY - 54
            // Sorting filters lead the row; time ranges follow them.
            viewSortButton.frame = NSRect(x: left, y: toolbarY, width: 106, height: 42)
            likeSortButton.frame = NSRect(x: left + 116, y: toolbarY, width: 106, height: 42)
            dayRankingButton.frame = NSRect(x: left + 242, y: toolbarY, width: 114, height: 42)
            monthRankingButton.frame = NSRect(x: left + 366, y: toolbarY, width: 114, height: 42)
            rangeRankingButton.frame = NSRect(x: left + 490, y: toolbarY, width: 120, height: 42)
            columnsLabel.frame = NSRect(x: right - 340, y: toolbarY + 10, width: 78, height: 22)
            for (index, button) in columnButtons.enumerated() { button.frame = NSRect(x: right - 252 + CGFloat(index) * 88, y: toolbarY, width: 76, height: 42) }
            resultTop = compact ? bounds.height - MoyeListingScrollPolicy.compactHeaderHeight : (filtersVisible ? toolbarY - 18 : summaryY - 12)
            if !monthRangeCard.isHidden { monthRangeCard.frame = NSRect(x: left, y: toolbarY - 78, width: contentWidth, height: 60); resultTop -= 78 }
        } else {
            let toolbarY = bounds.height - 278
            backButton.frame = NSRect(x: left, y: toolbarY, width: 138, height: 42)
            downloadButton.frame = NSRect(x: left + 150, y: toolbarY, width: 148, height: 42)
            resultCountLabel.frame = NSRect(x: left + 316, y: toolbarY + 7, width: contentWidth - 330, height: 28)
            resultTop = toolbarY - 18
        }
        downloadLocationCard.frame = NSRect(x: left, y: 18, width: contentWidth, height: 66)
        downloadLocationTitle.frame = NSRect(x: 22, y: 35, width: 130, height: 22)
        downloadLocationLabel.frame = NSRect(x: 22, y: 10, width: max(150, contentWidth - (downloadProgressButton.isHidden ? 338 : 570)), height: 22)
        downloadProgressButton.frame = NSRect(x: contentWidth - 540, y: 12, width: 226, height: 42)
        chooseDownloadFolderButton.frame = NSRect(x: contentWidth - 294, y: 12, width: 128, height: 42)
        openDownloadFolderButton.frame = NSRect(x: contentWidth - 154, y: 12, width: 134, height: 42)
        scrollView.frame = NSRect(x: left, y: MoyeListingScrollPolicy.footerTop, width: contentWidth, height: max(1, resultTop - MoyeListingScrollPolicy.footerTop))
        let width = scrollView.contentSize.width
        if scrollView.documentView === canvas { canvas.frame = NSRect(x: 0, y: 0, width: width, height: max(scrollView.contentSize.height, canvas.requiredHeight(for: width))); canvas.layoutSubtreeIfNeeded() }
        else if let detailCanvas { detailCanvas.frame = NSRect(x: 0, y: 0, width: width, height: max(scrollView.contentSize.height, detailCanvas.requiredHeight(for: width))); detailCanvas.layoutSubtreeIfNeeded() }
        let top = max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentSize.height)
        let distance = resetScrollToTop ? 0 : min(oldDistance, top)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollView.documentView?.isFlipped == true ? distance : top - distance))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        resetScrollToTop = false
        writeVerification()
    }

    private func resultsScrolled() {
        guard !isArranging, readerView == nil, scrollView.documentView === canvas else { return }
        let next = MoyeListingScrollPolicy.compactState(current: autoCompact,
                                                       offset: scrollView.contentView.bounds.minY,
                                                       contentHeight: canvas.requiredHeight(for: scrollView.contentSize.width),
                                                       viewportHeight: scrollView.contentSize.height,
                                                       windowHeight: bounds.height)
        guard next != autoCompact else { return }
#if MOYE_DIAGNOSTICS
        scrollTransitions.append(["compact": next, "offset": scrollView.contentView.bounds.minY, "time": Date().timeIntervalSince1970])
        if scrollTransitions.count > 100 { scrollTransitions.removeFirst() }
#endif
        autoCompact = next
        needsLayout = true
    }
    @objc private func toggleFunctions(_ sender: Any?) {
        if autoCompact { autoCompact = false; resetScrollToTop = true; functionsCollapsed = false }
        else { functionsCollapsed.toggle() }
        needsLayout = true
    }

#if MOYE_DIAGNOSTICS
    private func pollVerification() {
        guard !closing else { return }
        writeVerification()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.pollVerification() }
    }
#endif
    private func writeVerification() {
#if MOYE_DIAGNOSTICS
        var state: [String: Any] = ["columns": columns, "offset": scrollView.contentView.bounds.minY, "compact": autoCompact, "filtersCollapsed": functionsCollapsed, "results": currentResults.count, "cache": MoyeReadingCache.shared.snapshot, "downloadRunning": downloadPanel?.isRunning ?? false]
        state["resultMetadata"] = currentResults.map { ["id": $0.id, "metadata": $0.metadata] }
        state["scrollTransitions"] = scrollTransitions
        state["scrollGeometry"] = ["windowHeight": bounds.height, "viewportHeight": scrollView.contentSize.height, "naturalHeight": canvas.requiredHeight(for: scrollView.contentSize.width), "compactViewportHeight": MoyeListingScrollPolicy.compactViewportHeight(windowHeight: bounds.height), "canvasHeight": canvas.frame.height]
#if MOYE_READER_DIAGNOSTICS
        if let readerView { state["reader"] = readerView.verificationSnapshot() }
#endif
        try? FileManager.default.createDirectory(at: MoyeRuntimeData.temporaryRoot, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: MoyeRuntimeData.temporaryRoot.appendingPathComponent("Verification.json"), options: .atomic)
        }
#endif
    }

    @objc private func search(_ sender: Any?) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            statusLabel.stringValue = "请输入作品名、作者名或 JM 车号。"
            return
        }
        searchPanel.acknowledge()
        setSearchBusy(true)
        currentPage = 1
        if let id = Self.albumID(from: query) {
            let item = ComicResult(id: id, title: "JM \(id)", author: "", metadata: "", coverURL: nil, url: rootURL.appendingPathComponent("album/\(id)"))
            loadDetail(item)
            return
        }
        browsingRanking = false
        activeSearchQuery = query
        performSearch(query, page: currentPage)
    }

    private func performSearch(_ query: String, page: Int) {
        cancelMonthRanking()
        var components = URLComponents(url: rootURL, resolvingAgainstBaseURL: false)!
        components.path = "/search/photos"
        components.queryItems = [
            URLQueryItem(name: "search_query", value: query),
            URLQueryItem(name: "main_tag", value: "0"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "o", value: orderBy),
            URLQueryItem(name: "t", value: "a")
        ]
        guard let url = components.url else { return }
        listingURL = url
        listingGeneration = UUID()
        pending = .search(query)
        statusLabel.stringValue = "正在搜索“\(query)” · 第 \(page) 页…"
        showResultsState()
        engine.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 35))
    }

    @objc private func chooseRanking(_ sender: NSButton) {
        cancelMonthRanking()
        let id = sender.identifier?.rawValue ?? "ranking-t"
        rankingPeriod = id.replacingOccurrences(of: "ranking-", with: "")
        if rankingPeriod == "range" { orderBy = "tf" }
        browsingRanking = true
        searchField.stringValue = ""
        clearSearchButton.isHidden = true
        currentPage = 1
        if rankingPeriod == "range" {
            pending = .idle
            engine.stopLoading()
            currentResults = []
            canvas.setResults([], columns: columns)
            showResultsState()
            setSearchBusy(false)
            statusLabel.stringValue = "选择上架月份，再点击“查看前 30”。"
        } else { loadRanking() }
    }

    @objc private func chooseOrder(_ sender: NSButton) {
        orderBy = sender.identifier?.rawValue == "order-tf" ? "tf" : "mv"
        currentPage = 1
        if browsingRanking { loadRanking() }
        else { setSearchBusy(true); performSearch(activeSearchQuery, page: 1) }
    }

    private func loadRanking() {
        if rankingPeriod == "range" { loadMonthRangeRanking(); return }
        cancelMonthRanking()
        var components = URLComponents(url: rootURL, resolvingAgainstBaseURL: false)!
        components.path = "/albums"
        components.queryItems = [URLQueryItem(name: "page", value: String(currentPage)), URLQueryItem(name: "o", value: orderBy), URLQueryItem(name: "t", value: rankingPeriod)]
        guard let url = components.url else { return }
        listingURL = url
        listingGeneration = UUID()
        pending = .search("")
        setSearchBusy(true)
        statusLabel.stringValue = "正在载入" + rankingTitle + " · 按" + orderTitle + "排序…"
        showResultsState()
        engine.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 35))
    }

    private func updateRankingButtons() {
        viewSortButton.isEnabled = !(browsingRanking && rankingPeriod == "range")
        for button in rankingButtons {
            let id = button.identifier?.rawValue ?? ""
            let selected = id == "order-" + orderBy || (browsingRanking && id == "ranking-" + rankingPeriod)
            button.contentTintColor = selected ? .white : .labelColor
            button.layer?.backgroundColor = (selected ? color(0.49, 0.37, 0.68) : surfaceTint(0.48)).cgColor
        }
    }

    private func listingMatches(_ url: URL?) -> Bool {
        guard let url, let expected = listingURL, url.host == expected.host,
              url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == expected.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { return false }
        let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let wanted = URLComponents(url: expected, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return wanted.allSatisfy { item in parameters.contains { $0.name == item.name && $0.value == item.value } }
    }

    private static func albumID(from query: String) -> String? {
        let expression = try? NSRegularExpression(pattern: "^\\s*(?:JM[-\\s]?)?([0-9]{3,})\\s*$", options: [.caseInsensitive])
        let range = NSRange(query.startIndex..<query.endIndex, in: query)
        guard let match = expression?.firstMatch(in: query, range: range), let numberRange = Range(match.range(at: 1), in: query) else { return nil }
        return String(query[numberRange])
    }

    func controlTextDidBeginEditing(_ notification: Notification) { searchPanel.setFocused(true) }
    func controlTextDidChange(_ notification: Notification) { clearSearchButton.isHidden = searchField.stringValue.isEmpty }
    func controlTextDidEndEditing(_ notification: Notification) {
        searchPanel.setFocused(false)
        if let movement = notification.userInfo?["NSTextMovement"] as? Int, movement == NSReturnTextMovement { search(nil) }
    }

    @objc private func clearSearch(_ sender: Any?) {
        searchField.stringValue = ""
        clearSearchButton.isHidden = true
        window?.makeFirstResponder(searchField)
    }

    private func setSearchBusy(_ busy: Bool) {
        searchPanel.setBusy(busy)
        searchButton.title = busy ? "搜索中" : "搜索"
        if busy { searchProgress.startAnimation(nil) } else { searchProgress.stopAnimation(nil) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "moyeMonthProgress" {
            guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == rootURL.host,
                  case .monthRanking(let run) = pending, let value = message.body as? [String: Any],
                  value["runID"] as? String == run.uuidString else { return }
            for pair in value["dates"] as? [[String: String]] ?? [] {
                if let id = pair["id"], let date = pair["date"] { publicationDates[id] = date }
            }
            statusLabel.stringValue = "正在核对上架月份 · 已检查 \(value["checked"] as? Int ?? 0) 部 · 符合 \(min(30, value["matched"] as? Int ?? 0)) / 30 部"
            return
        }
        if message.name == "moyeDetail" {
            guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == rootURL.host,
                  message.webView === engine,
                  case .detail(let result) = pending,
                  let path = message.frameInfo.request.url?.path,
                  path.split(separator: "/").prefix(2).joined(separator: "/") == "album/\(result.id)" else { return }
            acceptDetail(message.body, result: result)
            return
        }
        if message.name == "moyeSessionReady" {
            guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == rootURL.host,
                  let verifier = sessionVerifier, message.webView === verifier,
                  let response = message.body as? [String: Any] else { return }
            let ok = response["ok"] as? Bool == true
            moyeDiagnostic("session.document.ready.confirmed=\(ok),userPage=\(response["userPage"] as? Bool ?? false),account=\(response["account"] as? Bool ?? false),loginForm=\(response["hasLoginForm"] as? Bool ?? false)")
            if ok { confirmRestoredSession(verifier) }
            else if response["hasLoginForm"] as? Bool == true { expireRestoredSession() }
            return
        }
        if message.name == "moyeLoginDocumentReady" {
            guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == rootURL.host,
                  message.webView === loginEngine else { return }
            loginDocumentReady()
            return
        }
        if message.name == "moyePhoto" {
            guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == rootURL.host,
                  message.webView === engine, case .photo(let chapter, _) = pending,
                  let path = message.frameInfo.request.url?.path,
                  path.split(separator: "/").prefix(2).joined(separator: "/") == "photo/\(chapter.id)" else { return }
            _ = acceptPhotoPages(message.body)
            return
        }
        guard message.name == "moyeSearch", message.frameInfo.isMainFrame, case .search = pending else { return }
        let payload = message.body as? [String: Any]
        guard let source = payload?["sourceURL"] as? String, listingMatches(URL(string: source)) else { return }
        if browsingRanking && rankingPeriod == "range" { beginMonthScan(); return }
        pending = .idle
        acceptSearchResults(payload?["results"])
        engine.stopLoading()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === sessionVerifier {
            verifyRestoredSession(webView)
            return
        }
        if webView === loginEngine { loginDocumentReady(); return }
        guard webView === engine else { return }
        switch pending {
        case .search:
            guard listingMatches(webView.url) else { return }
            if browsingRanking && rankingPeriod == "range" { beginMonthScan(); return }
            let generation = listingGeneration
            statusLabel.stringValue = "正在整理漫画结果…"
            webView.evaluateJavaScript(Self.searchScript) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self, self.listingGeneration == generation, case .search = self.pending else { return }
                    if let error { self.showNetworkError(error); return }
                    self.acceptSearchResults(result)
                }
            }
        case .detail(let result):
            webView.evaluateJavaScript(Self.detailScript) { [weak self] value, error in
                DispatchQueue.main.async {
                    guard let self, case .detail(let current) = self.pending, current.id == result.id else { return }
                    if let error { self.showNetworkError(error); return }
                    self.acceptDetail(value, result: result)
                }
            }
        case .photo(let chapter, _):
            let run = chapterNavigationID
            webView.evaluateJavaScript(Self.photoScript) { [weak self] value, error in
                DispatchQueue.main.async {
                    guard let self, self.chapterNavigationID == run, case .photo(let current, _) = self.pending, current.id == chapter.id else { return }
                    if let error { self.failChapterLoading(error.localizedDescription); return }
                    guard self.acceptPhotoPages(value) else {
                        self.failChapterLoading("这一章暂时无法加载，请再次点击章节按钮重试。")
                        return
                    }
                }
            }
        case .idle, .monthRanking:
            break
        }
    }

    private func acceptDetail(_ value: Any?, result: ComicResult) {
        setSearchBusy(false)
        pending = .idle
        engine.stopLoading()
        let dict = value as? [String: Any] ?? [:]
        let chapters = (dict["chapters"] as? [[String: String]] ?? []).enumerated().compactMap { index, item -> ComicChapter? in
            guard let id = item["id"], !id.isEmpty else { return nil }
            let url = sitePageURL(item["url"] ?? "/photo/\(id)", fallback: rootURL.appendingPathComponent("photo/\(id)"))
            // Site chapter links include a separate "latest" badge and line breaks.
            // Keep only the chapter name, as a single line in every app surface.
            let badgeDelimiters = CharacterSet(charactersIn: "[]()【】（）")
            let name = (item["title"] ?? "").cleanedHTMLText
                .split(whereSeparator: { $0.isWhitespace })
                .filter { String($0).trimmingCharacters(in: badgeDelimiters) != "最新" }
                .joined(separator: " ")
            return ComicChapter(id: id, title: name.isEmpty ? "第 \(index + 1) 话" : name, url: url)
        }
        let detail = ComicDetail(title: (dict["title"] as? String)?.cleanedHTMLText ?? result.title,
                                 author: (dict["author"] as? String)?.cleanedHTMLText ?? result.author,
                                 description: (dict["description"] as? String)?.cleanedHTMLText ?? "",
                                 coverURL: (dict["cover"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) } ?? result.coverURL,
                                 chapters: chapters)
        selectedDetail = detail
        showDetailState(detail)
        if autoReadAlbumID == result.id {
            autoReadAlbumID = nil
            if let chapter = detail.chapters.first { loadChapter(chapter) }
            else { statusLabel.stringValue = "这部作品暂时没有可阅读的章节。" }
        }
    }

    @discardableResult private func acceptPhotoPages(_ value: Any?) -> Bool {
        let dict = value as? [String: Any] ?? [:]
        let urls = (dict["urls"] as? [String] ?? []).compactMap(URL.init(string:))
        guard !urls.isEmpty else { return false }
        let pages = ComicPageSet(urls: urls, albumID: (dict["albumID"] as? Int) ?? Int(selectedResult?.id ?? "0") ?? 0, scrambleID: (dict["scrambleID"] as? Int) ?? 0)
        switch pending {
        case .photo(let chapter, _):
            pending = .idle
            engine.stopLoading()
            selectedPageSet = pages
            showReader(chapter: chapter, pageSet: pages)
            return true
        default: return false
        }
    }

    private func acceptSearchResults(_ value: Any?) {
        setSearchBusy(false)
        let records = (value as? [[String: Any]] ?? []).compactMap { dict -> ComicResult? in
            guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
            let fallback = URL(string: "/album/\(id)", relativeTo: rootURL)!.absoluteURL
            return ComicResult(id: id,
                               title: (dict["title"] as? String)?.cleanedHTMLText ?? "JM \(id)",
                               author: (dict["author"] as? String)?.cleanedHTMLText ?? "",
                               metadata: MoyeComicMetadata.summary(record: dict),
                               coverURL: (dict["cover"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
                               url: sitePageURL(dict["url"] as? String ?? fallback.absoluteString, fallback: fallback))
        }
        pending = .idle
        currentResults = records
        moyeDiagnostic("listing.period=\(browsingRanking ? rankingPeriod : "search"),order=\(orderBy),count=\(records.count),first=\(records.prefix(5).map(\.id).joined(separator: ","))")
        canvas.setResults(records, columns: columns)
        autoCompact = false
        resetScrollToTop = true
        let sectionTitle = browsingRanking ? rankingTitle : "搜索结果"
        resultCountLabel.stringValue = sectionTitle + " · \(records.count) 部"
        statusLabel.stringValue = records.isEmpty ? "站点暂未返回可显示的作品，请稍后重试。" : sectionTitle + " · 按" + orderTitle + "排序 · \(records.count) 部漫画"
        resultCountLabel.toolTip = resultCountLabel.stringValue
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func sitePageURL(_ value: String, fallback: URL) -> URL {
        guard let url = URL(string: value, relativeTo: rootURL)?.absoluteURL,
              let host = url.host?.lowercased(),
              ComicSiteRoute.allCases.contains(where: { $0.rawValue.lowercased() == host }) else { return fallback }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = rootURL.host
        return components?.url ?? url
    }

    private var isLoadingListing: Bool {
        switch pending { case .search, .monthRanking: return true; default: return false }
    }

    private func cancelMonthRanking() {
        if monthRangeCard.isBusy {
            if case .monthRanking = pending { engine.evaluateJavaScript("window.moyeMonthAbort?.abort()", completionHandler: nil) }
            else { engine.stopLoading() }
            pending = .idle
            listingGeneration = UUID()
            setSearchBusy(false)
            statusLabel.stringValue = "月份榜单已取消。"
        }
        monthRangeCard.setBusy(false)
    }

    private func loadMonthRangeRanking() {
        cancelMonthRanking()
        guard monthRangeCard.startMonth <= monthRangeCard.endMonth else {
            statusLabel.stringValue = "开始月份不能晚于结束月份。"
            return
        }
        orderBy = "tf"
        browsingRanking = true
        rankingPeriod = "range"
        currentResults = []
        canvas.setResults([], columns: columns)
        currentPage = 1
        let currentMonth = MoyeMonthRangeControls.currentMonth
        let period = monthRangeCard.startMonth == currentMonth && monthRangeCard.endMonth == currentMonth ? "m" : "a"
        var components = URLComponents(url: rootURL, resolvingAgainstBaseURL: false)!
        components.path = "/albums"
        components.queryItems = [URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "o", value: "tf"), URLQueryItem(name: "t", value: period)]
        guard let url = components.url else { return }
        listingURL = url
        listingGeneration = UUID()
        pending = .search("")
        showResultsState()
        monthRangeCard.setBusy(true)
        setSearchBusy(true)
        statusLabel.stringValue = "正在载入 \(monthRangeCard.rangeTitle) · 核对上架月份与爱心数…"
        engine.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 35))
    }

    private func beginMonthScan() {
        guard case .search = pending else { return }
        let run = UUID()
        pending = .monthRanking(run)
        let selectionTitle = monthRangeCard.rangeTitle
        let code = "const readCards=(document,location)=>" + Self.searchScript + ";" + Self.monthScanScript
        engine.callAsyncJavaScript(code, arguments: ["startMonth": monthRangeCard.startMonth, "endMonth": monthRangeCard.endMonth, "runID": run.uuidString, "knownDates": publicationDates], in: nil, in: .page) { [weak self] outcome in
            guard let self, case .monthRanking(let current) = self.pending, current == run else { return }
            self.pending = .idle
            self.monthRangeCard.setBusy(false)
            self.setSearchBusy(false)
            switch outcome {
            case .success(let object):
                guard let value = object as? [String: Any] else { self.statusLabel.stringValue = "月份榜单未返回有效结果，请重试。"; return }
                if let error = value["error"] as? String {
                    self.statusLabel.stringValue = "月份榜单尚未完成：" + error + "。请稍后重试。"
                    self.resultCountLabel.stringValue = "月份热榜 · 未完成"
                    return
                }
                self.acceptSearchResults(value["records"])
#if MOYE_DIAGNOSTICS
                let evidence = (value["records"] as? [[String: Any]] ?? []).map { record in
                    ["id": record["id"] ?? "", "published": record["published"] ?? "", "metadata": MoyeComicMetadata.summary(record: record), "url": record["url"] ?? ""]
                }
                if let data = try? JSONSerialization.data(withJSONObject: ["start": self.monthRangeCard.startMonth, "end": self.monthRangeCard.endMonth, "checked": value["checked"] ?? 0, "records": evidence], options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Moye-month-verification.json"))
                }
#endif
                let checked = value["checked"] as? Int ?? 0
                let exhausted = value["exhausted"] as? Bool == true
                self.resultCountLabel.stringValue = "月份热榜 · \(self.currentResults.count) 部"
                self.statusLabel.stringValue = selectionTitle + " · 按当前爱心数排序 · " + (exhausted && self.currentResults.count < 30 ? "站点可检索范围内 \(self.currentResults.count) 部" : "前 \(self.currentResults.count) 部")
                moyeDiagnostic("month-ranking.complete.checked=\(checked),count=\(self.currentResults.count),start=\(self.monthRangeCard.startMonth),end=\(self.monthRangeCard.endMonth)")
            case .failure:
                self.statusLabel.stringValue = "月份榜单读取中断，请检查网络后重试。"
            }
        }
    }

    // Browse the site's actual descending-like pages; every higher-ranked candidate is
    // checked before selecting the first 30 matches. Fetched HTML stays inert and uncached.
    private static let monthScanScript = #"""
    window.moyeMonthAbort?.abort();
    const controller = new AbortController(); window.moyeMonthAbort = controller;
    const matches=[], seen=new Set(), dates={...knownDates}; let checked=0, exhausted=false;
    const clean=x=>(x||'').replace(/\s+/g,' ').trim();
    const parseHTML=html=>{
      const doc=new DOMParser().parseFromString(html,'text/html');
      for(const match of html.matchAll(/(?:const|let|var)\s+html\s*=\s*base64DecodeUtf8\("([^"]+)"\)/g)){
        try { const bytes=Uint8Array.from(atob(match[1]),c=>c.charCodeAt(0)); const decoded=new TextDecoder().decode(bytes); doc.body.insertAdjacentHTML('beforeend',decoded); }catch(_){}
      }
      return doc;
    };
    const fetchDoc=async url=>{
      if(new URL(url,location.href).origin!==location.origin)throw Error('站点链接异常');
      for(let attempt=0;attempt<2;attempt++){
        const timeout=new AbortController(), timer=setTimeout(()=>timeout.abort(),25000);
        const abort=()=>timeout.abort(); controller.signal.addEventListener('abort',abort,{once:true});
        try {
          const response=await fetch(url,{credentials:'same-origin',cache:'no-store',signal:timeout.signal});
          if(!response.ok)throw Error('站点返回 HTTP '+response.status);
          return parseHTML(await response.text());
        }catch(error){ if(controller.signal.aborted||attempt===1)throw error; }
        finally{ clearTimeout(timer); controller.signal.removeEventListener('abort',abort); }
      }
    };
    const progress=batch=>window.webkit.messageHandlers.moyeMonthProgress.postMessage({runID,checked,matched:matches.length,dates:batch.map(item=>({id:item.id,date:dates[item.id]}))});
    let doc=document, pageURL=location.href;
    try {
      while(!controller.signal.aborted){
        const items=readCards(doc,{href:pageURL}).filter(item=>!seen.has(item.id));
        if(!items.length){exhausted=true;break;}
        for(let start=0;start<items.length;start+=4){
          const batch=items.slice(start,start+4);
          const inspected=await Promise.all(batch.map(async item=>{
            seen.add(item.id);
            let date=dates[item.id];
            if(!date){
              const detail=await fetchDoc(item.url);
              const text=detail.body?.textContent||'';
              date=detail.querySelector('[itemprop="datePublished"]')?.getAttribute('content')||text.match(/上架日期\s*[:：]\s*(\d{4}-\d{2}-\d{2})/)?.[1];
            }
            if(!date||!/^\d{4}-\d{2}-\d{2}$/.test(date))throw Error('部分作品上架日期无法核对');
            dates[item.id]=date;
            const month=date.slice(0,7);
            if(month<startMonth||month>endMonth)return null;
            const likesText=clean(item.likesText);
            if(!/^\d[\d,.]*\s*[KMW万萬]?$/i.test(likesText))throw Error('部分作品爱心数无法核对');
            return {...item,published:date,likesText};
          }));
          checked+=batch.length; matches.push(...inspected.filter(Boolean)); progress(batch);
          if(matches.length>=30)break;
        }
        if(matches.length>=30)break;
        const pageNumber=Number(new URL(pageURL).searchParams.get('page')||1);
        const next=[...doc.querySelectorAll('.pagination a')].map(a=>new URL(a.getAttribute('href')||'',pageURL)).find(u=>Number(u.searchParams.get('page'))===pageNumber+1&&u.pathname==='/albums'&&u.searchParams.get('o')==='tf');
        if(!next){exhausted=true;break;}
        pageURL=next.href; doc=await fetchDoc(pageURL);
      }
      if(controller.signal.aborted)throw Error('已取消');
      return {records:matches.slice(0,30),checked,exhausted};
    }catch(error){ return {error:controller.signal.aborted?'已取消':String(error.message||'站点连接中断'),checked}; }
    finally { controller.abort(); }
    """#

    private static let searchScript = """
    (()=>{
      const out=[],seen=new Set();
      const clean=x=>(x||'').replace(/\\s+/g,' ').trim();
      for(const a of document.querySelectorAll('a[href*="/album/"]')){
        const href=new URL(a.getAttribute('href')||a.href||'',location.href).href,m=href.match(/\\/album\\/(\\d+)/);
        if(!m||seen.has(m[1])||a.closest('nav,header,.navbar'))continue;
        const img=a.querySelector('img');
        if(!img)continue;
        const raw=img.getAttribute('data-original')||img.getAttribute('data-src')||img.getAttribute('data-lazy-src')||img.currentSrc||img.src||'';
        if(!raw||raw.startsWith('data:'))continue;
        const cover=new URL(raw,location.href).href;
        if(!/\\/media\\/albums\\//i.test(cover))continue;
        let card=a.closest('.list-col');
        if(!card){
          card=a.parentElement;
          for(let i=0;i<3&&card?.parentElement;i++){
            if(card.querySelector('.video-title,.album-title'))break;
            const parent=card.parentElement;
            const ids=new Set([...parent.querySelectorAll('a[href*="/album/"]')].map(x=>(x.href.match(/\\/album\\/(\\d+)/)||[])[1]).filter(Boolean));
            if(ids.size>1)break;
            card=parent;
          }
        }
        if(!card)continue;
        const title=clean(card.querySelector('.video-title,.album-title')?.textContent)||clean(img.alt)||clean(a.title)||('JM '+m[1]);
        const authors=[...card.querySelectorAll('a[href*="main_tag=2"]')].map(x=>clean(x.textContent)).filter(Boolean);
        const author=[...new Set(authors)].join('、');
        const tags=[...card.querySelectorAll('.tags .tag,.tags a')].map(x=>clean(x.textContent)).filter(Boolean);
        const likes=clean(card.querySelector('[id^="love_likes_"],.label-loveicon')?.textContent);
        seen.add(m[1]);out.push({id:m[1],title,author,tags,likesText:likes,cover,url:href});
      }
      return out;
    })()
    """

    private static let detailScript = """
    (()=>{const title=document.querySelector('#book-name')?.innerText||document.querySelector('h1')?.innerText||document.title||'';const author=document.querySelector('.author')?.innerText||document.querySelector('[class*=author]')?.innerText||'';const description=document.querySelector('meta[property="og:description"]')?.content||document.querySelector('.description')?.innerText||'';const imgs=[...document.querySelectorAll('a[href*="/photo/"] img,#album_photo,.album-thumb img,.thumb-overlay img,[class*=cover] img')];const src=i=>i&&(i.getAttribute('data-original')||i.getAttribute('data-src')||i.getAttribute('data-lazy-src')||i.currentSrc||i.src)||'';const actual=imgs.find(i=>{const u=src(i);return u&&!u.startsWith('data:')&&!/(logo|avatar|blank|banner|ad\\.)/i.test(u)});const social=document.querySelector('meta[property="og:image"]')?.content||'';const cover=src(actual)||(social&&!/(logo|avatar|blank|banner)/i.test(social)?social:'');const chapters=[];const seen=new Set();for(const a of document.querySelectorAll('a[href*="/photo/"]')){const m=(a.href||'').match(/\\/photo\\/(\\d+)/);if(!m||seen.has(m[1]))continue;seen.add(m[1]);chapters.push({id:m[1],title:(a.innerText||a.textContent||'').trim(),url:a.href})}return {title,author,description,cover:cover?new URL(cover,location.href).href:'',chapters};})()
    """

    static let photoScript = """
    (()=>{const imgs=[...document.querySelectorAll('.scramble-page img, img[id^="album_photo"]')];let raw=imgs.map(i=>i.dataset.original||i.dataset.src||i.src||'').filter(x=>x&&!x.includes('blank')&&!x.startsWith('data:'));let arr=window.page_arr;if(typeof arr==='string'){try{arr=JSON.parse(arr)}catch(e){}}const first=raw[0]||document.querySelector('[data-original*="/media/photos/"]')?.getAttribute('data-original')||'';if(Array.isArray(arr)&&arr.length&&first){const u=new URL(first,location.href);const base=u.href.slice(0,u.href.lastIndexOf('/')+1);const suffix=u.search;raw=arr.map(x=>base+String(x)+suffix)}const urls=[...new Set(raw.map(x=>new URL(x,location.href).href))];return {urls,albumID:Number(window.aid||new URL(location.href).pathname.match(/photo\\/(\\d+)/)?.[1]||0),scrambleID:Number(window.scramble_id||0)};})()
    """

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === sessionVerifier { endSessionVerification() }
        else if webView === loginEngine {
            if (error as NSError).code != NSURLErrorCancelled { loginFailed(loginConnectionMessage(error)) }
        } else if webView === engine { navigationFailed(error) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === sessionVerifier { endSessionVerification() }
        else if webView === loginEngine {
            if (error as NSError).code != NSURLErrorCancelled { loginFailed(loginConnectionMessage(error)) }
        } else if webView === engine { navigationFailed(error) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse {
            moyeDiagnostic("navigation.http=\(response.statusCode),path=\(response.url?.path ?? "")")
            if response.statusCode >= 400 {
                if webView === loginEngine {
                    decisionHandler(.cancel)
                    loginFailed("\(rootURL.host ?? "站点") 返回 HTTP \(response.statusCode)；登录服务暂时不可用。")
                    return
                } else if webView === sessionVerifier {
                    decisionHandler(.cancel)
                    endSessionVerification()
                    return
                }
            }
        }
        decisionHandler(.allow)
    }

    private func navigationFailed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        showNetworkError(error)
    }

    private func loginConnectionMessage(_ error: Error) -> String {
        let networkError = error as NSError
        let host = (networkError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host ?? rootURL.host ?? "禁漫天堂"
        let reason: String
        switch networkError.code {
        case NSURLErrorNotConnectedToInternet: reason = "当前没有网络连接"
        case NSURLErrorCannotFindHost: reason = "找不到站点域名，请检查入口或 DNS"
        case NSURLErrorCannotConnectToHost: reason = "站点拒绝连接或当前线路不可达"
        case NSURLErrorTimedOut: reason = "连接超时，当前线路可能不可用"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted: reason = "安全连接失败，请检查网络或站点证书"
        default: reason = networkError.localizedDescription
        }
        return "无法连接 \(host)（\(networkError.code)）：\(reason)"
    }

    private func showNetworkError(_ error: Error) {
        if case .photo = pending {
            failChapterLoading((error as NSError).code == NSURLErrorNotConnectedToInternet ? "当前没有网络连接，请稍后重试。" : "章节打开失败，请再次点击章节按钮重试。")
            return
        }
        cancelMonthRanking()
        setSearchBusy(false)
        let message = (error as NSError).code == -1009 ? "当前没有网络连接。" : "禁漫天堂没有返回数据，可能是站点验证、网络限制或入口暂不可用。"
        statusLabel.stringValue = message
        if currentResults.isEmpty { resultCountLabel.stringValue = "暂时无法连接" }
    }

    private func loadDetail(_ result: ComicResult, startReading: Bool = false) {
        cancelMonthRanking()
        setSearchBusy(true)
        selectedResult = result
        autoReadAlbumID = startReading ? result.id : nil
        pending = .detail(result)
        statusLabel.stringValue = "正在读取作品信息与章节…"
        engine.load(URLRequest(url: result.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 35))
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in
            guard let self, case .detail(let current) = self.pending, current.id == result.id else { return }
            self.pending = .idle
            self.engine.stopLoading()
            self.setSearchBusy(false)
            self.statusLabel.stringValue = "作品信息读取超时，请点击搜索重试。"
        }
    }

    fileprivate func select(_ result: ComicResult) { loadDetail(result) }
    fileprivate func read(_ result: ComicResult) { loadDetail(result, startReading: true) }

    private func showResultsState() {
        backButton.isHidden = true
        downloadButton.isHidden = true
        themeButton.isHidden = false
        columnsLabel.isHidden = false
        for button in columnButtons { button.isHidden = false }
        if scrollView.documentView !== canvas { scrollView.documentView = canvas }
        resultCountLabel.stringValue = (browsingRanking ? rankingTitle : "搜索结果") + (currentResults.isEmpty ? "" : " · \(currentResults.count) 部")
        for button in rankingButtons { button.isHidden = false }
        monthRangeCard.isHidden = !(browsingRanking && rankingPeriod == "range")
        updateRankingButtons()
        needsLayout = true
    }

    private func showDetailState(_ detail: ComicDetail) {
        let item = selectedResult
        let newCanvas = ComicDetailCanvas(result: item, detail: detail)
        newCanvas.chapterAction = { [weak self] chapter in self?.loadChapter(chapter) }
        newCanvas.coverAction = { [weak self] in
            guard let chapter = detail.chapters.first else { return }
            self?.loadChapter(chapter)
        }
        detailCanvas = newCanvas
        scrollView.documentView = newCanvas
        backButton.isHidden = false
        downloadButton.isHidden = false
        themeButton.isHidden = true
        monthRangeCard.isHidden = true
        for button in rankingButtons { button.isHidden = true }
        columnsLabel.isHidden = true
        for button in columnButtons { button.isHidden = true }
        resultCountLabel.stringValue = "作品详情"
        statusLabel.stringValue = "作品信息已载入 · \(detail.chapters.count) 个章节"
        autoCompact = false
        resetScrollToTop = true
        needsLayout = true
    }

    private func loadChapter(_ chapter: ComicChapter) {
        guard let result = selectedResult else { return }
        chapterNavigationID = UUID()
        if let pages = MoyeReadingCache.shared.chapters[chapter.url.absoluteString] {
            pending = .idle; engine.stopLoading()
            selectedPageSet = pages; showReader(chapter: chapter, pageSet: pages); return
        }
        pending = .photo(chapter, result)
        readerView?.showChapterLoading(chapter.title)
        statusLabel.stringValue = "正在打开《\(chapter.title)》…"
        engine.load(URLRequest(url: chapter.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 35))
        let run = chapterNavigationID
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in
            guard let self, self.chapterNavigationID == run, case .photo(let current, _) = self.pending, current.id == chapter.id else { return }
            self.failChapterLoading("章节读取超时，请再次点击章节按钮重试。")
        }
    }

    private func failChapterLoading(_ message: String) {
        chapterNavigationID = UUID()
        pending = .idle
        engine.stopLoading()
        statusLabel.stringValue = message
        readerView?.finishChapterLoading(message: message)
    }

    private func showReader(chapter: ComicChapter, pageSet: ComicPageSet) {
        let chromeHidden = readerView?.hidesChrome ?? false
        readerView?.removeFromSuperview()
        MoyeReadingCache.shared.chapters[chapter.url.absoluteString] = pageSet
        let chapters = selectedDetail?.chapters ?? [chapter]
        let chapterIndex = chapters.firstIndex(where: { $0.id == chapter.id || $0.url == chapter.url }) ?? 0
        let reader = MoyeComicReaderView(title: selectedDetail?.title ?? chapter.title, pageCount: pageSet.urls.count, chapterIndex: chapterIndex, chapterCount: chapters.count, chapterTitle: chapter.title, chromeInitiallyHidden: chromeHidden) { index, completion in
            guard pageSet.urls.indices.contains(index) else { completion(nil); return }
            Self.cachePage(pageSet, index: index, chapter: chapter, priority: true, completion: completion)
        }
        reader.onBack = { [weak self] in self?.goBack(nil) }
        reader.onDownload = { [weak self] in self?.downloadAlbum(nil) }
        reader.onProgress = { [weak self] in self?.showDownloadProgress(nil) }
        if chapterIndex + 1 < chapters.count {
            reader.onNextChapter = { [weak self, weak reader] in
                guard let self, let reader, self.readerView === reader else { return }
                self.loadChapter(chapters[chapterIndex + 1])
            }
        }
        if chapterIndex > 0 {
            reader.onPreviousChapter = { [weak self, weak reader] in
                guard let self, let reader, self.readerView === reader else { return }
                self.loadChapter(chapters[chapterIndex - 1])
            }
        }
        reader.updateDownloadStatus(downloadPanel?.isRunning == true)
        // Start with the visible spread, then fetch every remaining page and chapter.
        for index in pageSet.urls.indices { Self.cachePage(pageSet, index: index, chapter: chapter, priority: false) }
        preloadBook(excluding: chapter)
        readerView = reader
        for view in [background, searchPanel, downloadLocationCard, statusLabel, resultCountLabel, columnsLabel, scrollView, backButton, downloadButton] { view.isHidden = true }
        columnButtons.forEach { $0.isHidden = true }
        monthRangeCard.isHidden = true
        rankingButtons.forEach { $0.isHidden = true }
        collapseButton.isHidden = true
        reader.frame = bounds
        reader.autoresizingMask = [.width, .height]
        addSubview(reader)
        window?.makeFirstResponder(reader)
        needsLayout = true
    }

    private static func cachePage(_ pages: ComicPageSet, index: Int, chapter: ComicChapter, priority: Bool, completion: ((NSImage?) -> Void)? = nil) {
        let url = pages.urls[index]
        let key = "\(pages.albumID):\(pages.scrambleID):" + url.absoluteString
        MoyeReadingCache.shared.request(key: key, priority: priority, load: { done in
            Self.fetchImage(url: url, referer: chapter.url) { data in
                done(data.flatMap { ComicImageDecoder.decode($0, imageURL: url, albumID: pages.albumID, scrambleID: pages.scrambleID) ?? $0 })
            }
        }, completion: completion)
    }
    private func preloadBook(excluding current: ComicChapter) {
        guard let detail = selectedDetail else { return }
        if bookLoader == nil { bookLoader = MoyeChapterLoader(parent: self) }
        for chapter in detail.chapters where chapter.url != current.url {
            if let pages = MoyeReadingCache.shared.chapters[chapter.url.absoluteString] {
                for index in pages.urls.indices { Self.cachePage(pages, index: index, chapter: chapter, priority: false) }
            } else if MoyeReadingCache.shared.requestedChapters.insert(chapter.url.absoluteString).inserted {
                bookLoader?.load(chapter) { pages in
                    MoyeReadingCache.shared.requestedChapters.remove(chapter.url.absoluteString)
                    guard let pages else { return }
                    MoyeReadingCache.shared.chapters[chapter.url.absoluteString] = pages
                    for index in pages.urls.indices { Self.cachePage(pages, index: index, chapter: chapter, priority: false) }
                }
            }
        }
    }

    @objc private func goBack(_ sender: Any?) {
        if let readerView {
            chapterNavigationID = UUID()
            pending = .idle
            engine.stopLoading()
            readerView.removeFromSuperview()
            self.readerView = nil
            for view in [background, searchPanel, downloadLocationCard, statusLabel, resultCountLabel, scrollView] { view.isHidden = false }
            if let selectedDetail { showDetailState(selectedDetail) }
            else { showResultsState() }
        } else {
            detailCanvas = nil
            pending = .idle
            showResultsState()
            statusLabel.stringValue = currentResults.isEmpty ? "输入作品名、作者名或 JM 车号开始搜索" : "搜索结果只显示漫画作品，不加载站点网页版面。"
        }
        window?.makeFirstResponder(self)
        needsLayout = true
    }

    @objc private func setColumns(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue.split(separator: "-").last.flatMap({ Int($0) }) else { return }
        columns = value
        UserDefaults.standard.set(value, forKey: "MoyeShelf.ComicColumns")
        updateColumnButtons()
        autoCompact = false
        canvas.setColumns(value)
        resetScrollToTop = true
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func updateColumnButtons() {
        for button in columnButtons {
            let isSelected = button.identifier?.rawValue == "columns-\(columns)"
            button.contentTintColor = isSelected ? .white : color(0.30, 0.31, 0.36)
            button.wantsLayer = true
            button.layer?.cornerRadius = 12
            button.layer?.backgroundColor = (isSelected ? color(0.49, 0.37, 0.68) : surfaceTint(0.57)).cgColor
        }
    }

    @objc private func toggleTheme(_ sender: Any?) { owner?.toggleAppearance(from: self) }

    @objc private func showLogin(_ sender: Any?) {
        if let username = authenticatedUsername { showAccount(username: username) }
        else { showLoginForm() }
    }

    private func showAccount(username: String) {
        let panel = MoyeAccountPanel(username: username, site: siteRoute.rawValue) { [weak self] in self?.showLoginForm() }
        accountPanel = panel
        panel.show()
    }

    private func showLoginForm() {
        endSessionVerification()
        if let loginPanel { loginPanel.show(); return }
        let panel = NativeLoginPanel(initialRoute: siteRoute, onRouteChange: { [weak self] route in
            self?.setSiteRoute(route)
        }, onSubmit: { [weak self] username, password, route in
            self?.setSiteRoute(route)
            self?.beginSiteLogin(username: username, password: password)
        }, onClose: { [weak self] in
            self?.endLoginRequest()
            self?.loginPanel = nil
        })
        loginPanel = panel
        panel.show()
    }

    private func setSiteRoute(_ route: ComicSiteRoute) {
        guard siteRoute != route else { return }
        endLoginRequest()
        endSessionVerification()
        authenticatedUsername = nil
        loginButton.title = "登录账号"
        loginButton.toolTip = "登录你自己的账号"
        siteRoute = route
        UserDefaults.standard.set(route.rawValue, forKey: ComicSiteRoute.preferenceKey)
        statusLabel.stringValue = "站点线路已切换为 \(route.rawValue)；后续搜索和登录会使用此线路。"
    }

    private func beginSiteLogin(username: String, password: String) {
        endLoginRequest()
        endSessionVerification()
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUsername.isEmpty, !password.isEmpty else {
            loginPanel?.showFailure("请输入账号和密码。")
            return
        }
        loginPanel?.showSubmitting()
        loginButton.title = "登录中…"
        loginButton.isEnabled = false
        statusLabel.stringValue = "正在通过禁漫天堂验证账号…"
        loginAttemptID = UUID()
        let attemptID = loginAttemptID
        loginDeadline = Date().addingTimeInterval(40)
        moyeDiagnostic("login.begin")
        loginPending = .page(cleanUsername, password)
        let configuration = Self.webConfiguration()
        for name in ["moyeLoginDocumentReady"] {
            configuration.userContentController.add(scriptHandler, name: name)
        }
        let ready = "try{window.webkit.messageHandlers.moyeLoginDocumentReady.postMessage({ready:true})}catch(_){}"
        configuration.userContentController.addUserScript(WKUserScript(source: ready, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let worker = WKWebView(frame: NSRect(x: -4000, y: -4000, width: 1440, height: 1100), configuration: configuration)
        worker.customUserAgent = engine.customUserAgent
        worker.navigationDelegate = self
        worker.isHidden = true
        worker.setAccessibilityHidden(true)
        loginEngine = worker
        addSubview(worker, positioned: .below, relativeTo: background)
        worker.load(URLRequest(url: rootURL.appendingPathComponent("login"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25))
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in
            guard let self, self.loginAttemptID == attemptID else { return }
            switch self.loginPending {
            case .page, .outcome:
                self.loginFailed("当前线路连接超时，站点没有返回可确认的登录结果。请稍后再试。")
            default: break
            }
        }
    }

    private func loginDocumentReady() {
        switch loginPending {
        case .page(let username, let password): submitSiteLogin(username: username, password: password)
        case .outcome: break
        case .idle: break
        }
    }

    private func endLoginRequest() {
        loginAttemptID = UUID()
        loginPending = .idle
        loginDeadline = nil
        loginEngine?.navigationDelegate = nil
        for name in ["moyeLoginDocumentReady"] {
            loginEngine?.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
        loginEngine?.evaluateJavaScript("window.__moyeLoginAbort?.abort()", completionHandler: nil)
        loginEngine?.stopLoading()
        loginEngine?.removeFromSuperview()
        loginEngine = nil
        loginButton.title = authenticatedUsername == nil ? "登录账号" : "账号已登录"
        loginButton.isEnabled = true
    }

    private func submitSiteLogin(username: String, password: String) {
        guard let worker = loginEngine else { return }
        let attempt = loginAttemptID
        let source = """
        try {
          if (location.hostname !== expectedHost) return {ok:false, reason:'登录页面跳转到了其他域名，账号信息未提交。'};
          const pageText = document.body?.innerText || '';
          if (/520|web server is returning an unknown error|origin web server/i.test((document.title || '') + ' ' + pageText)) {
            return {ok:false, reason:'站点服务器返回 Cloudflare 520 错误；登录页面没有加载，账号信息未提交。'};
          }
          const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).display !== 'none' && getComputedStyle(e).visibility !== 'hidden';
          const pw = [...document.querySelectorAll('form[name=login_form] input[type=password],input[type=password]')].find(visible);
          if (!pw) return {ok:false, reason:'没有找到站点登录表单'};
          const form = pw.form || pw.closest('form');
          if (!form) return {ok:false, reason:'站点登录表单结构暂不兼容'};
          const fields = [...form.querySelectorAll('input')].filter(e => e !== pw && visible(e) && !['hidden','submit','button','image'].includes((e.type || '').toLowerCase()));
          const userInput = fields.find(e => /user|email|account|login|name/i.test((e.name || '') + ' ' + (e.id || '') + ' ' + (e.placeholder || '')))
            || fields.find(e => ['text','email',''].includes((e.type || '').toLowerCase()));
          if (!userInput) return {ok:false, reason:'没有找到账号输入框'};
          const setValue = (element, value) => {
            const descriptor = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
            if (descriptor && descriptor.set) descriptor.set.call(element, value); else element.value = value;
            element.dispatchEvent(new Event('input', {bubbles:true}));
            element.dispatchEvent(new Event('change', {bubbles:true}));
          };
          setValue(userInput, user);
          setValue(pw, pass);
          // JM's current web form uses a type="button" AJAX control, not a native submit button.
          // Keep its long-lived session option enabled, but never enable its password-save option.
          const persistentSession = form.querySelector('input[name=login_remember]');
          if (persistentSession && !persistentSession.checked) {
            persistentSession.checked = true;
            persistentSession.dispatchEvent(new Event('change', {bubbles:true}));
          }
          const savePassword = form.querySelector('input[name=id_remember]');
          if (savePassword) savePassword.checked = false;
          const action = new URL(form.getAttribute('action') || '/login', location.href);
          if (action.protocol !== 'https:' || action.hostname !== expectedHost || action.pathname !== '/login') {
            return {ok:false, reason:'登录地址不属于当前站点，账号信息未提交。'};
          }
          // Use the site's own form fields and submit_login marker. This avoids
          // depending on its deferred jQuery button handler or advertisement loads.
          const body = new URLSearchParams(new FormData(form));
          body.set('submit_login', '1');
          const controller = new AbortController();
          window.__moyeLoginAbort = controller;
          const timeout = setTimeout(() => controller.abort(), 20000);
          let response;
          try {
            response = await fetch(action.href, {
              method:'POST', credentials:'same-origin', signal:controller.signal,
              headers:{'Content-Type':'application/x-www-form-urlencoded; charset=UTF-8','X-Requested-With':'XMLHttpRequest'},
              body:body.toString()
            });
            const text = await response.text();
            let data;
            try { data = JSON.parse(text); } catch (_) {
              return {ok:false, reason:'登录服务没有返回有效结果（HTTP ' + response.status + '），请稍后重试。'};
            }
            let message = String(data?.errors || data?.msg || data?.message || '');
            if (pass) message = message.split(pass).join('[已隐藏]');
            return {ok:true,httpStatus:response.status,status:Number(data?.status ?? -1),message};
          } finally { clearTimeout(timeout); if (window.__moyeLoginAbort === controller) delete window.__moyeLoginAbort; }
        } catch (error) {
          return {ok:false, reason:error.name === 'AbortError' ? '登录服务响应超时，请重试。' : '登录请求失败，请检查网络后重试。'};
        }
        """
        moyeDiagnostic("login.form.submit")
        loginPending = .outcome(username)
        worker.callAsyncJavaScript(source, arguments: ["user": username, "pass": password, "expectedHost": rootURL.host ?? ""], in: nil, in: .page, completionHandler: { [weak self, weak worker] result in
            DispatchQueue.main.async {
                guard let self, let worker, self.loginEngine === worker,
                      self.loginAttemptID == attempt, case .outcome = self.loginPending else { return }
                guard case .success(let value) = result else {
                    if case .failure(let error) = result {
                        let details = (error as NSError).userInfo.first(where: { $0.key.localizedCaseInsensitiveContains("exceptionmessage") })?.value as? String
                        self.loginFailed("登录表单提交失败：\(details ?? error.localizedDescription)")
                    }
                    return
                }
                let response = value as? [String: Any] ?? [:]
                guard response["ok"] as? Bool == true else {
                    self.loginFailed(response["reason"] as? String ?? "没有找到可用的站点登录表单。")
                    return
                }
                self.loginPanel?.clearPassword()
                let httpStatus = response["httpStatus"] as? Int ?? 0
                let status = response["status"] as? Int ?? -1
                moyeDiagnostic("login.response.http=\(httpStatus),status=\(status)")
                if status == 1, (200..<300).contains(httpStatus) {
                    self.completeLoginWithSession(username: username)
                } else if status == 5 {
                    self.loginFailed("站点要求额外验证，登录尚未完成。")
                } else {
                    let detail = (response["message"] as? String ?? "").cleanedHTMLText
                    self.loginFailed(detail.isEmpty ? "站点没有确认登录成功（HTTP \(httpStatus)，状态 \(status)）。" : "站点返回：\(detail)")
                }
            }
        })
    }

    private func loginSucceeded(username: String) {
        authenticatedUsername = username
        endLoginRequest()
        loginButton.title = "账号已登录"
        loginButton.isEnabled = true
        loginButton.toolTip = "查看当前登录账号"
        statusLabel.stringValue = "账号已登录 · 阅读和下载会使用当前站点会话"
        moyeDiagnostic("login.confirmed")
        UserDefaults.standard.set(username, forKey: "MoyeShelf.SessionUser.\(siteRoute.rawValue)")
        loginPanel?.dismiss()
        loginPanel = nil
        showAccount(username: username)
    }

    private func completeLoginWithSession(username: String) {
        guard let worker = loginEngine else { return }
        let attempt = loginAttemptID
        worker.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self, weak worker] cookies in
            DispatchQueue.main.async {
                guard let self, let worker, self.loginEngine === worker, self.loginAttemptID == attempt,
                      case .outcome(let user) = self.loginPending, user == username else { return }
                let hasSession = cookies.contains { Self.isAccountCookie($0, host: self.siteRoute.rawValue) }
                moyeDiagnostic("login.session.cookie=\(hasSession)")
                guard hasSession else { self.loginFailed("站点接受了登录请求，但没有建立登录会话，请重试。"); return }
                ComicSessionStore.save(cookies, host: self.siteRoute.rawValue)
                self.loginSucceeded(username: username)
            }
        }
    }

    private static func isAccountCookie(_ cookie: HTTPCookie, host: String) -> Bool {
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return cookie.name == "AVS" && !cookie.value.isEmpty
            && (domain == host || host.hasSuffix("." + domain))
            && (cookie.expiresDate.map { $0 > Date() } ?? true)
    }

    private func restoreSiteSession() {
        let key = "MoyeShelf.SessionUser.\(siteRoute.rawValue)"
        guard let expectedUsername = UserDefaults.standard.string(forKey: key),
              !expectedUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        endSessionVerification()
        let run = UUID()
        sessionVerificationID = run
        let host = siteRoute.rawValue
        let configuration = Self.webConfiguration()
        // Restoration is optional background work. The sign-in entry remains usable.
        loginButton.title = "登录账号"
        loginButton.isEnabled = true
        loginButton.toolTip = "正在检查已保存的登录；点击可重新登录"
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.sessionVerificationID == run else { return }
            self.endSessionVerification()
        }
        sessionVerificationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        ComicSessionStore.restore(host: host, into: configuration.websiteDataStore.httpCookieStore) { [weak self] in
            guard let self, self.sessionVerificationID == run, !self.closing else { return }
            configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                DispatchQueue.main.async {
                    guard let self, self.sessionVerificationID == run, !self.closing else { return }
                    guard cookies.contains(where: { Self.isAccountCookie($0, host: host) }) else {
                        UserDefaults.standard.removeObject(forKey: key)
                        self.endSessionVerification()
                        return
                    }
                    self.startSessionVerifier(configuration: configuration, username: expectedUsername)
                }
            }
        }
    }

    private func startSessionVerifier(configuration: WKWebViewConfiguration, username: String) {
        configuration.userContentController.add(scriptHandler, name: "moyeSessionReady")
        let readyScript = """
        (()=>{const expected=\(String(reflecting: username)).toLocaleLowerCase();let lastState='';const check=()=>{const links=[...document.querySelectorAll('a')];const logout=links.some(a=>/logout|signout|sign out|登出|注销|註銷|退出登入|退出登录/i.test((a.textContent||'')+' '+(a.getAttribute('href')||'')));const visible=e=>!!e&&e.getClientRects().length>0&&getComputedStyle(e).display!=='none'&&getComputedStyle(e).visibility!=='hidden';const hasLoginForm=[...document.querySelectorAll('form[name=login_form] input[type=password]')].some(visible);const userPage=/^\\/user(?:\\/|$)/i.test(location.pathname);const account=(document.body?.innerText||'').toLocaleLowerCase().includes(expected);const ok=!hasLoginForm&&(logout||(userPage&&account));const state=JSON.stringify({ok,userPage,account,hasLoginForm});if(state!==lastState){lastState=state;try{window.webkit.messageHandlers.moyeSessionReady.postMessage({ok,userPage,account,hasLoginForm})}catch(_){}}return ok||hasLoginForm};if(!check()){const observer=new MutationObserver(()=>{if(check())observer.disconnect()});observer.observe(document.documentElement,{childList:true,subtree:true});setTimeout(()=>observer.disconnect(),10000)}})();
        """
        configuration.userContentController.addUserScript(WKUserScript(source: readyScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let verifier = WKWebView(frame: NSRect(x: -4000, y: -4000, width: 1440, height: 1100), configuration: configuration)
        verifier.customUserAgent = engine.customUserAgent
        verifier.navigationDelegate = self
        verifier.isHidden = true
        verifier.setAccessibilityHidden(true)
        sessionVerifier = verifier
        addSubview(verifier, positioned: .below, relativeTo: background)
        verifier.load(URLRequest(url: rootURL.appendingPathComponent("user/"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8))
    }

    private func expireRestoredSession() {
        UserDefaults.standard.removeObject(forKey: "MoyeShelf.SessionUser.\(siteRoute.rawValue)")
        authenticatedUsername = nil
        endSessionVerification()
    }

    private func verifyRestoredSession(_ verifier: WKWebView) {
        let source = """
        (()=>{const logout=[...document.querySelectorAll('a')].some(a=>/\\/logout(?:[/?#]|$)/i.test(a.getAttribute('href')||''));return {ok:logout};})()
        """
        verifier.evaluateJavaScript(source) { [weak self, weak verifier] value, _ in
            DispatchQueue.main.async {
                guard let self, let verifier, self.sessionVerifier === verifier else { return }
                let ok = (value as? [String: Any])?["ok"] as? Bool == true
                if ok {
                    self.confirmRestoredSession(verifier)
                } else { moyeDiagnostic("session.unconfirmed") }
            }
        }
    }

    private func confirmRestoredSession(_ verifier: WKWebView) {
        guard sessionVerifier === verifier else { return }
        endSessionVerification()
        authenticatedUsername = UserDefaults.standard.string(forKey: "MoyeShelf.SessionUser.\(siteRoute.rawValue)")
        loginButton.title = "账号已登录"
        loginButton.isEnabled = true
        if case .idle = pending { statusLabel.stringValue = "已保持登录 · 可以搜索、阅读和下载" }
        loginButton.toolTip = "查看当前登录账号"
        moyeDiagnostic("session.restored")
    }

    private func endSessionVerification() {
        sessionVerificationID = UUID()
        sessionVerificationTimeout?.cancel()
        sessionVerificationTimeout = nil
        sessionVerifier?.navigationDelegate = nil
        sessionVerifier?.configuration.userContentController.removeScriptMessageHandler(forName: "moyeSessionReady")
        sessionVerifier?.stopLoading()
        sessionVerifier?.removeFromSuperview()
        sessionVerifier = nil
        if case .idle = loginPending {
            loginButton.title = authenticatedUsername == nil ? "登录账号" : "账号已登录"
            loginButton.isEnabled = true
            loginButton.toolTip = authenticatedUsername == nil ? "登录你自己的账号" : "查看当前登录账号"
        }
    }

    private func loginFailed(_ message: String) {
        authenticatedUsername = nil
        endLoginRequest()
        statusLabel.stringValue = message
        loginPanel?.clearPassword()
        moyeDiagnostic("login.failed")
        loginPanel?.showFailure(message)
    }

    @objc private func downloadAlbum(_ sender: Any?) {
        moyeDiagnostic("download.button.detail=\(selectedDetail != nil),result=\(selectedResult != nil)")
        guard let detail = selectedDetail else { return }
        guard !detail.chapters.isEmpty else {
            statusLabel.stringValue = "该作品暂时没有可读取的章节。"
            return
        }
        let folder = downloadDirectory
        guard FileManager.default.fileExists(atPath: folder.path), FileManager.default.isWritableFile(atPath: folder.path) else {
            statusLabel.stringValue = "下载位置无法写入，请点“更改位置”选择文件夹。"
            return
        }
        if downloadPanel?.isRunning == true { showDownloadProgress(nil); return }
        let destination = folder.appendingPathComponent(Self.fileSafe(detail.title) + ".zip")
        let panel = MoyeDownloadPanel(detail: detail, destination: destination, parent: self)
        configureDownloadStatus(panel)
        downloadPanel = panel
        panel.show(relativeTo: window)
    }
    private func configureDownloadStatus(_ panel: MoyeDownloadPanel) {
        panel.onStatus = { [weak self] message, running in
            guard let self else { return }
            self.downloadProgressButton.isHidden = false
            self.downloadProgressButton.title = running ? "下载中 · 查看进度" : "下载结果"
            self.downloadProgressButton.toolTip = message
            self.readerView?.updateDownloadStatus(running)
            self.needsLayout = true
        }
    }
    @objc private func showDownloadProgress(_ sender: Any?) { downloadPanel?.show(relativeTo: window) }

    private var downloadDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: "MoyeShelf.DownloadDirectory") { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    private func updateDownloadLocation() {
        let path = downloadDirectory.path
        downloadLocationLabel.stringValue = (path as NSString).abbreviatingWithTildeInPath
        downloadLocationLabel.toolTip = path
    }

    @objc private func chooseDownloadFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "选择下载位置"
        panel.prompt = "使用此文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = downloadDirectory
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let folder = panel.url else { return }
            UserDefaults.standard.set(folder.path, forKey: "MoyeShelf.DownloadDirectory")
            self.updateDownloadLocation()
            self.owner?.showToast("下载位置已更新")
        }
    }

    @objc private func openDownloadFolder(_ sender: Any?) { NSWorkspace.shared.open(downloadDirectory) }

    @discardableResult static func fetchImage(url: URL, referer: URL, completion: @escaping (Data?) -> Void) -> MoyeImageRequest {
        let handle = MoyeImageRequest()
        var request = URLRequest(url: url, timeoutInterval: 40)
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        DispatchQueue.main.async {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                guard !handle.isCancelled else { completion(nil); return }
                let host = url.host?.lowercased() ?? ""
                let matching = cookies.filter { cookie in
                    let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    return (host == domain || host.hasSuffix("." + domain)) && (!cookie.isSecure || url.scheme == "https")
                }
                var imageRequest = request
                for (name, value) in HTTPCookie.requestHeaderFields(with: matching) { imageRequest.setValue(value, forHTTPHeaderField: name) }
                let task = MoyeRuntimeData.imageSession.dataTask(with: imageRequest) { data, response, _ in
                    guard (response as? HTTPURLResponse)?.statusCode == 200,
                          response?.mimeType?.hasPrefix("image/") == true,
                          let data, !data.isEmpty,
                          let source = CGImageSourceCreateWithData(data as CFData, nil),
                          CGImageSourceGetCount(source) > 0 else { completion(nil); return }
                    completion(data)
                }
                handle.attach(task)
            }
        }
        return handle
    }

    private static func fileSafe(_ value: String) -> String {
        let cleaned = value.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\t")).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        var name = cleaned.isEmpty ? "漫画作品" : cleaned
        while name.decomposedStringWithCanonicalMapping.utf8.count > 230 { name.removeLast() }
        return name
    }
}

private extension OnlineMainView {
    static let searchScriptPlaceholder = ""
}

private final class NativeLoginPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let siteRouteLabel = NSTextField(labelWithString: "站点线路")
    private let siteRoutePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = NSTextField(wrappingLabelWithString: "登录后会保持禁漫天堂的网站会话。墨夜阅读器不会保存你的密码。")
    private let submitButton = MoyeGlassButton(title: "登录账号", target: nil, action: nil)
    private let onRouteChange: (ComicSiteRoute) -> Void
    private let onSubmit: (String, String, ComicSiteRoute) -> Void
    private let onClose: () -> Void

    init(initialRoute: ComicSiteRoute,
         onRouteChange: @escaping (ComicSiteRoute) -> Void,
         onSubmit: @escaping (String, String, ComicSiteRoute) -> Void,
         onClose: @escaping () -> Void) {
        self.onRouteChange = onRouteChange
        self.onSubmit = onSubmit
        self.onClose = onClose
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.title = "登录禁漫天堂账号"
        panel.appearance = MoyeAppearance.appearance
        panel.backgroundColor = color(0.95, 0.95, 0.98)
        panel.isReleasedWhenClosed = false
        panel.center()

        let content = NSView(frame: panel.contentView?.bounds ?? .zero)
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.backgroundColor = color(0.95, 0.95, 0.98).cgColor
        panel.contentView = content

        siteRouteLabel.frame = NSRect(x: 38, y: 384, width: 95, height: 22)
        siteRouteLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        siteRouteLabel.textColor = color(0.31, 0.31, 0.37)
        content.addSubview(siteRouteLabel)
        siteRoutePopup.addItems(withTitles: ComicSiteRoute.allCases.map(\.displayTitle))
        siteRoutePopup.selectItem(at: ComicSiteRoute.allCases.firstIndex(of: initialRoute) ?? 0)
        siteRoutePopup.frame = NSRect(x: 139, y: 378, width: 425, height: 34)
        siteRoutePopup.target = self
        siteRoutePopup.action = #selector(routeChanged(_:))
        content.addSubview(siteRoutePopup)

        let title = label("登录账号", size: 28, weight: .bold, color: color(0.16, 0.15, 0.21))
        title.frame = NSRect(x: 34, y: 465, width: 520, height: 38)
        content.addSubview(title)
        let subtitle = label("公开作品可直接下载；登录用于账号访问权限。", size: 16, weight: .medium, color: color(0.40, 0.40, 0.47))
        subtitle.frame = NSRect(x: 36, y: 435, width: 520, height: 24)
        content.addSubview(subtitle)

        let usernameCaption = label("用户名或邮箱", size: 14, weight: .semibold, color: color(0.31, 0.31, 0.37))
        usernameCaption.frame = NSRect(x: 38, y: 333, width: 500, height: 22)
        content.addSubview(usernameCaption)
        usernameField.frame = NSRect(x: 36, y: 286, width: 528, height: 43)
        usernameField.placeholderString = "输入禁漫天堂账号"
        usernameField.stringValue = ""
        usernameField.identifier = NSUserInterfaceItemIdentifier("login-username")
        usernameField.font = .systemFont(ofSize: 17)
        usernameField.focusRingType = .default
        usernameField.wantsLayer = true
        usernameField.layer?.cornerRadius = 11
        usernameField.layer?.backgroundColor = surfaceTint(1).cgColor
        usernameField.layer?.borderWidth = 1
        usernameField.layer?.borderColor = color(0.82, 0.82, 0.87).cgColor
        content.addSubview(usernameField)

        let passwordCaption = label("密码", size: 14, weight: .semibold, color: color(0.31, 0.31, 0.37))
        passwordCaption.frame = NSRect(x: 38, y: 253, width: 500, height: 22)
        content.addSubview(passwordCaption)
        passwordField.frame = NSRect(x: 36, y: 206, width: 528, height: 43)
        passwordField.placeholderString = "输入密码"
        passwordField.identifier = NSUserInterfaceItemIdentifier("login-password")
        passwordField.font = .systemFont(ofSize: 17)
        passwordField.focusRingType = .default
        passwordField.wantsLayer = true
        passwordField.layer?.cornerRadius = 11
        passwordField.layer?.backgroundColor = surfaceTint(1).cgColor
        passwordField.layer?.borderWidth = 1
        passwordField.layer?.borderColor = color(0.82, 0.82, 0.87).cgColor
        content.addSubview(passwordField)

        status.frame = NSRect(x: 38, y: 129, width: 520, height: 48)
        status.font = .systemFont(ofSize: 14, weight: .medium)
        status.textColor = color(0.39, 0.39, 0.46)
        status.maximumNumberOfLines = 3
        content.addSubview(status)

        submitButton.target = self
        submitButton.action = #selector(submit(_:))
        submitButton.bezelStyle = .rounded
        submitButton.font = .systemFont(ofSize: 16, weight: .semibold)
        submitButton.frame = NSRect(x: 36, y: 46, width: 528, height: 50)
        submitButton.wantsLayer = true
        submitButton.layer?.cornerRadius = 14
        submitButton.layer?.backgroundColor = color(0.39, 0.30, 0.57).cgColor
        submitButton.contentTintColor = .white
        content.addSubview(submitButton)
        passwordField.target = self
        passwordField.action = #selector(submit(_:))
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(passwordField.stringValue.isEmpty ? usernameField : passwordField)
    }

    func dismiss() { clearPassword(); panel.orderOut(nil) }

    func windowWillClose(_ notification: Notification) {
        clearPassword()
        onClose()
    }

    func clearPassword() { passwordField.stringValue = "" }

    func showSubmitting(message: String = "正在安全提交账号信息…") {
        status.stringValue = message
        status.textColor = color(0.36, 0.33, 0.45)
        submitButton.title = "正在登录…"
        submitButton.isEnabled = false
        usernameField.isEnabled = false
        passwordField.isEnabled = false
        siteRoutePopup.isEnabled = false
    }

    func showFailure(_ message: String) {
        status.stringValue = message
        status.textColor = color(0.68, 0.19, 0.20)
        submitButton.title = "重试登录"
        submitButton.isEnabled = true
        usernameField.isEnabled = true
        passwordField.isEnabled = true
        siteRoutePopup.isEnabled = true
    }

    func showSuccess(username: String) {
        status.stringValue = "已通过站点确认登录。下次打开时会验证并沿用网站登录会话；密码不会保存在墨夜阅读器中。"
        status.textColor = color(0.18, 0.48, 0.31)
        submitButton.title = "登录成功"
        submitButton.isEnabled = false
        clearPassword()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.panel.orderOut(nil) }
    }

    @objc private func routeChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard ComicSiteRoute.allCases.indices.contains(index) else { return }
        onRouteChange(ComicSiteRoute.allCases[index])
    }

    @objc private func submit(_ sender: Any?) {
        guard submitButton.isEnabled else { return }
        let username = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordField.stringValue
        guard !username.isEmpty, !password.isEmpty else {
            showFailure("请输入账号和密码。")
            return
        }
        let routeIndex = siteRoutePopup.indexOfSelectedItem
        guard ComicSiteRoute.allCases.indices.contains(routeIndex) else { return }
        onSubmit(username, password, ComicSiteRoute.allCases[routeIndex])
    }
}

private extension String {
    var cleanedHTMLText: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class ComicResultsCanvas: NSView {
    override var isFlipped: Bool { true }
    weak var delegate: OnlineMainView?
    private(set) var items: [ComicResult] = []
    private var cards: [ComicResultCard] = []
    private var columns = 2
    func setResults(_ items: [ComicResult], columns: Int) {
        self.items = items; self.columns = max(1, min(3, columns))
        cards.forEach { $0.removeFromSuperview() }
        cards = items.map { result in
            let card = ComicResultCard(result: result)
            card.readAction = { [weak self] in self?.delegate?.read(result) }
            addSubview(card); return card
        }
        needsLayout = true
    }
    func setColumns(_ value: Int) { columns = max(1, min(3, value)); needsLayout = true }
    private var cardHeight: CGFloat { columns == 3 ? 220 : 245 }
    func requiredHeight(for width: CGFloat) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        let rows = CGFloat((items.count + columns - 1) / columns)
        return rows * cardHeight + (rows + 1) * 16
    }
    override func layout() {
        super.layout()
        let gap: CGFloat = 16, cardWidth = (bounds.width - gap * CGFloat(columns + 1)) / CGFloat(columns)
        for (index, card) in cards.enumerated() {
            card.frame = NSRect(x: gap + CGFloat(index % columns) * (cardWidth + gap), y: gap + CGFloat(index / columns) * (cardHeight + gap), width: cardWidth, height: cardHeight)
            card.layoutCard()
        }
    }
}

private final class ComicResultCard: NSView {
    private let result: ComicResult
    private let cover = MoyeCoverView()
    private let titleLabel: NSTextField
    private let authorLabel: NSTextField
    private let metadataLabel: NSTextField
    private let idLabel: NSTextField
    private let hit = MoyeCardHitButton(title: "", target: nil, action: nil)
    var readAction: (() -> Void)?
    init(result: ComicResult) {
        self.result = result
        titleLabel = NSTextField(wrappingLabelWithString: result.title)
        authorLabel = NSTextField(wrappingLabelWithString: result.author.isEmpty ? "作者信息暂未提供" : result.author)
        metadataLabel = NSTextField(wrappingLabelWithString: result.metadata)
        idLabel = label("JM \(result.id)", size: 13, weight: .semibold, color: .secondaryLabelColor)
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 22; layer?.cornerCurve = .continuous
        layer?.backgroundColor = surfaceTint(0.82).cgColor; layer?.borderWidth = 1; layer?.borderColor = borderTint(0.88).cgColor
        cover.wantsLayer = true; cover.layer?.cornerRadius = 15; cover.layer?.masksToBounds = true
        cover.layer?.backgroundColor = color(0.88, 0.86, 0.91).cgColor
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold); titleLabel.maximumNumberOfLines = 4
        titleLabel.textColor = .labelColor; titleLabel.lineBreakMode = .byWordWrapping; titleLabel.cell?.wraps = true; titleLabel.cell?.truncatesLastVisibleLine = true; titleLabel.toolTip = result.title
        authorLabel.font = .systemFont(ofSize: 14, weight: .medium); authorLabel.textColor = .secondaryLabelColor; authorLabel.maximumNumberOfLines = 2
        metadataLabel.font = .systemFont(ofSize: 13); metadataLabel.textColor = .secondaryLabelColor; metadataLabel.maximumNumberOfLines = 3
        for view in [cover, titleLabel, authorLabel, metadataLabel, idLabel] { addSubview(view) }
        hit.target = self; hit.action = #selector(readNow(_:)); hit.isBordered = false; hit.setButtonType(.momentaryChange)
        hit.identifier = NSUserInterfaceItemIdentifier("comic-card-" + result.id)
        hit.setAccessibilityLabel(result.title + "，直接阅读"); hit.toolTip = "点击整张卡片开始阅读"
        hit.highlightChanged = { [weak self] pressed in self?.layer?.borderColor = (pressed ? NSColor.systemPurple : borderTint(0.88)).cgColor; self?.layer?.opacity = pressed ? 0.9 : 1 }
        addSubview(hit)
        if let url = result.coverURL { OnlineMainView.fetchImage(url: url, referer: result.url) { [weak self] data in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async { self?.cover.image = image }
        } }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func layoutCard() {
        let inset: CGFloat = 14
        let coverHeight = bounds.height - inset * 2
        let coverWidth = min(coverHeight * 0.69, bounds.width * 0.37)
        cover.frame = NSRect(x: inset, y: inset, width: coverWidth, height: coverHeight)
        let x = cover.frame.maxX + 16, width = max(1, bounds.width - x - inset)
        let narrow = width < 230
        titleLabel.font = .systemFont(ofSize: narrow ? 16 : 18, weight: .bold)
        titleLabel.maximumNumberOfLines = narrow ? 4 : 3
        titleLabel.frame = NSRect(x: x, y: bounds.height - inset - (narrow ? 88 : 76), width: width, height: narrow ? 88 : 76)
        authorLabel.frame = NSRect(x: x, y: titleLabel.frame.minY - 44, width: width, height: 38)
        metadataLabel.frame = NSRect(x: x, y: 43, width: width, height: max(22, authorLabel.frame.minY - 50))
        idLabel.frame = NSRect(x: x, y: 16, width: width, height: 21)
        hit.frame = bounds
    }
    @objc private func readNow(_ sender: Any?) { readAction?() }
}

private final class ComicDetailCanvas: NSView {
    private let result: ComicResult?
    private let detail: ComicDetail
    var chapterAction: ((ComicChapter) -> Void)?
    var coverAction: (() -> Void)?
    private var chapterButtons: [NSButton] = []
    private let cover = MoyeCoverView()
    private let coverHit = MoyeCardHitButton(title: "", target: nil, action: nil)
    private let infoCard = NSView()
    private let titleField: NSTextField
    private let authorField: NSTextField
    private let identifierField: NSTextField
    private let descriptionField: NSTextField
    private let chapterHeading = label("章节列表", size: 21, weight: .bold, color: color(0.20, 0.20, 0.25))
    private var emptyField: NSTextField?

    init(result: ComicResult?, detail: ComicDetail) {
        self.result = result
        self.detail = detail
        titleField = NSTextField(wrappingLabelWithString: detail.title)
        authorField = NSTextField(wrappingLabelWithString: detail.author.isEmpty ? "作者信息暂未提供" : "作者 · \(detail.author)")
        identifierField = label("JM \(result?.id ?? "—")  ·  \(detail.chapters.count) 个章节", size: 14, weight: .semibold, color: color(0.52, 0.43, 0.63))
        let boilerplate = detail.description.contains("成人") && (detail.description.contains("線上看") || detail.description.contains("线上看"))
        descriptionField = NSTextField(wrappingLabelWithString: boilerplate ? "" : detail.description)
        super.init(frame: .zero)
        infoCard.wantsLayer = true
        infoCard.layer?.cornerRadius = 24
        infoCard.layer?.cornerCurve = .continuous
        infoCard.layer?.backgroundColor = surfaceTint(0.90).cgColor
        infoCard.layer?.borderWidth = 1
        infoCard.layer?.borderColor = borderTint(0.70).cgColor
        addSubview(infoCard)
        if let url = detail.coverURL ?? result?.coverURL {
            OnlineMainView.fetchImage(url: url, referer: result?.url ?? URL(string: "https://18comic.vip")!) { [weak self] data in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async { self?.cover.image = image }
            }
        }
        cover.imageScaling = .scaleProportionallyUpOrDown
        cover.wantsLayer = true
        cover.layer?.cornerRadius = 16
        cover.layer?.masksToBounds = true
        cover.layer?.backgroundColor = color(0.87, 0.85, 0.91).cgColor
        infoCard.addSubview(cover)
        coverHit.target = self
        coverHit.action = #selector(readCover(_:))
        coverHit.isBordered = false
        coverHit.setAccessibilityLabel("点击封面开始阅读")
        coverHit.identifier = NSUserInterfaceItemIdentifier("detail-cover-read")
        coverHit.highlightChanged = { [weak self] pressed in self?.cover.alphaValue = pressed ? 0.85 : 1 }
        infoCard.addSubview(coverHit)

        titleField.font = .systemFont(ofSize: 25, weight: .bold)
        titleField.textColor = color(0.18, 0.18, 0.23)
        titleField.maximumNumberOfLines = 0
        titleField.lineBreakMode = .byWordWrapping
        titleField.isSelectable = true
        titleField.toolTip = detail.title
        titleField.identifier = NSUserInterfaceItemIdentifier("detail-title")
        authorField.font = .systemFont(ofSize: 17, weight: .medium)
        authorField.textColor = color(0.42, 0.40, 0.47)
        authorField.maximumNumberOfLines = 0
        authorField.lineBreakMode = .byWordWrapping
        authorField.identifier = NSUserInterfaceItemIdentifier("detail-author")
        identifierField.identifier = NSUserInterfaceItemIdentifier("detail-identifier")
        descriptionField.font = .systemFont(ofSize: 16)
        descriptionField.textColor = color(0.38, 0.38, 0.44)
        descriptionField.maximumNumberOfLines = 4
        descriptionField.lineBreakMode = .byWordWrapping
        descriptionField.toolTip = detail.description
        descriptionField.identifier = NSUserInterfaceItemIdentifier("detail-description")
        for field in [titleField, authorField, identifierField, descriptionField] { infoCard.addSubview(field) }
        chapterHeading.identifier = NSUserInterfaceItemIdentifier("chapter-heading")
        addSubview(chapterHeading)
        for (index, chapter) in detail.chapters.enumerated() {
            let button = MoyeGlassButton(title: chapter.title.isEmpty ? "第 \(index + 1) 话" : chapter.title, target: self, action: #selector(openChapter(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(chapter.id)
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 16, weight: .medium)
            button.alignment = .left
            button.cell?.wraps = false
            button.cell?.usesSingleLineMode = true
            button.cell?.lineBreakMode = .byTruncatingTail
            button.contentTintColor = color(0.26, 0.25, 0.31)
            button.toolTip = button.title
            button.wantsLayer = true
            button.layer?.cornerRadius = 13
            button.layer?.backgroundColor = surfaceTint(0.68).cgColor
            addSubview(button)
            chapterButtons.append(button)
        }
        if detail.chapters.isEmpty {
            let empty = label("暂时没有可用章节信息。", size: 16, color: .secondaryLabelColor)
            empty.identifier = NSUserInterfaceItemIdentifier("chapter-empty")
            addSubview(empty)
            emptyField = empty
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private struct Metrics {
        let textX: CGFloat
        let textWidth: CGFloat
        let titleHeight: CGFloat
        let authorHeight: CGFloat
        let descriptionHeight: CGFloat
        let cardHeight: CGFloat
        let columns: Int
        let rows: Int
    }

    private func measuredHeight(_ field: NSTextField, width: CGFloat, maximumLines: Int = 0) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let font = field.font ?? .systemFont(ofSize: 16)
        let text = NSAttributedString(string: field.stringValue, attributes: [.font: font, .paragraphStyle: paragraph])
        let measured = text.boundingRect(with: NSSize(width: max(1, width - 6), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let height = maximumLines > 0 ? min(measured, lineHeight * CGFloat(maximumLines)) : measured
        return ceil(max(lineHeight, height)) + 8
    }

    private func metrics(for width: CGFloat) -> Metrics {
        let textX: CGFloat = 22 + 186 + 26
        let textWidth = max(1, width - textX - 22)
        let titleHeight = measuredHeight(titleField, width: textWidth)
        let authorHeight = measuredHeight(authorField, width: textWidth)
        let descriptionHeight = descriptionField.stringValue.isEmpty ? 0 : measuredHeight(descriptionField, width: textWidth, maximumLines: 4)
        let textHeight = titleHeight + 16 + authorHeight + 10 + 22 + 18 + descriptionHeight
        let columns = width > 920 ? 3 : 2
        let rows = max(1, (chapterButtons.count + columns - 1) / columns)
        return Metrics(textX: textX, textWidth: textWidth, titleHeight: titleHeight, authorHeight: authorHeight, descriptionHeight: descriptionHeight, cardHeight: max(270, textHeight) + 44, columns: columns, rows: rows)
    }

    func requiredHeight(for width: CGFloat) -> CGFloat {
        let m = metrics(for: width)
        return max(520, 12 + m.cardHeight + 26 + 30 + 14 + CGFloat(m.rows) * 64 + 24)
    }

    override func layout() {
        super.layout()
        let m = metrics(for: bounds.width)
        infoCard.frame = NSRect(x: 0, y: bounds.height - 12 - m.cardHeight, width: bounds.width, height: m.cardHeight)
        cover.frame = NSRect(x: 22, y: m.cardHeight - 22 - 270, width: 186, height: 270)
        coverHit.frame = cover.frame
        var top = m.cardHeight - 22
        titleField.frame = NSRect(x: m.textX, y: top - m.titleHeight, width: m.textWidth, height: m.titleHeight)
        top = titleField.frame.minY - 16
        authorField.frame = NSRect(x: m.textX, y: top - m.authorHeight, width: m.textWidth, height: m.authorHeight)
        top = authorField.frame.minY - 10
        identifierField.frame = NSRect(x: m.textX, y: top - 22, width: m.textWidth, height: 22)
        top = identifierField.frame.minY - 18
        descriptionField.frame = NSRect(x: m.textX, y: top - m.descriptionHeight, width: m.textWidth, height: m.descriptionHeight)
        chapterHeading.frame = NSRect(x: 4, y: infoCard.frame.minY - 26 - 30, width: bounds.width - 8, height: 30)
        let rowsTop = chapterHeading.frame.minY - 14
        let gap: CGFloat = 12
        let buttonWidth = (bounds.width - gap * CGFloat(m.columns - 1)) / CGFloat(m.columns)
        for (index, button) in chapterButtons.enumerated() {
            let row = index / m.columns, column = index % m.columns
            button.frame = NSRect(x: CGFloat(column) * (buttonWidth + gap), y: rowsTop - 52 - CGFloat(row) * 64, width: buttonWidth, height: 52)
        }
        emptyField?.frame = NSRect(x: 4, y: rowsTop - 32, width: bounds.width - 8, height: 32)
    }

    @objc private func openChapter(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let chapter = detail.chapters.first(where: { $0.id == id }) else { return }
        chapterAction?(chapter)
    }
    @objc private func readCover(_ sender: Any?) { coverAction?() }
}

enum ComicImageDecoder {
    struct DownloadImage {
        let data: Data
        let fileExtension: String
    }

    static func decode(_ data: Data, imageURL: URL, albumID: Int, scrambleID: Int) -> Data? {
        guard albumID > 0, scrambleID > 0, albumID >= scrambleID,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let filename = imageURL.lastPathComponent
        let stem = (filename as NSString).deletingPathExtension
        let strips = stripCount(albumID: albumID, scrambleID: scrambleID, filename: stem)
        guard strips > 1, image.height > strips else { return nil }
        guard let decoded = restore(image, strips: strips) else { return nil }
        return NSBitmapImageRep(cgImage: decoded).representation(using: .png, properties: [:])
    }

    static func downloadImage(_ data: Data, imageURL: URL, albumID: Int, scrambleID: Int) -> DownloadImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let sourceType = CGImageSourceGetType(source) else { return nil }
        let type = sourceType as String
        let extensions = ["public.jpeg": "jpg", "public.png": "png", "org.webmproject.webp": "webp", "public.avif": "avif", "public.heic": "heic", "public.heif": "heif"]
        let fileExtension = extensions[type] ?? UTType(type)?.preferredFilenameExtension ?? "img"
        let original = DownloadImage(data: data, fileExtension: fileExtension)
        guard albumID > 0, scrambleID > 0, albumID >= scrambleID else { return original }
        let stem = (imageURL.lastPathComponent as NSString).deletingPathExtension
        let strips = stripCount(albumID: albumID, scrambleID: scrambleID, filename: stem)
        guard strips > 1, image.height > strips else { return original }
        guard let decoded = restore(image, strips: strips) else { return nil }
        return encodeDownloadImage(decoded, sourceType: type)
    }

    static func encodeDownloadImage(_ image: CGImage, sourceType: String) -> DownloadImage? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let png = bitmap.representation(using: .png, properties: [:])
        // Reconstructed JPEG pages were previously always written as much larger PNGs.
        // Retain full resolution. PNG and transparent pages keep lossless reconstruction;
        // unshuffled bytes stay original. CDN JPEG/WebP/AVIF pages can use high quality JPEG.
        let mime = UTType(sourceType)?.preferredMIMEType ?? ""
        let compressedPhoto = ["org.webmproject.webp", "public.avif", "public.heic", "public.heif"].contains(sourceType) ||
            ["image/webp", "image/avif", "image/heic", "image/heif"].contains(mime)
        let canUseJPEG = sourceType == UTType.jpeg.identifier || (compressedPhoto && isOpaque(image))
        if canUseJPEG,
           let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95]),
           png.map({ jpeg.count < $0.count }) ?? true {
            return DownloadImage(data: jpeg, fileExtension: "jpg")
        }
        return png.map { DownloadImage(data: $0, fileExtension: "png") }
    }

    private static func isOpaque(_ image: CGImage) -> Bool {
        if [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) { return true }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for index in stride(from: 3, to: context.bytesPerRow * image.height, by: 4) {
            if bytes[index] != 255 { return false }
        }
        return true
    }

    private static func restore(_ image: CGImage, strips: Int) -> CGImage? {
        let h = image.height, w = image.width
        let remainder = h % strips
        let stripHeight = h / strips
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        var sourceY = h - remainder - stripHeight
        var destinationY = 0
        for index in 0..<strips {
            let sliceHeight = index == 0 ? stripHeight + remainder : stripHeight
            let rect = CGRect(x: 0, y: sourceY, width: w, height: sliceHeight)
            if let slice = image.cropping(to: rect) {
                context.draw(slice, in: CGRect(x: 0, y: h - destinationY - sliceHeight, width: w, height: sliceHeight))
            }
            sourceY -= stripHeight
            destinationY += sliceHeight
        }
        return context.makeImage()
    }

    private static func stripCount(albumID: Int, scrambleID: Int, filename: String) -> Int {
        if albumID < scrambleID { return 0 }
        if albumID < 268850 { return 10 }
        let modulus = albumID < 421926 ? 10 : 8
        let digest = Insecure.MD5.hash(data: Data("\(albumID)\(filename)".utf8))
        let lastByte = Array(digest).last ?? 0
        let hex = String(format: "%02x", lastByte)
        let lastCharacter = Int(hex.utf8.last ?? 48)
        return (lastCharacter % modulus) * 2 + 2
    }
}
