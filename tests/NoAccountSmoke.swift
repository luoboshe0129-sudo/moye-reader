import AppKit
import WebKit

@main
enum NoAccountSmoke {
    static func main() {
        let app = NSApplication.shared
        let delegate = SmokeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

private final class SmokeDelegate: NSObject, NSApplicationDelegate {
    private var controller: MoyeWindowController!
    private var timer: Timer?
    private var phase = 0
    private var selectionShownAt: Date?
    private let started = Date()
    private let destination = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOYE_SMOKE_OUTPUT"]!)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let first = OnlineMainView.webConfiguration().websiteDataStore
        let second = OnlineMainView.webConfiguration().websiteDataStore
        guard !first.isPersistent, first === second else { finish(false, "Web views must share an in-memory cookie store"); return }
        UserDefaults.standard.set(destination.path, forKey: "MoyeShelf.DownloadDirectory")
        UserDefaults.standard.set("obsolete-test-user", forKey: "MoyeShelf.SessionUser.18comic.vip")
        UserDefaults.standard.set("18comic.vip", forKey: "MoyeShelf.SiteRoute")
        controller = MoyeWindowController()
        controller.showWindow(nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.check() }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    private var views: [NSView] {
        NSApp.windows.flatMap { $0.contentView.map(descendants) ?? [] }
    }
    private func view(_ id: String) -> NSView? { views.first { $0.identifier?.rawValue == id } }
    private func click(_ id: String) { (view(id) as? NSButton)?.performClick(nil) }

    private func check() {
        guard Date().timeIntervalSince(started) < 75 else {
            let texts = views.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " | ")
            finish(false, "Timeout at phase \(phase): \(texts)")
            return
        }
        guard !views.contains(where: { $0 is NSSecureTextField || (($0 as? NSButton)?.title.contains("登录") ?? false) }) else {
            finish(false, "Account UI still exists"); return
        }
        if views.contains(where: { ($0 as? NSTextField)?.stringValue.contains("这一章暂时无法加载") ?? false }) {
            finish(false, "Chapter failed to load"); return
        }
        switch phase {
        case 0:
            guard view("comic-card-100001") != nil else { return }
            phase = 1
            click("comic-card-100001")
        case 1:
            guard let reader = views.first(where: { $0 is MoyeComicReaderView }),
                  descendants(reader).contains(where: { ($0 as? NSImageView)?.image != nil }) else { return }
            phase = 2
            click("reader-back")
        case 2:
            guard !views.contains(where: { $0 is MoyeComicReaderView }), view("chapter-heading") != nil else { return }
            guard let field = view("comic-search-input") as? NSTextField else { finish(false, "Search input missing"); return }
            field.stringValue = "匿名搜索测试"
            phase = 3
            click("comic-search-submit")
        case 3:
            guard view("comic-card-100002") != nil else { return }
            phase = 4
            click("comic-card-100002")
        case 4:
            guard !views.contains(where: { $0 is MoyeComicReaderView }) else {
                finish(false, "Multi-chapter work opened the reader before a chapter was selected"); return
            }
            guard view("chapter-heading") != nil, view("100101") != nil, view("100102") != nil else { return }
            if selectionShownAt == nil { selectionShownAt = Date(); return }
            guard Date().timeIntervalSince(selectionShownAt!) >= 1 else { return }
            phase = 5
            click("100102")
        case 5:
            guard let reader = views.first(where: { $0 is MoyeComicReaderView }),
                  descendants(reader).contains(where: { ($0 as? NSImageView)?.image != nil }) else { return }
            guard descendants(reader).contains(where: { ($0 as? NSTextField)?.stringValue.hasPrefix("第 2 / 2 章") ?? false }) else {
                finish(false, "The selected second chapter was not opened"); return
            }
            phase = 6
            click("reader-download")
        case 6:
            guard view("download-start") != nil else { return }
            phase = 7
            click("download-start")
        case 7:
            guard FileManager.default.fileExists(atPath: destination.appendingPathComponent("匿名测试作品.zip").path) else { return }
            finish(true, "Single-chapter auto-open, multi-chapter selection, chosen chapter reading and anonymous ZIP download passed")
        default: break
        }
    }

    private func finish(_ passed: Bool, _ message: String) {
        timer?.invalidate()
        let report: [String: Any] = ["passed": passed, "phase": phase, "message": message]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: destination.appendingPathComponent("result.json"))
        }
        controller?.prepareToQuit()
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        MoyeReadingCache.shared.stop()
        MoyeRuntimeData.imageSession.invalidateAndCancel()
        MoyeRuntimeData.clearCaches { exit(passed ? 0 : 1) }
    }
}
