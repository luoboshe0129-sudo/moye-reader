import AppKit
import WebKit
import CryptoKit

// These files belong only to this launch and are removed by the application's exit path.
final class MoyeReadingCache {
    static let shared = MoyeReadingCache()
    private struct Job {
        let key: String
        let load: (@escaping (Data?) -> Void) -> Void
        var callbacks: [(NSImage?) -> Void]
    }
    var chapters: [String: ComicPageSet] = [:]
    var requestedChapters = Set<String>()
    private let stateLock = NSLock()
    private var files: [String: URL] = [:]
    private var jobs: [String: Job] = [:]
    private var queue: [String] = []
    private var active = Set<String>()
    private let diskQueue = DispatchQueue(label: "moye.reading.disk", qos: .userInitiated)
    private let directory = MoyeRuntimeData.temporaryRoot.appendingPathComponent("Reading", isDirectory: true)
    private var stopped = false
    private(set) var networkLoads = 0
    private(set) var diskHits = 0

    func request(key: String, priority: Bool, load: @escaping (@escaping (Data?) -> Void) -> Void, completion: ((NSImage?) -> Void)? = nil) {
        precondition(Thread.isMainThread)
        guard !stopped else { completion?(nil); return }
        if let file = files[key] {
            if let completion {
                diskHits += 1
                diskQueue.async { let image = (try? Data(contentsOf: file)).flatMap(NSImage.init(data:)); DispatchQueue.main.async { completion(image) } }
            }
            return
        }
        if var job = jobs[key] {
            if let completion { job.callbacks.append(completion) }
            jobs[key] = job
            if priority, !active.contains(key) { queue.removeAll { $0 == key }; queue.insert(key, at: 0) }
        } else {
            jobs[key] = Job(key: key, load: load, callbacks: completion.map { [$0] } ?? [])
            if priority { queue.insert(key, at: 0) } else { queue.append(key) }
        }
        pump()
    }
    private func pump() {
        while !stopped, active.count < 4, !queue.isEmpty {
            let key = queue.removeFirst()
            guard let job = jobs[key] else { continue }
            active.insert(key); networkLoads += 1
            job.load { [weak self] data in
                guard let self else { return }
                self.diskQueue.async {
                    var file: URL?
                    self.stateLock.lock()
                    if !self.stopped, let data {
                        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
                        let target = self.directory.appendingPathComponent(hash + ".png")
                        do { try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true); try data.write(to: target, options: .atomic); file = target } catch {}
                    }
                    self.stateLock.unlock()
                    let image = data.flatMap(NSImage.init(data:))
                    let saved = file
                    DispatchQueue.main.async {
                        guard !self.stopped else { return }
                        if let saved { self.files[key] = saved }
                        let callbacks = self.jobs.removeValue(forKey: key)?.callbacks ?? []
                        self.active.remove(key)
                        callbacks.forEach { $0(image) }
                        self.pump()
                    }
                }
            }
        }
    }
    func stop() { stateLock.lock(); stopped = true; stateLock.unlock(); jobs.removeAll(); queue.removeAll(); files.removeAll(); chapters.removeAll(); requestedChapters.removeAll(); diskQueue.sync {} }
#if MOYE_DIAGNOSTICS
    var snapshot: [String: Int] { ["files": files.count, "networkLoads": networkLoads, "diskHits": diskHits, "queued": queue.count, "active": active.count, "chapters": chapters.count, "pendingChapters": requestedChapters.count] }
#endif
}

final class MoyeChapterLoader: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private struct Request { let chapter: ComicChapter; let completion: (ComicPageSet?) -> Void }
    private var queue: [Request] = []
    private var current: Request?
    private var generation = UUID()
    init(parent: NSView?) {
        webView = WKWebView(frame: NSRect(x: -5000, y: -5000, width: 1400, height: 1000), configuration: OnlineMainView.webConfiguration())
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.isHidden = true
        webView.setAccessibilityHidden(true)
        parent?.addSubview(webView)
    }
    func load(_ chapter: ComicChapter, priority: Bool = false, completion: @escaping (ComicPageSet?) -> Void) {
        let request = Request(chapter: chapter, completion: completion)
        if priority { queue.insert(request, at: 0) } else { queue.append(request) }
        next()
    }
    private func next() {
        guard current == nil, !queue.isEmpty else { return }
        current = queue.removeFirst(); generation = UUID()
        let run = generation
        webView.load(URLRequest(url: current!.chapter.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 35))
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in guard let self, self.generation == run, self.current != nil else { return }; self.finish(nil) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let run = generation
        webView.evaluateJavaScript(OnlineMainView.photoScript) { [weak self] value, _ in
            guard let self, self.generation == run, let current = self.current else { return }
            let dict = value as? [String: Any] ?? [:]
            let urls = (dict["urls"] as? [String] ?? []).compactMap(URL.init(string:))
            self.finish(urls.isEmpty ? nil : ComicPageSet(urls: urls, albumID: dict["albumID"] as? Int ?? Int(current.chapter.id) ?? 0, scrambleID: dict["scrambleID"] as? Int ?? 0))
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if (error as NSError).code != NSURLErrorCancelled { finish(nil) } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if (error as NSError).code != NSURLErrorCancelled { finish(nil) } }
    private func finish(_ pages: ComicPageSet?) { guard let request = current else { return }; generation = UUID(); current = nil; webView.stopLoading(); request.completion(pages); next() }
    func cancel() { generation = UUID(); current = nil; queue.removeAll(); webView.stopLoading() }
    deinit { webView.navigationDelegate = nil; webView.removeFromSuperview() }
}

final class MoyeImageRequest {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func attach(_ task: URLSessionDataTask) { lock.lock(); self.task = task; let cancel = cancelled; lock.unlock(); if cancel { task.cancel() } else { task.resume() } }
    func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
}
