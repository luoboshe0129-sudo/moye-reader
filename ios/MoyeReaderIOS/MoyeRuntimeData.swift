import Foundation
import CryptoKit
import WebKit

@MainActor
enum MoyeRuntimeData {
    static let websiteDataStore = WKWebsiteDataStore.nonPersistent()
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    static let imageSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration)
    }()
    static let coverSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration)
    }()
    private static var cookieRead: Task<[HTTPCookie], Never>?
    private static let parsingRules: Task<WKContentRuleList?, Never> = Task {
        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "moye-native-parsing-v1",
                encodedContentRuleList: #"[{"trigger":{"url-filter":".*","resource-type":["image","media","font"]},"action":{"type":"block"}}]"#) { rule, _ in
                continuation.resume(returning: rule)
            }
        }
    }

    static func contentRules() async -> WKContentRuleList? { await parsingRules.value }
    private static func cookies() async -> [HTTPCookie] {
        if let cookieRead { return await cookieRead.value }
        let read = Task { @MainActor in
            await withCheckedContinuation { continuation in
                websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
            }
        }
        cookieRead = read
        let result = await read.value
        cookieRead = nil
        return result
    }

    static func imageData(url: URL, referer: URL?, cover: Bool = false, priority: Bool = true, requestID: UUID = UUID()) async -> Data? {
        if !cover { return await MoyePageDataStore.shared.data(url: url, referer: referer, priority: priority, requestID: requestID) }
        return await networkImageData(url: url, referer: referer, cover: true)
    }

    static func networkImageData(url: URL, referer: URL?, cover: Bool = false) async -> Data? {
        let cookies = await cookies()
        guard !Task.isCancelled else { return nil }
        let host = url.host?.lowercased() ?? ""
        let matching = cookies.filter {
            let domain = $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return (host == domain || host.hasSuffix("." + domain)) && (!$0.isSecure || url.scheme == "https")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 40)
        request.setValue(referer?.absoluteString ?? url.deletingLastPathComponent().absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        for (name, value) in HTTPCookie.requestHeaderFields(with: matching) { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await (cover ? coverSession : imageSession).data(for: request)
            guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200,
                  response.mimeType?.hasPrefix("image/") == true, !data.isEmpty else { return nil }
            return data
        } catch { return nil }
    }
}

// Compressed originals are cached on disk; only visible pages are decoded.
// Two network slots remain available when chapter preloading is running.
@MainActor
final class MoyePageDataStore {
    static let shared = MoyePageDataStore()
    private struct Waiter {
        let continuation: CheckedContinuation<Data?, Never>
        var priority: Bool
    }
    private struct Job {
        let id = UUID()
        let url: URL
        let referer: URL?
        var waiting: [UUID: Waiter]
        var priority: Bool { waiting.values.contains { $0.priority } }
    }
    private var directory: URL
    private var files: [String: URL] = [:]
    private var jobs: [String: Job] = [:]
    private var queue: [String] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var background = Set<String>()

    private init() {
        let parent = FileManager.default.temporaryDirectory
        let stale = ((try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("MoyeReader-Preload-") }
        directory = Self.makeDirectory()
        Task.detached(priority: .utility) { stale.forEach { try? FileManager.default.removeItem(at: $0) } }
    }

    private static func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoyeReader-Preload-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func contains(_ url: URL) -> Bool { files[url.absoluteString] != nil }

    func data(url: URL, referer: URL?, priority: Bool, requestID: UUID = UUID()) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let key = url.absoluteString
        if let file = files[key], let cached = await Task.detached(priority: priority ? .userInitiated : .utility, operation: {
            try? Data(contentsOf: file, options: .mappedIfSafe)
        }).value { return cached }
        let token = requestID
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if var job = jobs[key] {
                    job.waiting[token] = Waiter(continuation: continuation, priority: priority)
                    jobs[key] = job
                    if priority { background.remove(key) }
                } else {
                    jobs[key] = Job(url: url, referer: referer, waiting: [token: Waiter(continuation: continuation, priority: priority)])
                    queue.append(key)
                }
                pump()
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel(key: key, token: token) } })
    }

    func promote(url: URL, requestID: UUID) {
        let key = url.absoluteString
        guard var job = jobs[key], var waiter = job.waiting[requestID], !waiter.priority else { return }
        waiter.priority = true
        job.waiting[requestID] = waiter
        jobs[key] = job
        background.remove(key)
        pump()
    }

    private func cancel(key: String, token: UUID) {
        guard var job = jobs[key], let waiting = job.waiting.removeValue(forKey: token) else { return }
        jobs[key] = job
        if job.waiting.isEmpty {
            jobs.removeValue(forKey: key); queue.removeAll { $0 == key }
            tasks.removeValue(forKey: key)?.cancel(); background.remove(key)
        } else if !job.priority, tasks[key] != nil {
            background.insert(key)
        }
        waiting.continuation.resume(returning: nil)
        pump()
    }

    private func pump() {
        // A page that is now visible can reclaim a slot from an in-flight
        // preload. Preserve its subscribers and resume that preload later.
        if tasks.count >= 4, queue.contains(where: { jobs[$0]?.priority == true }),
           let key = background.first {
            tasks.removeValue(forKey: key)?.cancel()
            background.remove(key)
            queue.append(key)
        }
        while tasks.count < 4 {
            let next = queue.firstIndex(where: { jobs[$0]?.priority == true })
                ?? (background.count < 2 ? queue.startIndex < queue.endIndex ? queue.startIndex : nil : nil)
            guard let next else { return }
            let key = queue.remove(at: next)
            guard let job = jobs[key] else { continue }
            if !job.priority { background.insert(key) }
            let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            let destination = directory.appendingPathComponent(name)
            tasks[key] = Task { [weak self] in
                let data = await MoyeRuntimeData.networkImageData(url: job.url, referer: job.referer)
                guard !Task.isCancelled else { return }
                let saved = await Task.detached(priority: .utility) {
                    guard let data else { return false }
                    do { try data.write(to: destination, options: .atomic); return true } catch { return false }
                }.value
                guard let self, !Task.isCancelled, self.jobs[key]?.id == job.id else { return }
                self.tasks.removeValue(forKey: key); self.background.remove(key)
                let waiting = self.jobs.removeValue(forKey: key)?.waiting.values
                if saved { self.files[key] = destination }
                waiting?.forEach { $0.continuation.resume(returning: data) }
                self.pump()
            }
        }
    }

    func clear() {
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        let waiting = jobs.values.flatMap { $0.waiting.values.map(\.continuation) }
        jobs.removeAll(); queue.removeAll(); background.removeAll(); files.removeAll()
        let old = directory; directory = Self.makeDirectory()
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: old) }
        waiting.forEach { $0.resume(returning: nil) }
    }
}
