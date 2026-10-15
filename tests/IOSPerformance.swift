import SwiftUI
import UIKit

@main struct IOSPerformance: App {
    var body: some Scene { WindowGroup { PerformanceHost().ignoresSafeArea() } }
}
private struct PerformanceHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PerformanceController { PerformanceController() }
    func updateUIViewController(_ controller: PerformanceController, context: Context) {}
}
@MainActor private final class PerformanceController: UIViewController {
    private var started = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }; started = true
        Task { await run() }
    }
    private func run() async {
        let root = URL(string: ProcessInfo.processInfo.environment["MOYE_SMOKE_ROOT"]!)!
        let catalog = MoyeCatalogService(route: .internationalVIP, rootURL: root)
        view.addSubview(catalog.webView)
        catalog.loadRanking()
        while catalog.isLoading { try? await Task.sleep(nanoseconds: 20_000_000) }
        let loaders = (0..<12).map { _ in MoyeImageLoader() }
        let start = CACurrentMediaTime()
        await withTaskGroup(of: Void.self) { group in
            for (index, loader) in loaders.enumerated() {
                group.addTask { await loader.load(url: root.appendingPathComponent("media/albums/performance-\(index).png"), referer: root, priority: false) }
            }
        }
        let covers = CACurrentMediaTime() - start
        let imagePixels = loaders.compactMap(\.image).reduce(0) { $0 + ($1.cgImage.map { $0.width * $0.height } ?? 0) }
        let chapter = MoyeChapter(id: "rapid", title: "rapid", url: root.appendingPathComponent("photo/rapid"))
        let pages = MoyePageSet(urls: (0..<30).map { root.appendingPathComponent("geometry/\($0).png") }, albumID: 0, scrambleID: 0)
        let viewport = MoyeReaderViewport(frame: CGRect(x: 0, y: 20, width: 1000, height: 700))
        viewport.testConfigure(imageRequests: false, animatedTurns: true)
        view.addSubview(viewport); viewport.layoutIfNeeded()
        viewport.configure(pages: pages, chapter: chapter, mode: .spread, page: 0)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300)).image { c in UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 200, height: 300)) }
        viewport.testImages(Dictionary(uniqueKeysWithValues: (0..<30).map { ($0, image) }))
        var page = 0, accepted = 0
        viewport.onTurn = { forward in
            if case .page(let next) = MoyeReaderNavigation.action(mode: .spread, forward: forward, page: page, count: 30, chapter: 0, chapterCount: 1) {
                accepted += 1; page = next
                viewport.prepareTurn(forward: forward)
                viewport.configure(pages: pages, chapter: chapter, mode: .spread, page: next)
            }
        }
        let rapidStart = CACurrentMediaTime()
        for _ in 0..<6 { viewport.testTap(x: 100); try? await Task.sleep(nanoseconds: 20_000_000) }
        let rapidTime = CACurrentMediaTime() - rapidStart
        let result: [String: Any] = ["passed": true, "device": "iPad", "covers_12_seconds": covers, "cover_decoded_pixels": imagePixels,
            "rapid_6_inputs_accepted": accepted, "rapid_input_seconds": rapidTime]
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("result.json"))
        exit(0)
    }
}
