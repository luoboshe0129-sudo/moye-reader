import CryptoKit
import ImageIO
import SwiftUI
import UIKit
import WebKit

struct MoyeComic: Identifiable, Hashable {
    let id: String
    let title: String
    let author: String
    let metadata: String
    let tags: [String]
    let coverURL: URL?
    let url: URL
}

struct MoyeChapter: Identifiable, Hashable {
    let id: String
    let title: String
    let url: URL
}

struct MoyeComicDetail: Hashable {
    let comicID: String
    let title: String
    let author: String
    let description: String
    let coverURL: URL?
    let chapters: [MoyeChapter]
    var automaticChapter: MoyeChapter? { chapters.count == 1 ? chapters.first : nil }
}

struct MoyePageSet: Hashable {
    let urls: [URL]
    let albumID: Int
    let scrambleID: Int
}

@MainActor
final class MoyeCatalogService: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var comics: [MoyeComic] = []
    @Published private(set) var listingPage = 0
    @Published private(set) var hasMoreListing = false
    @Published private(set) var currentDetail: MoyeComicDetail?
    @Published private(set) var isLoading = false
    @Published private(set) var loadingMessage = ""
    @Published var errorMessage: String?

    let webView: WKWebView
    private(set) var route: MoyeSiteRoute
    private let rootOverride: URL?
    var rootURL: URL { rootOverride ?? route.rootURL }
    private var operation: Operation = .idle
    private var requestID = UUID()
    private var navigation: WKNavigation?
    private var expectedURL: URL?
    private var requestOwner: UUID?
    private var detailCompletion: ((MoyeComicDetail?) -> Void)?
    private var pagesCompletion: ((MoyePageSet?) -> Void)?
    private static var pageCache: [String: MoyePageSet] = [:]
    private static var detailCache: [String: MoyeComicDetail] = [:]
    private var cachedPageSets: [String: MoyePageSet] { get { Self.pageCache } set { Self.pageCache = newValue } }
    private var cachedDetails: [String: MoyeComicDetail] { get { Self.detailCache } set { Self.detailCache = newValue } }
    private var emptyRetries = 0
    private var settlingDetail = false
    private var settledDetail = false

    private enum Operation {
        case idle
        case listing(page: Int, append: Bool)
        case detail(MoyeComic)
        case pages(MoyeComic, MoyeChapter)
    }

    init(route: MoyeSiteRoute, rootURL: URL? = nil) {
        self.route = route
        rootOverride = rootURL
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = MoyeRuntimeData.websiteDataStore
        configuration.allowsInlineMediaPlayback = true
        let controller = WKUserContentController()
        // The same parsers serve every work. DOM-ready messages avoid waiting
        // for slow ads or decorative images before displaying native content.
        for (path, script) in [("/albums", MoyeSiteScripts.searchScript), ("/search/photos", MoyeSiteScripts.searchScript),
                               ("/album/", MoyeSiteScripts.detailScript), ("/photo/", MoyeSiteScripts.photoScript)] {
            let notifier = """
            (()=>{
              if(!location.pathname.startsWith('\(path)'))return;
              let timer;
              const send=()=>{try{const value=\(script);window.webkit.messageHandlers.moyeContent.postMessage({sourceURL:location.href,value})}catch(_){}};
              send();
              const observer=new MutationObserver(()=>{clearTimeout(timer);timer=setTimeout(send,30)});
              if(document.documentElement)observer.observe(document.documentElement,{childList:true,subtree:true});
              setTimeout(()=>observer.disconnect(),12000);
            })();
            """
            controller.addUserScript(WKUserScript(source: notifier, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        controller.addUserScript(WKUserScript(source: "window.open=()=>null;window.alert=()=>{};", injectionTime: .atDocumentStart, forMainFrameOnly: false))
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        let handler = MoyeWeakScriptHandler(owner: self)
        controller.add(handler, name: "moyeContent")
        webView.navigationDelegate = self
        webView.customUserAgent = MoyeRuntimeData.userAgent
        webView.isOpaque = false
        webView.backgroundColor = .clear
    }

    func independentLoader() -> MoyeCatalogService {
        MoyeCatalogService(route: route, rootURL: rootOverride)
    }

    func setRoute(_ value: MoyeSiteRoute) {
        guard route != value else { return }
        cancel()
        route = value
        comics = []
        listingPage = 0; hasMoreListing = false
        currentDetail = nil
        errorMessage = nil
    }

    var isAppendingListing: Bool {
        if case .listing(_, true) = operation { return true }
        return false
    }

    func loadRanking(order: String = "mv", page: Int = 1, append: Bool = false) {
        cancel()
        if !append { listingPage = 0; hasMoreListing = false }
        var components = URLComponents(url: rootURL, resolvingAgainstBaseURL: false)!
        components.path = "/albums"
        components.queryItems = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "o", value: order), URLQueryItem(name: "t", value: "m")]
        guard let url = components.url else { return }
        operation = .listing(page: page, append: append)
        begin(url, message: "正在载入每月热看 · 第 \(page) 页…")
    }

    func search(_ query: String, order: String = "mv", page: Int = 1, append: Bool = false) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cancel()
        if !append { listingPage = 0; hasMoreListing = false }
        if let id = albumID(from: trimmed) {
            let comic = MoyeComic(id: id, title: "JM \(id)", author: "", metadata: "", tags: [], coverURL: nil, url: rootURL.appending(path: "album/\(id)"))
            loadDetail(comic) { [weak self] detail in
                guard let detail else { return }
                self?.comics = [comic]
                self?.currentDetail = detail
            }
            return
        }
        var components = URLComponents(url: rootURL, resolvingAgainstBaseURL: false)!
        components.path = "/search/photos"
        components.queryItems = [URLQueryItem(name: "search_query", value: trimmed), URLQueryItem(name: "main_tag", value: "0"),
                                 URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "o", value: order), URLQueryItem(name: "t", value: "a")]
        guard let url = components.url else { return }
        operation = .listing(page: page, append: append)
        begin(url, message: "正在搜索“\(trimmed)” · 第 \(page) 页…")
    }

    func loadDetail(_ comic: MoyeComic, owner: UUID? = nil, completion: @escaping (MoyeComicDetail?) -> Void) {
        cancel()
        requestOwner = owner
        currentDetail = nil
        errorMessage = nil
        if let cached = cachedDetails[comic.url.absoluteString] {
            requestOwner = nil
            currentDetail = cached
            updateCard(cached)
            completion(cached)
            return
        }
        detailCompletion = completion
        operation = .detail(comic)
        begin(comic.url, message: "正在读取作品信息与章节…")
    }

    func cachedDetail(for comic: MoyeComic) -> MoyeComicDetail? { cachedDetails[comic.url.absoluteString] }

    func showDirectResult(_ comic: MoyeComic) {
        cancel()
        listingPage = 0; hasMoreListing = false
        comics = [comic]
        currentDetail = cachedDetail(for: comic)
        errorMessage = nil
    }


    func loadPages(for comic: MoyeComic, chapter: MoyeChapter, owner: UUID? = nil, completion: @escaping (MoyePageSet?) -> Void) {
        cancel()
        requestOwner = owner
        errorMessage = nil
        if let pages = cachedPageSets[chapter.url.absoluteString] { requestOwner = nil; completion(pages); return }
        pagesCompletion = completion
        operation = .pages(comic, chapter)
        begin(chapter.url, message: "正在打开《\(chapter.title)》…")
    }

    func cancel() {
        requestID = UUID()
        navigation = nil
        expectedURL = nil
        requestOwner = nil
        webView.stopLoading()
        operation = .idle
        isLoading = false
        let detailCallback = detailCompletion, pageCallback = pagesCompletion
        detailCompletion = nil; pagesCompletion = nil
        detailCallback?(nil); pageCallback?(nil)
    }

    func cancel(owner: UUID) {
        guard requestOwner == owner else { return }
        cancel()
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.webView === webView,
              message.frameInfo.securityOrigin.host == rootURL.host,
              let payload = message.body as? [String: Any] else { return }
        guard message.name == "moyeContent", let source = payload["sourceURL"] as? String, matches(URL(string: source)) else { return }
        accept(payload["value"], final: false)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, let expected = self.navigation, navigation === expected, matches(webView.url) else { return }
        let activeID = requestID
        let script: String
        switch operation {
        case .idle: return
        case .listing: script = MoyeSiteScripts.searchScript
        case .detail: script = MoyeSiteScripts.detailScript
        case .pages: script = MoyeSiteScripts.photoScript
        }
        webView.evaluateJavaScript(script) { [weak self] value, error in
            Task { @MainActor in
                guard let self, self.requestID == activeID else { return }
                if let error { self.finishWithError(error.localizedDescription); return }
                self.accept(value, final: true)
            }
        }
    }

    private func accept(_ value: Any?, final: Bool) {
        switch operation {
        case .idle: return
        case .listing(let page, let append):
            let records = parseComics(value)
            if records.isEmpty && !final { return }
            if records.isEmpty && retryEmptyContent(MoyeSiteScripts.searchScript) { return }
            if append {
                let seen = Set(comics.map(\.id))
                let added = records.filter { !seen.contains($0.id) }
                comics += added
                hasMoreListing = !added.isEmpty
            } else {
                comics = records
                hasMoreListing = !records.isEmpty
            }
            listingPage = page
            finish()
        case .detail(let comic):
            let detail = parseDetail(value, for: comic)
            if detail.chapters.isEmpty && !final { return }
            if detail.chapters.isEmpty && retryEmptyContent(MoyeSiteScripts.detailScript) { return }
            if detail.chapters.count == 1 && !settledDetail {
                // Some pages insert their chapter list just after DOM-ready.
                // Recheck a provisional single chapter before auto-opening it.
                guard !settlingDetail else { return }
                settlingDetail = true
                let activeID = requestID
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self, self.requestID == activeID else { return }
                    self.webView.evaluateJavaScript(MoyeSiteScripts.detailScript) { [weak self] value, error in
                        Task { @MainActor in
                            guard let self, self.requestID == activeID else { return }
                            if let error { self.finishWithError(error.localizedDescription); return }
                            self.settledDetail = true
                            self.accept(value, final: true)
                        }
                    }
                }
                return
            }
            currentDetail = detail
            updateCard(detail)
            if !detail.chapters.isEmpty { cachedDetails[comic.url.absoluteString] = detail }
            let completion = detailCompletion
            detailCompletion = nil
            finish()
            completion?(detail)
        case .pages(let comic, let chapter):
            guard let pages = parsePages(value, comic: comic) else {
                if final && retryEmptyContent(MoyeSiteScripts.photoScript) { return }
                if final { finishWithError("这一章暂时没有可读取的页面，请重试。"); }
                return
            }
            cachedPageSets[chapter.url.absoluteString] = pages
            let completion = pagesCompletion
            pagesCompletion = nil
            finish()
            completion?(pages)
        }
    }

    private func matches(_ url: URL?) -> Bool {
        guard let url, let expectedURL, url.host == expectedURL.host,
              url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == expectedURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { return false }
        let actual = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let expected = URLComponents(url: expectedURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return expected.allSatisfy { item in actual.contains { $0.name == item.name && $0.value == item.value } }
    }

    private func begin(_ url: URL, message: String, timeout: Double = 45) {
        requestID = UUID()
        emptyRetries = 0; settlingDetail = false; settledDetail = false
        expectedURL = url
        errorMessage = nil
        isLoading = true
        loadingMessage = message
        let activeID = requestID
        Task { @MainActor [weak self] in
            let rule = await MoyeRuntimeData.contentRules()
            guard let self, self.requestID == activeID else { return }
            if let rule { self.webView.configuration.userContentController.add(rule) }
            self.navigation = self.webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 35))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.requestID == activeID, self.isLoading else { return }
            self.finishWithError("读取超时，请重试或切换线路。")
        }
    }

    private func retryEmptyContent(_ script: String) -> Bool {
        guard emptyRetries < 5 else { return false }
        emptyRetries += 1
        let activeID = requestID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.requestID == activeID else { return }
            self.webView.evaluateJavaScript(script) { [weak self] value, error in
                Task { @MainActor in
                    guard let self, self.requestID == activeID else { return }
                    if let error { self.finishWithError(error.localizedDescription); return }
                    self.accept(value, final: true)
                }
            }
        }
        return true
    }

    private func finish() {
        requestID = UUID()
        navigation = nil
        expectedURL = nil
        requestOwner = nil
        operation = .idle
        isLoading = false
        errorMessage = nil
        webView.stopLoading()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishNavigation(navigation, error: error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishNavigation(navigation, error: error) }
    private func finishNavigation(_ failed: WKNavigation?, error: Error) {
        guard let navigation, failed === navigation, (error as NSError).code != NSURLErrorCancelled else { return }
        finishWithError("站点暂时无法读取，请检查网络或切换线路后重试。")
    }
    private func finishWithError(_ message: String) {
        let detailCallback = detailCompletion, pagesCallback = pagesCompletion
        detailCompletion = nil; pagesCompletion = nil
        finish()
        errorMessage = message
        detailCallback?(nil); pagesCallback?(nil)
    }

    #if MOYE_IOS_DIAGNOSTICS
    var testNavigation: WKNavigation? { navigation }
    #endif

    private func parseComics(_ value: Any?) -> [MoyeComic] {
        let records = value as? [[String: Any]] ?? []
        var seen = Set<String>()
        return records.compactMap { record in
            guard let id = record["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { return nil }
            let fallback = route.rootURL.appending(path: "album/\(id)")
            let cover = (record["cover"] as? String).flatMap(URL.init(string:))
            let tags = MoyeComicMetadata.displayTags(record["tags"] as? [String] ?? [])
            let title = (record["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let author = (record["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return MoyeComic(
                id: id,
                title: (title?.isEmpty == false ? title! : "JM \(id)"),
                author: author,
                metadata: MoyeComicMetadata.summary(record: record),
                tags: tags,
                coverURL: cover,
                url: normalizedURL(record["url"] as? String, fallback: fallback)
            )
        }
    }

    private func updateCard(_ detail: MoyeComicDetail) {
        comics = comics.map { comic in
            guard comic.id == detail.comicID else { return comic }
            return MoyeComic(id: comic.id, title: detail.title, author: detail.author,
                metadata: comic.metadata, tags: comic.tags, coverURL: detail.coverURL ?? comic.coverURL, url: comic.url)
        }
    }

    private func parseDetail(_ value: Any?, for comic: MoyeComic) -> MoyeComicDetail {
        let record = value as? [String: Any] ?? [:]
        let chapters = (record["chapters"] as? [[String: String]] ?? []).enumerated().compactMap { index, item -> MoyeChapter? in
            guard let id = item["id"], !id.isEmpty else { return nil }
            let fallback = route.rootURL.appending(path: "photo/\(id)")
            let rawName = item["title"] ?? ""
            let name = rawName
                .split(whereSeparator: \.isWhitespace)
                .filter { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "[]()【】（）")) != "最新" }
                .joined(separator: " ")
            return MoyeChapter(id: id, title: name.isEmpty ? "第 \(index + 1) 话" : name, url: normalizedURL(item["url"], fallback: fallback))
        }
        let cover = (record["cover"] as? String).flatMap(URL.init(string:)) ?? comic.coverURL
        return MoyeComicDetail(
            comicID: comic.id,
            title: (record["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? comic.title,
            author: (record["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? comic.author,
            description: (record["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            coverURL: cover,
            chapters: chapters
        )
    }

    private func parsePages(_ value: Any?, comic: MoyeComic) -> MoyePageSet? {
        let record = value as? [String: Any] ?? [:]
        let urls = (record["urls"] as? [String] ?? []).compactMap(URL.init(string:))
        guard !urls.isEmpty else { return nil }
        return MoyePageSet(
            urls: urls,
            albumID: record["albumID"] as? Int ?? Int(comic.id) ?? 0,
            scrambleID: record["scrambleID"] as? Int ?? 0
        )
    }

    private func normalizedURL(_ value: String?, fallback: URL) -> URL {
        guard let value, let url = URL(string: value, relativeTo: route.rootURL)?.absoluteURL,
              let host = url.host?.lowercased(),
              (host == rootURL.host || MoyeSiteRoute.allCases.contains(where: { $0.rawValue.lowercased() == host })) else { return fallback }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = rootURL.scheme
        components?.host = rootURL.host
        components?.port = rootURL.port
        return components?.url ?? fallback
    }

    private func albumID(from query: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^\s*(?:JM[-\s]?)?([0-9]{3,})\s*$"#, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(query.startIndex..<query.endIndex, in: query)
        guard let match = regex.firstMatch(in: query, range: range), let number = Range(match.range(at: 1), in: query) else { return nil }
        return String(query[number])
    }


}

@MainActor
private final class MoyeWeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: MoyeCatalogService?
    init(owner: MoyeCatalogService) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.receive(message) }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

struct MoyeHiddenWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
final class MoyeImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLoading = false
    private var requestID = UUID()
    private var subscription: UUID?

    func load(url: URL?, referer: URL?, albumID: Int = 0, scrambleID: Int = 0, priority: Bool = true) async {
        requestID = UUID()
        let activeRequest = requestID
        if let subscription { MoyeReadingImageCache.covers.cancel(subscription); self.subscription = nil }
        guard let url, ["https", "http"].contains(url.scheme ?? "") else { isLoading = false; return }
        if let cached = MoyeReadingImageCache.covers.imageIfCached(url: url, albumID: albumID, scrambleID: scrambleID) {
            image = cached; isLoading = false; return
        }
        image = nil
        isLoading = true
        let loadedImage: UIImage? = await withTaskCancellationHandler(operation: {
          await withCheckedContinuation { continuation in
            subscription = MoyeReadingImageCache.covers.request(
                url: url,
                referer: referer,
                albumID: albumID,
                scrambleID: scrambleID,
                priority: priority
            ) { image in
                continuation.resume(returning: image)
            }
            if Task.isCancelled, let subscription { MoyeReadingImageCache.covers.cancel(subscription) }
          }
        }, onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.requestID == activeRequest, let subscription = self.subscription else { return }
                MoyeReadingImageCache.covers.cancel(subscription)
            }
        })
        guard requestID == activeRequest, !Task.isCancelled else { return }
        subscription = nil
        image = loadedImage
        isLoading = false
    }
}

struct MoyeRemoteImage: View {
    @Environment(\.scenePhase) private var scenePhase
    let url: URL?
    let referer: URL?
    var albumID = 0
    var scrambleID = 0
    var contentMode: ContentMode = .fill
    var fitWidth = false
    var priority = true
    @StateObject private var loader = MoyeImageLoader()

    private var cachedImage: UIImage? {
        guard let url else { return nil }
        return MoyeReadingImageCache.covers.imageIfCached(url: url, albumID: albumID, scrambleID: scrambleID)
    }

    var body: some View {
        Group {
            if let image = cachedImage ?? loader.image {
                if fitWidth {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(image.size.width / max(1, image.size.height), contentMode: .fit)
                        .frame(maxWidth: .infinity)
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                }
                } else {
                    ZStack {
                        Color(uiColor: .tertiarySystemGroupedBackground)
                        Image(systemName: loader.isLoading ? "book.closed" : "photo")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                    .frame(height: fitWidth ? 700 : nil)
                }
        }
        .task(id: "\(url?.absoluteString ?? "")-\(String(describing: scenePhase))") {
            guard scenePhase == .active else { return }
            await loader.load(url: url, referer: referer, albumID: albumID, scrambleID: scrambleID, priority: priority)
        }
    }
}

@MainActor
final class MoyeReadingImageCache {
    static let shared = MoyeReadingImageCache()
    static let covers = MoyeReadingImageCache(cover: true)

    private struct Job {
        let key: String
        let url: URL
        let referer: URL?
        let albumID: Int
        let scrambleID: Int
        var priority: Bool
        var callbacks: [UUID: (UIImage?) -> Void]
        let prefetch: Bool
    }

    private let memory = NSCache<NSString, UIImage>()
    private let originalData = NSCache<NSString, NSData>()
    private var sizes: [String: CGSize] = [:]
    private var jobs: [String: Job] = [:]
    private var queue: [String] = []
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var activeLoads = 0
    private var activePreviewKeys = Set<String>()
    private var generation = UUID()
    private let cover: Bool
    private var subscriptions: [UUID: String] = [:]

    private init(cover: Bool = false) {
        self.cover = cover
        memory.countLimit = cover ? 160 : 24
        memory.totalCostLimit = (cover ? 48 : 128) * 1024 * 1024
        originalData.totalCostLimit = 32 * 1024 * 1024
    }

    func clear() {
        generation = UUID()
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll()
        let callbacks = jobs.values.flatMap { Array($0.callbacks.values) }
        jobs.removeAll()
        subscriptions.removeAll()
        queue.removeAll()
        activeLoads = 0
        activePreviewKeys.removeAll()
        memory.removeAllObjects()
        originalData.removeAllObjects()
        callbacks.forEach { $0(nil) }
    }

    func clearAll(completion: (() -> Void)? = nil) {
        MoyeChapterPreloader.shared.cancel()
        MoyePageDataStore.shared.clear()
        clear()
        // Clear files created by older versions, which used an on-disk cache.
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MoyeReader/Reading")
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: directory)
            DispatchQueue.main.async { completion?() }
        }
    }

    func sizeIfKnown(url: URL, albumID: Int, scrambleID: Int) -> CGSize? {
        sizes[Self.key(url: url, albumID: albumID, scrambleID: scrambleID)]
    }

    func dataIfCached(url: URL, albumID: Int, scrambleID: Int) -> Data? {
        originalData.object(forKey: Self.key(url: url, albumID: albumID, scrambleID: scrambleID) as NSString) as Data?
    }

    @discardableResult func request(
        url: URL,
        referer: URL?,
        albumID: Int,
        scrambleID: Int,
        priority: Bool,
        completion: ((UIImage?) -> Void)?
    ) -> UUID? {
        let key = Self.key(url: url, albumID: albumID, scrambleID: scrambleID)
        if let image = memory.object(forKey: key as NSString) {
            completion?(image)
            return nil
        }
        let token = completion == nil ? nil : UUID()
        if let token { subscriptions[token] = key }
        if var job = jobs[key] {
            if let token, let completion { job.callbacks[token] = completion }
            job.priority = job.priority || priority
            jobs[key] = job
            if priority, let index = queue.firstIndex(of: key), index > 0 {
                queue.removeAll { $0 == key }
                queue.insert(key, at: 0)
            }
        } else {
            jobs[key] = Job(key: key, url: url, referer: referer, albumID: albumID, scrambleID: scrambleID, priority: priority,
                callbacks: token.flatMap { token in completion.map { [token: $0] } } ?? [:], prefetch: completion == nil)
            if priority { queue.insert(key, at: 0) } else { queue.append(key) }
        }
        pump()
        return token
    }

    func cancel(_ token: UUID) {
        guard let key = subscriptions.removeValue(forKey: token), var job = jobs[key], let callback = job.callbacks.removeValue(forKey: token) else { return }
        jobs[key] = job
        if job.callbacks.isEmpty && !job.prefetch {
            jobs.removeValue(forKey: key)
            queue.removeAll { $0 == key }
            if let task = activeTasks.removeValue(forKey: key) {
                task.cancel(); activeLoads = max(0, activeLoads - 1); activePreviewKeys.remove(key)
            }
        }
        callback(nil)
        pump()
    }

    func imageIfCached(url: URL, albumID: Int, scrambleID: Int) -> UIImage? {
        let key = Self.key(url: url, albumID: albumID, scrambleID: scrambleID)
        return memory.object(forKey: key as NSString)
    }

    func prefetch(urls: [URL], referer: URL, albumID: Int, scrambleID: Int) {
        for url in urls {
            request(url: url, referer: referer, albumID: albumID, scrambleID: scrambleID, priority: false, completion: nil)
        }
    }

    private func pump() {
        while activeLoads < (cover ? 6 : 4), !queue.isEmpty {
            guard let next = queue.firstIndex(where: { cover || jobs[$0]?.priority == true || activePreviewKeys.count < 2 }) else { break }
            let key = queue.remove(at: next)
            guard let job = jobs[key] else { continue }
            activeLoads += 1
            if !job.priority { activePreviewKeys.insert(key) }
            let requestGeneration = generation
            let task = Task { [weak self] in
                let (image, data) = await Self.load(job, cover: self?.cover ?? false)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.finish(key: key, image: image, data: data, generation: requestGeneration)
            }
            activeTasks[key] = task
        }
    }

    private func finish(key: String, image: UIImage?, data: Data?, generation requestGeneration: UUID) {
        guard generation == requestGeneration, jobs[key] != nil else { return }
        activeLoads = max(0, activeLoads - 1)
        activeTasks.removeValue(forKey: key)
        activePreviewKeys.remove(key)
        let callbacks = jobs.removeValue(forKey: key)?.callbacks ?? [:]
        callbacks.keys.forEach { subscriptions.removeValue(forKey: $0) }
        if let image {
            let cost = image.cgImage.map { $0.width * $0.height * 4 } ?? Int(image.size.width * image.size.height * 4)
            memory.setObject(image, forKey: key as NSString, cost: max(1, cost))
            sizes[key] = image.size
            if !cover, let data { originalData.setObject(data as NSData, forKey: key as NSString, cost: data.count) }
        }
        callbacks.values.forEach { $0(image) }
        pump()
    }

    private static func load(_ job: Job, cover: Bool) async -> (UIImage?, Data?) {
        guard let data = await MoyeRuntimeData.imageData(url: job.url, referer: job.referer, cover: cover, priority: job.priority), !Task.isCancelled else { return (nil, nil) }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            if cover, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
               let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                return UIImage(cgImage: thumbnail)
            }
            let image = MoyeImageDecoder.decode(data, url: job.url, albumID: job.albumID, scrambleID: job.scrambleID) ?? UIImage(data: data)
            return image?.preparingForDisplay() ?? image
        }.value
        return (image, data)
    }

    private static func key(url: URL, albumID: Int, scrambleID: Int) -> String {
        "\(albumID):\(scrambleID):" + url.absoluteString
    }

}

enum MoyeImageDecoder {
    static func needsRestoration(_ data: Data, url: URL, albumID: Int, scrambleID: Int) -> Bool {
        guard albumID > 0, scrambleID > 0, albumID >= scrambleID,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let stem = (url.lastPathComponent as NSString).deletingPathExtension
        let strips = stripCount(albumID: albumID, scrambleID: scrambleID, filename: stem)
        return strips > 1 && image.height > strips
    }
    static func decode(_ data: Data, url: URL, albumID: Int, scrambleID: Int) -> UIImage? {
        guard albumID > 0, scrambleID > 0, albumID >= scrambleID,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let name = (url.lastPathComponent as NSString).deletingPathExtension
        let strips = stripCount(albumID: albumID, scrambleID: scrambleID, filename: name)
        guard strips > 1, image.height > strips, let restored = restore(image, strips: strips) else { return nil }
        return UIImage(cgImage: restored)
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

    private static func restore(_ image: CGImage, strips: Int) -> CGImage? {
        let height = image.height
        let width = image.width
        let remainder = height % strips
        let stripHeight = height / strips
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        var sourceY = height - remainder - stripHeight
        var destinationY = 0
        for index in 0..<strips {
            let sliceHeight = index == 0 ? stripHeight + remainder : stripHeight
            if let slice = image.cropping(to: CGRect(x: 0, y: sourceY, width: width, height: sliceHeight)) {
                context.draw(slice, in: CGRect(x: 0, y: height - destinationY - sliceHeight, width: width, height: sliceHeight))
            }
            sourceY -= stripHeight
            destinationY += sliceHeight
        }
        return context.makeImage()
    }
}
