import Foundation
import SwiftUI
import UIKit
import WebKit

@main
struct IOSSmoke: App {
    var body: some Scene { WindowGroup { IOSSmokeHost().ignoresSafeArea() } }
}

private struct IOSSmokeHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> IOSSmokeController { IOSSmokeController() }
    func updateUIViewController(_ controller: IOSSmokeController, context: Context) {}
}

@MainActor
private final class IOSSmokeController: UIViewController {
    private let runner = IOSSmokeDelegate()
    private var started = false
    override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = .black }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started, let window = view.window else { return }
        started = true
        runner.start(in: window)
    }
}

private struct SmokeFailure: Error { let message: String }

@MainActor
final class IOSSmokeDelegate {
    var window: UIWindow?
    private var checks: [String] = []
    private var timings: [String: Double] = [:]
    private var service: MoyeCatalogService!
    private var retainedLoaders: [MoyeCatalogService] = []
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    func start(in window: UIWindow) {
        self.window = window
        print("Smoke started")
        Task {
            do { try await run(); finish(true, message: "iOS native loading, chapter flow, reader geometry and ZIP checks passed") }
            catch { finish(false, message: (error as? SmokeFailure)?.message ?? String(describing: error)) }
        }
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SmokeFailure(message: message) }
    }
    private func wait(_ condition: () -> Bool, _ message: String, timeout: Double = 12) async throws {
        let started = Date()
        while !condition() {
            if Date().timeIntervalSince(started) > timeout { throw SmokeFailure(message: "Timeout: " + message + " · " + (service?.errorMessage ?? "")) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    private func attach(_ loader: MoyeCatalogService) {
        retainedLoaders.append(loader)
        loader.webView.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        window?.rootViewController?.view.addSubview(loader.webView)
    }

    private func run() async throws {
        let root = URL(string: ProcessInfo.processInfo.environment["MOYE_SMOKE_ROOT"]!)!
        service = MoyeCatalogService(route: .internationalVIP, rootURL: root)
        attach(service)
        try require(!service.webView.configuration.websiteDataStore.isPersistent, "Cookie store is persistent")
        var started = Date()
        service.loadRanking()
        let oldNavigation = service.testNavigation
        try await wait({ !service.isLoading }, "monthly homepage")
        timings["monthly_dom_ready"] = Date().timeIntervalSince(started)
        let decorativeWidth = try await service.webView.evaluateJavaScript("document.querySelector('img[src=\"/slow-decoration\"]').naturalWidth") as? Int
        try require(decorativeWidth == 0, "Homepage waited for slow decorative images")
        try require(service.comics.map(\.id) == ["100001", "100002", "100005"], "Homepage cards differ from the shared parser")
        try require(service.comics[0].tags == ["韩漫", "剧情"], "Unverified tags leaked into the card")
        try require(service.comics[0].metadata.contains("点赞 120"), "Desktop metadata rule missing")
        checks.append("DOM-ready homepage, identical card metadata, no account store")

        let singleComic = service.comics[0], multiComic = service.comics[1]
        try await verifyImageQueue(root: root)
        try await verifySequentialWorks(root: root)
        let single = MoyeWorkSession(comic: singleComic, catalog: service)
        started = Date()
        single.load()
        if let oldNavigation { service.webView(service.webView, didFinish: oldNavigation) }
        try await wait({ single.readerRoute != nil || single.alertMessage != nil }, "single-chapter auto-open")
        timings["single_work_open"] = Date().timeIntervalSince(started)
        try require(single.readerRoute?.chapter.id == "100201", "Single chapter did not auto-open")
        try require(single.readerRoute?.pages.urls.count == 2, "Single chapter pages missing")
        try require(timings["single_work_open"]! < 4, "Work waited for slow decorative images")
        single.readerRoute = nil
        single.load()
        try require(single.readerRoute == nil, "Returning to chapter selection reopened the reader")
        checks.append("single chapter auto-opens, returning stays on selection, stale navigation ignored")

        let multi = MoyeWorkSession(comic: multiComic, catalog: service)
        started = Date()
        multi.load()
        try await wait({ multi.detail != nil || multi.alertMessage != nil }, "multi-chapter detail")
        timings["multi_work_open"] = Date().timeIntervalSince(started)
        try require(multi.detail?.chapters.map(\.id) == ["100101", "100102"], "Delayed chapter list was treated as a single chapter")
        try await Task.sleep(nanoseconds: 500_000_000)
        try require(multi.readerRoute == nil && !service.isLoading, "Multi-chapter work auto-opened")
        multi.open(multi.detail!.chapters[1])
        try await wait({ multi.readerRoute != nil || multi.alertMessage != nil }, "chosen second chapter")
        try require(multi.readerRoute?.chapter.id == "100102", "Explicit chapter selection opened the wrong chapter")
        try require(multi.readerRoute?.pages.urls.first?.lastPathComponent == "2.png", "page_arr order was lost")
        try require(single.detail?.coverURL == singleComic.coverURL && multi.detail?.coverURL == multiComic.coverURL, "Chapter thumbnail replaced the original work cover")
        try require(service.comics.first(where: { $0.id == multiComic.id })?.coverURL == multiComic.coverURL, "Opening chapters changed the listing cover")
        checks.append("listing and detail retain original cover after different chapter thumbnails and chapter navigation")
        checks.append("multi-chapter selection, delayed chapter list, explicit second chapter, page ordering")

        service.loadRanking(order: "tf")
        try await wait({ !service.isLoading }, "monthly like sorting")
        try require(service.comics.map(\.id) == ["100003"], "Monthly homepage or delayed cards missing")
        service.search("fixture", page: 2)
        try await wait({ !service.isLoading }, "search page 2")
        try require(service.comics.map(\.id) == ["100004"], "Search paging missing")
        checks.append("monthly-only ranking, like sorting, search pagination")
        service.loadRanking()
        try await wait({ !service.isLoading }, "ranking reset")
        service.loadRanking(page: 2, append: true)
        try await wait({ !service.isLoading }, "append ranking page 2")
        try require(service.comics.map(\.id) == ["100001", "100002", "100005", "100003"] && service.listingPage == 2 && service.hasMoreListing, "Continuous ranking lost cards or duplicated the overlapping work")
        service.loadRanking(page: 3, append: true)
        try await wait({ !service.isLoading }, "ranking end", timeout: 20)
        try require(service.comics.count == 4 && !service.hasMoreListing, "Empty next page removed existing works or failed to stop")
        service.search("fixture")
        try await wait({ !service.isLoading }, "search reset")
        service.search("fixture", page: 2, append: true)
        try await wait({ !service.isLoading }, "append search page 2")
        try require(service.comics.map(\.id) == ["100002", "100004"], "Continuous search replaced the previous page")
        service.loadRanking(order: "tf")
        try await wait({ !service.isLoading }, "duplicate-page ranking")
        service.loadRanking(order: "tf", page: 2, append: true)
        try await wait({ !service.isLoading }, "duplicate-page end")
        try require(service.comics.count == 1 && !service.hasMoreListing, "Repeated last page keeps loading forever")
        checks.append("continuous ranking/search appends, overlap deduplication, empty/repeated page stops loading")
        try require(MoyeReadingMode.allCases.map(\.rawValue) == ["spread", "webtoon"], "Unexpected reading mode remains")
        try require(MoyeReadingMode.resolve("vertical") == .webtoon, "Old continuous mode was not migrated")

        let downloader = MoyeDownloadModel(catalog: service)
        window?.rootViewController?.view.addSubview(downloader.webView)
        downloader.start(comic: multiComic, detail: multi.detail!, chapters: multi.detail!.chapters)
        // Reading and downloading must be allowed to request chapters concurrently.
        let concurrent = MoyeWorkSession(comic: singleComic, catalog: service)
        concurrent.load()
        try await wait({ concurrent.readerRoute != nil }, "reading during download")
        try await wait({ !downloader.isRunning }, "two-chapter ZIP", timeout: 40)
        try require(downloader.archiveURL != nil, "Download failed: " + (downloader.status ?? ""))
        checks.append("independent reading/download, shared anonymous cookies, original PNG ZIP export")

        try await verifyReader(root: root)
        try await verifyChapterPreload(root: root, comic: multiComic)
        try await verifyCoverCards(comic: multiComic)
        try await verifyCoverFill(root: root)
        try await verifyFavorites(comics: [singleComic, multiComic, service.comics[0]])
        try await verifyNativeScreens(comic: multiComic, route: multi.readerRoute!)
        try await verifyLargeListing(root: root)
    }

    private func verifyNativeScreens(comic: MoyeComic, route: MoyeReaderRoute) async throws {
        let root = window!.rootViewController!
        // iPadOS can keep a scene in a floating window despite an orientation
        // request. Render the actual screens at a wide viewport explicitly;
        // geometry/anchor tests above exercise resizing independently.
        let bounds = root.view.bounds.size
        let canvas = UIDevice.current.userInterfaceIdiom == .pad
            ? CGSize(width: max(bounds.width, bounds.height), height: min(bounds.width, bounds.height))
            : bounds
        func add<Content: View>(_ content: Content) -> UIHostingController<Content> {
            let host = UIHostingController(rootView: content)
            root.addChild(host)
            host.view.frame = CGRect(origin: .zero, size: canvas)
            root.view.addSubview(host.view)
            host.didMove(toParent: root)
            return host
        }
        func remove(_ controller: UIViewController) {
            controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
        }
        UserDefaults.standard.set(1, forKey: "moye.columns")
        let home = add(MoyeHomeView(catalog: service).environment(\.scenePhase, .active))
        try await Task.sleep(nanoseconds: 300_000_000)
        try await wait({ !service.isLoading }, "native homepage render")
        try await Task.sleep(nanoseconds: 300_000_000)
        var homeImage = try screenshot(home.view, name: "homepage")
        if UIDevice.current.userInterfaceIdiom == .pad {
            try require(homeImage.size.width > homeImage.size.height, "iPad homepage did not render a wide viewport")
        }
        for columns in 1...3 {
            UserDefaults.standard.set(columns, forKey: "moye.columns")
            try await Task.sleep(nanoseconds: 350_000_000)
            try await wait({ !self.service.isLoading }, "homepage continuous loading", timeout: 20)
            try await wait({ self.service.comics.prefix(columns).allSatisfy { comic in
                guard let url = comic.coverURL else { return true }
                return MoyeReadingImageCache.covers.imageIfCached(url: url, albumID: 0, scrambleID: 0) != nil
            } }, "homepage covers")
            try await Task.sleep(nanoseconds: 150_000_000)
            homeImage = try screenshot(home.view, name: "homepage-\(columns)-columns")
            try require(coverColumnCount(homeImage) == columns, "Selected \(columns) columns were overridden or covers are missing")
        }
        checks.append("actual homepage renders all three manual column choices on phone/tablet, continuous list without fixed pagination")
        remove(home)
        let darkHome = add(MoyeHomeView(catalog: service).environment(\.scenePhase, .active).environment(\.colorScheme, .dark))
        try await Task.sleep(nanoseconds: 300_000_000)
        try await wait({ !service.isLoading }, "dark monthly homepage render")
        try await Task.sleep(nanoseconds: 300_000_000)
        try screenshot(darkHome.view, name: "homepage-dark")
        remove(darkHome)
        let detail = add(NavigationStack { MoyeDetailScreen(comic: comic, catalog: service) }.environment(\.scenePhase, .active))
        try await Task.sleep(nanoseconds: 500_000_000)
        try require(!containsViewport(detail.view), "Native multi-chapter screen auto-opened reader")
        try screenshot(detail.view, name: "chapter-selection")
        remove(detail)
        let reader = add(MoyeComicReaderScreen(route: route, catalog: service).environment(\.scenePhase, .active))
        try await Task.sleep(nanoseconds: 500_000_000)
        guard let viewport = findViewport(reader.view) else { throw SmokeFailure(message: "Native reader did not mount viewport") }
        try screenshot(reader.view, name: "reader-screen")
        let fixedBounds = viewport.bounds
        let fixedOffset = viewport.testOffset
        for _ in 0..<2 {
            viewport.testTap(x: viewport.bounds.midX)
            try await Task.sleep(nanoseconds: 300_000_000)
            try require(viewport.bounds == fixedBounds && abs(viewport.testOffset - fixedOffset) < 1, "Center tap resized or reflowed the reading canvas")
        }
        checks.append("center toggles toolbar opacity while reading canvas size and position remain fixed")
        remove(reader)
        checks.append("native homepage, chapter selector and reader screens rendered at \(Int(canvas.width))×\(Int(canvas.height))")
    }

    private func verifySequentialWorks(root: URL) async throws {
        func comic(_ id: Int) -> MoyeComic {
            MoyeComic(id: "\(id)", title: "Sequential work \(id)", author: "", metadata: "", tags: [], coverURL: nil,
                url: root.appendingPathComponent("album/\(id)"))
        }
        let first = MoyeWorkSession(comic: comic(910001), catalog: service)
        first.load()
        try await wait({ first.detail != nil || first.alertMessage != nil }, "first sequential work")
        try require(first.detail?.comicID == "910001", "First sequential work did not load")
        let second = MoyeWorkSession(comic: comic(910002), catalog: service)
        second.load()
        // Navigation may deliver the first screen's disappearance after the
        // second screen has already started loading on the shared engine.
        first.cancel()
        try await wait({ second.detail != nil || second.alertMessage != nil }, "second work after old disappearance")
        try require(second.detail?.comicID == "910002" && second.alertMessage == nil, "Exiting the first work cancelled the second work's detail request")
        second.open(second.detail!.chapters[0])
        first.cancel()
        try await wait({ second.readerRoute != nil || second.alertMessage != nil }, "second work reading")
        try require(second.readerRoute?.comic.id == "910002", "Old work exit cancelled the new chapter request")
        let third = MoyeWorkSession(comic: comic(910003), catalog: service)
        third.load(); second.cancel()
        try await wait({ third.detail != nil || third.alertMessage != nil }, "third sequential work")
        try require(third.detail?.comicID == "910003", "Third work requires an app restart")
        let retry = MoyeWorkSession(comic: comic(910004), catalog: service)
        retry.load(); retry.cancel(); retry.load()
        try await wait({ retry.detail != nil || retry.alertMessage != nil }, "cancel and reopen work")
        try require(retry.detail?.comicID == "910004", "Cancelled work cannot be reopened")

        func content(_ comic: MoyeComic) -> some View {
            NavigationStack { MoyeDetailScreen(comic: comic, catalog: service) }.environment(\.scenePhase, .active)
        }
        let rootController = window!.rootViewController!
        let host = UIHostingController(rootView: content(comic(910011)))
        rootController.addChild(host); host.view.frame = rootController.view.bounds
        rootController.view.addSubview(host.view); host.didMove(toParent: rootController)
        try await wait({ self.service.currentDetail?.comicID == "910011" && !self.service.isLoading }, "first native work state")
        for id in 910012...910014 {
            host.rootView = content(comic(id))
            try await wait({ self.service.currentDetail?.comicID == "\(id)" && !self.service.isLoading }, "native detail switches to work \(id)")
            try require(!containsViewport(host.view), "Multi-chapter sequential work skipped selection")
        }
        host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
        checks.append("sequential works A/B/C load without restart; old exit cannot cancel new detail/chapter; cancelled work reopens; native detail state changes per work")
    }

    private func containsViewport(_ view: UIView) -> Bool { view is MoyeReaderViewport || view.subviews.contains(where: containsViewport) }
    private func findViewport(_ view: UIView) -> MoyeReaderViewport? {
        if let viewport = view as? MoyeReaderViewport { return viewport }
        return view.subviews.compactMap(findViewport).first
    }

    private func coverColumnCount(_ image: UIImage) -> Int {
        let cg = image.cgImage!
        let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var count = 0, previous = false
        for x in 0..<cg.width {
            var hits = 0
            for y in stride(from: 0, to: cg.height, by: 4) {
                let offset = (y * cg.width + x) * 4
                if abs(Int(bytes[offset]) - 220) < 12 && abs(Int(bytes[offset + 1]) - 30) < 12 && abs(Int(bytes[offset + 2]) - 30) < 12 { hits += 1 }
            }
            let red = hits > 4
            if red && !previous { count += 1 }
            previous = red
        }
        return count
    }

    private func verifyCoverCards(comic: MoyeComic) async throws {
        let root = window!.rootViewController!
        for width in [CGFloat(110), CGFloat(190), CGFloat(300), CGFloat(520)] {
            let metrics = MoyeComicCardLayout.metrics(width: width)
            try require(metrics.cover.height > metrics.cover.width, "Cover box lost portrait proportions")
            try require(metrics.compact ? metrics.cover.maxY < metrics.information.minY : metrics.cover.maxX < metrics.information.minX, "Cover and text overlap")
            let host = UIHostingController(rootView: MoyeComicCard(comic: comic).environment(\.scenePhase, .active).ignoresSafeArea())
            root.addChild(host); host.view.frame = CGRect(x: 0, y: 20, width: width, height: metrics.height)
            root.view.addSubview(host.view); host.didMove(toParent: root)
            try await wait({ MoyeReadingImageCache.covers.imageIfCached(url: comic.coverURL!, albumID: 0, scrambleID: 0) != nil }, "card cover image")
            try await Task.sleep(nanoseconds: 300_000_000)
            let image = try screenshot(host.view, name: "cover-card-\(Int(width))")
            let cg = image.cgImage!
            let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            // Check the top, middle, and bottom of the original portrait cover.
            for (fraction, expected) in [(CGFloat(1.0 / 6), [220, 30, 30]), (0.5, [30, 220, 30]), (5.0 / 6, [30, 30, 220])] {
                let y = Int(metrics.cover.minY + metrics.cover.height * fraction)
                let offset = (y * cg.width + Int(metrics.cover.midX)) * 4
                let observed = (0..<3).map { Int(bytes[offset + $0]) }
                try require((0..<3).allSatisfy { abs(observed[$0] - expected[$0]) < 25 }, "Portrait cover was cropped at width \(width): \(observed) at \(fraction)")
            }
            host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
        }
        checks.append("full portrait covers at 110/190/300/520pt, compact title instead of squeezed description")
    }

    private func verifyCoverFill(root: URL) async throws {
        let controller = window!.rootViewController!
        for shape in ["wide", "tall"] {
          for width in [CGFloat(110), CGFloat(300)] {
            let metrics = MoyeComicCardLayout.metrics(width: width)
            let comic = MoyeComic(id: "ratio-\(shape)", title: "比例检查", author: "", metadata: "", tags: [],
                coverURL: URL(string: root.absoluteString + "/media/cover-ratio-test.png?\(shape)=1"), url: root)
            let host = UIHostingController(rootView: MoyeComicCard(comic: comic).environment(\.scenePhase, .active).ignoresSafeArea())
            controller.addChild(host); host.view.frame = CGRect(x: 0, y: 20, width: width, height: metrics.height)
            controller.view.addSubview(host.view); host.didMove(toParent: controller)
            try await wait({ MoyeReadingImageCache.covers.imageIfCached(url: comic.coverURL!, albumID: 0, scrambleID: 0) != nil }, "ratio cover")
            try await Task.sleep(nanoseconds: 200_000_000)
            let cg = try screenshot(host.view, name: "cover-fill-\(shape)-\(Int(width))").cgImage!
            let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            // The blue source must meet all four edges, and its white circle
            // must remain circular after proportional fill and clipping.
            for point in [CGPoint(x: metrics.cover.midX, y: metrics.cover.minY + 2), CGPoint(x: metrics.cover.midX, y: metrics.cover.maxY - 3),
                          CGPoint(x: metrics.cover.minX + 2, y: metrics.cover.midY), CGPoint(x: metrics.cover.maxX - 3, y: metrics.cover.midY)] {
                let offset = (Int(point.y) * cg.width + Int(point.x)) * 4
                try require(zip([80, 140, 220], (0..<3).map { Int(bytes[offset + $0]) }).allSatisfy { abs($0 - $1) < 20 }, "Cover leaves a border at \(shape)/\(width)")
            }
            var white = CGRect.null
            for y in Int(metrics.cover.minY + 12)..<Int(metrics.cover.maxY - 12) {
                for x in Int(metrics.cover.minX + 12)..<Int(metrics.cover.maxX - 12) {
                    let offset = (y * cg.width + x) * 4
                    if (0..<3).allSatisfy({ bytes[offset + $0] > 220 }) { white = white.union(CGRect(x: x, y: y, width: 1, height: 1)) }
                }
            }
            try require(!white.isNull && abs(white.width - white.height) <= 2, "Cover stretched its original proportions: \(white)")
            host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
          }
        }
        checks.append("wide/tall covers fill every edge at narrow/wide card sizes; rendered circle retains original ratio")
    }

    private func verifyFavorites(comics: [MoyeComic]) async throws {
        let domain = "moye.smoke.favorites.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let favorites = MoyeFavoritesStore(defaults: defaults)
        try require(favorites.comics.isEmpty, "Fresh favorites should be empty")
        for comic in comics { favorites.toggle(comic) }
        try require(favorites.comics.map(\.id) == comics.reversed().map(\.id), "Favorites lost insertion order")
        let changed = MoyeComic(id: comics[0].id, title: "更新后的标题", author: "作者", metadata: "", tags: [],
            coverURL: URL(string: "https://example.invalid/chapter-thumb.png"), url: comics[0].url)
        favorites.refresh(changed)
        let reopened = MoyeFavoritesStore(defaults: defaults)
        try require(reopened.comics.count == 3 && reopened.comics.last?.title == changed.title && reopened.comics.last?.coverURL == comics[0].coverURL, "Favorites persistence changed the cover or metadata")
        let moved = comics[0].onSite(MoyeSiteRoute.southeastAsiaORG.rootURL)
        try require(reopened.contains(moved) && moved.url.host == "jmcomic-zzz.org" && moved.url.path == "/album/\(comics[0].id)" && moved.coverURL == comics[0].coverURL, "Favorite identity or route rebasing failed")
        reopened.toggle(moved)
        try require(reopened.comics.count == 2 && !reopened.contains(comics[0]), "Favorite removal depends on the selected route")
        try require(MoyeFavoritesStore(defaults: defaults).comics.count == 2, "Favorite removal was not persisted")
        reopened.toggle(comics[0])

        let catalog = service.independentLoader()
        let controller = window!.rootViewController!
        let bounds = controller.view.bounds.size
        let canvas = UIDevice.current.userInterfaceIdiom == .pad ? CGSize(width: max(bounds.width, bounds.height), height: min(bounds.width, bounds.height)) : bounds
        UserDefaults.standard.set(1, forKey: "moye.columns")
        let host = UIHostingController(rootView: MoyeHomeView(catalog: catalog, favorites: reopened, showingFavorites: true).environment(\.scenePhase, .active))
        controller.addChild(host); host.view.frame = CGRect(origin: .zero, size: canvas)
        controller.view.addSubview(host.view); host.didMove(toParent: controller)
        try await wait({ reopened.comics.allSatisfy { MoyeReadingImageCache.covers.imageIfCached(url: $0.coverURL!, albumID: 0, scrambleID: 0) != nil } }, "favorite covers")
        for columns in 1...3 {
            UserDefaults.standard.set(columns, forKey: "moye.columns")
            try await Task.sleep(nanoseconds: 300_000_000)
            let image = try screenshot(host.view, name: "favorites-\(columns)-columns")
            try require(coverColumnCount(image) == columns, "Favorites do not reuse the selected card columns")
        }
        for comic in comics { reopened.toggle(comic) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let empty = try screenshot(host.view, name: "favorites-empty")
        try require(coverColumnCount(empty) == 0, "Removed favorites remain in the visible grid")
        try require(catalog.comics.isEmpty && catalog.listingPage == 0 && !catalog.isLoading, "Favorites unexpectedly fetched monthly pages")
        host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
        checks.append("favorites persist metadata and stable covers; remove by work ID across routes; same 1–3 column UI and reactive empty state without fetching monthly pages")
    }

    private func verifyReader(root: URL) async throws {
        let chapter = MoyeChapter(id: "100101", title: "geometry", url: root.appendingPathComponent("photo/100101"))
        func pages(_ count: Int) -> MoyePageSet {
            MoyePageSet(urls: (0..<count).map { root.appendingPathComponent("geometry/\($0).png") }, albumID: 0, scrambleID: 0)
        }
        func image(_ size: CGSize, colors: [UIColor]) -> UIImage {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                for (index, color) in colors.enumerated() {
                    color.setFill()
                    context.fill(CGRect(x: 0, y: CGFloat(index) * size.height / CGFloat(colors.count), width: size.width, height: size.height / CGFloat(colors.count)))
                }
            }
        }
        let normal = image(CGSize(width: 200, height: 300), colors: [.red])
        let other = image(CGSize(width: 200, height: 360), colors: [.blue])
        let long = image(CGSize(width: 200, height: 12000), colors: [.red, .green, .blue])
        let leftLong = image(CGSize(width: 200, height: 12000), colors: [.cyan, .magenta, .yellow])
        let view = MoyeReaderViewport(frame: CGRect(x: 0, y: 40, width: min(1024, window!.bounds.width), height: min(700, window!.bounds.height - 80)))
        view.testConfigure(imageRequests: false, animatedTurns: false)
        window!.rootViewController!.view.addSubview(view)
        view.layoutIfNeeded()
        view.configure(pages: pages(3), chapter: chapter, mode: .spread, page: 0)
        view.testImages([0: normal, 1: other, 2: normal])
        var frames = view.testLayout.frames
        try require(abs(frames[1]!.maxX - frames[0]!.minX) < 0.01, "Normal spread has a seam")
        try require(!view.testLayout.scrolls, "Normal spread unexpectedly scrolls")
        try screenshot(view, name: "normal-spread")
        view.configure(pages: pages(3), chapter: chapter, mode: .spread, page: 2)
        try require(abs(view.testLayout.frames[2]!.midX - view.bounds.midX) < 0.01, "Odd final page is not centered")
        checks.append("normal spread zero seam, odd page centered")

        view.configure(pages: pages(3), chapter: chapter, mode: .spread, page: 0)
        view.testImages([0: long, 1: leftLong])
        frames = view.testLayout.frames
        try require(view.testLayout.scrolls && abs(frames[0]!.height / frames[0]!.width - 60) < 0.01, "Tall spread lost image ratio")
        try require(frames[1]!.maxX == frames[0]!.minX, "Tall spread has a seam")
        let middle = frames[0]!.height * 0.5
        view.testScroll(to: middle)
        let middleImage = try screenshot(view, name: "tall-spread-middle")
        try verifySpreadPixels(middleImage, left: [255, 0, 255], right: [0, 255, 0])
        try require(view.testSliceFrames.allSatisfy { $0.height <= view.bounds.height * 2 + 1 }, "Tall page backing view is unbounded")
        let fraction = view.testOffset / frames[0]!.height
        view.frame.size = CGSize(width: min(700, view.bounds.height), height: min(700, view.bounds.width))
        view.setNeedsLayout(); view.layoutIfNeeded()
        try require(abs(view.testOffset / view.testLayout.frames[0]!.height - fraction) < 0.01, "Rotation lost reading position")
        view.configure(pages: pages(3), chapter: chapter, mode: .webtoon, page: 0)
        try require(abs(view.testOffset / view.testLayout.frames[0]!.height - fraction) < 0.01, "Mode switch lost reading position")
        try require(view.testLayout.frames[0]!.maxY == view.testLayout.frames[1]!.minY, "Webtoon has a page gap")
        view.configure(pages: pages(3), chapter: chapter, mode: .spread, page: 0)
        view.testImages([0: long, 1: leftLong])
        view.testScroll(to: view.testLayout.contentSize.height - view.bounds.height)
        try require(!view.scrollOneScreen(forward: true), "Bottom of spread failed to release next-page action")
        let bottomImage = try screenshot(view, name: "tall-spread-bottom")
        try verifySpreadPixels(bottomImage, left: [255, 255, 0], right: [0, 0, 255])
        checks.append("tall spread full ratio, bounded drawing, rotation/mode anchor, complete bottom pixels")

        view.configure(pages: pages(3), chapter: chapter, mode: .spread, page: 0)
        view.testImages([0: long, 1: normal])
        try require(view.testLayout.frames[0]!.minY == view.testLayout.frames[1]!.minY, "Mixed pages are not top-aligned")
        try require(abs(view.testLayout.frames[1]!.height / view.testLayout.frames[1]!.width - 1.5) < 0.01, "Mixed normal page was stretched")
        view.configure(pages: pages(400), chapter: chapter, mode: .webtoon, page: 0)
        view.testImages(Dictionary(uniqueKeysWithValues: (0..<400).map { ($0, normal) }))
        view.testScroll(to: view.testLayout.frames[200]!.minY + view.testLayout.frames[200]!.height * 0.4)
        let before = view.testOffset
        view.testImages([0: long])
        let anchored = view.testLayout.frames[200]!.minY + view.testLayout.frames[200]!.height * 0.4
        try require(abs(view.testOffset - anchored) < 1 && view.testOffset > before, "Delayed dimensions above viewport moved the reading anchor")
        try require(view.testSliceFrames.count < 8, "Long chapter mounted every page")
        checks.append("mixed image ratios, 400-page virtualization, late image dimensions preserve anchor")
        view.configure(pages: pages(1), chapter: chapter, mode: .webtoon, page: 0)
        view.testImages([0: long])
        let dragBase = view.bounds.height * 8
        view.testScroll(to: dragBase)
        let stableFrame = view.testSliceFrames.first!
        var cropChanges = 0
        for step in Array(1...120) + Array((0..<120).reversed()) {
            let offset = dragBase + CGFloat(step) * 0.375
            view.testScroll(to: offset)
            // SwiftUI may send the same reader configuration during a drag.
            view.configure(pages: pages(1), chapter: chapter, mode: .webtoon, page: 0)
            if view.testSliceFrames.first != stableFrame { cropChanges += 1 }
            try require(abs(view.testOffset - offset) < 1, "Webtoon drawing changed the native scroll position")
            let visible = CGRect(x: 0, y: view.testOffset, width: view.bounds.width, height: view.bounds.height)
            try require(view.testSliceFrames.first!.contains(visible), "Webtoon drawing leaves a blank edge during a small drag")
            if step % 8 == 0 { try await Task.sleep(nanoseconds: 8_000_000) }
        }
        try require(cropChanges == 0, "Webtoon repeatedly re-crops its backing image during fractional up/down dragging")
        for step in Array(1...12) + Array((0..<12).reversed()) {
            let offset = dragBase + CGFloat(step) * view.bounds.height * 0.55 + 0.375
            view.testScroll(to: offset)
            let visible = CGRect(x: 0, y: view.testOffset, width: view.bounds.width, height: view.bounds.height)
            try require(view.testSliceFrames.first!.contains(visible), "Webtoon drawing window fails to cover a long forward/reverse drag")
            try require(view.testSliceFrames.first!.height <= view.bounds.height * 2 + 1, "Stable webtoon crop has an unbounded backing image")
        }
        // Resizing and late dimensions must still retain the reading anchor.
        let oldFraction = view.testOffset / view.testLayout.frames[0]!.height
        view.frame.size.width -= 20
        view.setNeedsLayout(); view.layoutIfNeeded()
        try require(abs(view.testOffset / view.testLayout.frames[0]!.height - oldFraction) < 0.01, "Stable webtoon crop broke resize anchoring")
        checks.append("webtoon fractional forward/reverse drag keeps crop fixed, native offset untouched, overscan covers long drags and resize")
        view.configure(pages: pages(4), chapter: chapter, mode: .spread, page: 0)
        view.testImages([0: long, 1: leftLong, 2: normal, 3: other])
        view.testScroll(to: view.testLayout.frames[0]!.height * 0.4)
        view.testConfigure(imageRequests: false, animatedTurns: true)
        var selectedPage = 0
        view.onTurn = { forward in
            if case .page(let next) = MoyeReaderNavigation.action(mode: .spread, forward: forward,
                page: selectedPage, count: 4, chapter: 0, chapterCount: 1) {
                selectedPage = next
                view.prepareTurn(forward: forward)
                view.configure(pages: pages(4), chapter: chapter, mode: .spread, page: next)
            }
        }
        view.testTap(x: view.bounds.width / 6)
        try require(selectedPage == 2 && view.testOffset == 0, "Left-side tap scrolled vertically instead of paging")
        try require(UIAccessibility.isReduceMotionEnabled || (view.testIsTurning && view.testTurnTravel > 0), "Next spread did not enter from the left")
        try await Task.sleep(nanoseconds: 100_000_000)
        if let translation = view.testPresentationTranslation {
            try require(translation.x < -1 && translation.x > -view.bounds.width && abs(translation.y) < 1, "Next spread does not move from left toward right")
        }
        if let translation = view.testOutgoingTranslation {
            try require(translation.x > 1 && abs(translation.y) < 1, "Left tap outgoing spread did not move right")
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        try require(!view.testIsTurning && view.testHorizontalTranslation == 0, "Turn animation did not finish")
        view.testTap(x: view.bounds.width * 5 / 6)
        try require(selectedPage == 0, "Right-side tap failed to return to the previous spread")
        try await Task.sleep(nanoseconds: 100_000_000)
        if let translation = view.testPresentationTranslation {
            try require(translation.x > 1 && translation.x < view.bounds.width && abs(translation.y) < 1, "Previous spread does not enter from right toward left")
        }
        if let translation = view.testOutgoingTranslation {
            try require(translation.x < -1 && abs(translation.y) < 1, "Right tap outgoing spread did not move left")
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        view.testScroll(to: view.testLayout.frames[0]!.height * 0.4)
        let preservedOffset = view.testOffset
        view.testTap(x: view.bounds.width * 5 / 6)
        try require(selectedPage == 0 && view.testOffset == preservedOffset, "Right-side tap unexpectedly scrolled within the first spread")
        view.onTurn = nil
        try require(MoyeReaderNavigation.forward(onLeft: true, mode: .spread) && !MoyeReaderNavigation.forward(onLeft: false, mode: .spread), "Footer buttons reverse the physical tap directions")
        view.configure(pages: pages(20), chapter: chapter, mode: .spread, page: 0)
        var accepted = 0
        selectedPage = 0
        view.onTurn = { forward in
            guard case .page(let next) = MoyeReaderNavigation.action(mode: .spread, forward: forward, page: selectedPage, count: 20, chapter: 0, chapterCount: 1) else { return }
            accepted += 1; selectedPage = next
            view.prepareTurn(forward: forward)
            view.configure(pages: pages(20), chapter: chapter, mode: .spread, page: next)
        }
        let rapidStart = CACurrentMediaTime()
        for _ in 0..<6 {
            view.testTap(x: view.bounds.width / 6)
            try await Task.sleep(nanoseconds: 20_000_000)
            try require(view.testOutgoingCount <= 2, "Interrupted turns accumulate unbounded backing views")
        }
        timings["six_rapid_turn_inputs"] = CACurrentMediaTime() - rapidStart
        try require(accepted == 6 && selectedPage == 12, "Rapid taps were blocked until animation completion")
        try await Task.sleep(nanoseconds: 250_000_000)
        try require(!view.testIsTurning && view.testOutgoingCount == 0, "Rapid turns retained old page views")
        view.onTurn = nil
        checks.append("next spread enters from left, previous from right; all six 20ms-spaced taps accepted; bounded GPU page views")
        view.removeFromSuperview()
        let encoded = MoyePageExporter.encode(image: normal, original: normal.pngData(), url: root.appendingPathComponent("normal.png"), restored: false)
        try require(encoded?.fileExtension == "png" && encoded?.data == normal.pngData(), "Original PNG changed on export")
    }

    private func verifyImageQueue(root: URL) async throws {
        MoyeChapterPreloader.shared.cancel()
        MoyeReadingImageCache.shared.clear()
        MoyePageDataStore.shared.clear()
        let cache = MoyeReadingImageCache.shared
        let view = MoyeReaderViewport(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        view.testConfigure(imageRequests: true, animatedTurns: false)
        window!.rootViewController!.view.addSubview(view)
        view.layoutIfNeeded()
        func pages(_ chapter: Int, fast: Bool = false) -> MoyePageSet {
            MoyePageSet(urls: (1...12).map { URL(string: "media/reader-queue/\(chapter)/\($0).png" + (fast ? "?fast=1" : ""), relativeTo: root)!.absoluteURL }, albumID: chapter, scrambleID: 0)
        }
        func chapter(_ id: Int) -> MoyeChapter { MoyeChapter(id: "\(id)", title: "queue", url: root.appendingPathComponent("photo/\(id)")) }
        func loaded(_ pages: MoyePageSet, _ indices: [Int]) -> Bool {
            indices.allSatisfy { cache.imageIfCached(url: pages.urls[$0], albumID: pages.albumID, scrambleID: 0) != nil }
        }
        func count(_ prefix: String) async throws -> Int {
            var url = URLComponents(url: root.appendingPathComponent("fixture/queue-count"), resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "prefix", value: prefix)]
            let (data, _) = try await URLSession.shared.data(from: url.url!)
            return try JSONDecoder().decode(Int.self, from: data)
        }
        // Seed only the first four images, then stall the two background raw
        // requests. The fifth/sixth images are already queued as nearby pages.
        // Making them visible must promote the existing requests end to end.
        let initial = pages(880001, fast: true)
        view.configure(pages: initial, chapter: chapter(880001), mode: .spread, page: 0)
        try await wait({ loaded(initial, [0, 1, 2, 3]) }, "first four queue pages")
        let blockers = (1...2).map { index in Task {
            await MoyePageDataStore.shared.data(url: root.appendingPathComponent("media/queue-blockers/\(index).png"), referer: root, priority: false)
        } }
        var started = CACurrentMediaTime()
        while try await count("/media/queue-blockers/") < 2 {
            try require(CACurrentMediaTime() - started < 3, "Background blockers did not start")
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        started = CACurrentMediaTime()
        let promotedURL = root.appendingPathComponent("media/geometry/promoted.png")
        var promoted = false
        let preview = cache.request(url: promotedURL, referer: root, albumID: 0, scrambleID: 0, priority: false) { _ in }
        try await Task.sleep(nanoseconds: 100_000_000)
        let visible = cache.request(url: promotedURL, referer: root, albumID: 0, scrambleID: 0, priority: true) { promoted = $0 != nil }
        try await wait({ promoted }, "visible request promoted past background queue", timeout: 1.5)
        timings["promoted_visible_image"] = CACurrentMediaTime() - started
        if let preview { cache.cancel(preview) }; if let visible { cache.cancel(visible) }
        view.configure(pages: initial, chapter: chapter(880001), mode: .spread, page: 2)
        try await Task.sleep(nanoseconds: 150_000_000)
        started = CACurrentMediaTime()
        view.configure(pages: initial, chapter: chapter(880001), mode: .spread, page: 4)
        try await wait({ loaded(initial, [4, 5]) }, "fifth and sixth pages stayed at preload priority", timeout: 1.5)
        timings["fifth_sixth_visible_images"] = CACurrentMediaTime() - started
        blockers.forEach { $0.cancel() }
        for task in blockers { _ = await task.value }
        // Visible subscribers can leave originals with preload subscribers.
        // Those downloads must become interruptible background work again.
        let sharedURLs = (1...4).map { root.appendingPathComponent("media/queue-blockers/shared/\($0).png") }
        let background = sharedURLs.map { url in Task { await MoyePageDataStore.shared.data(url: url, referer: root, priority: false) } }
        try await Task.sleep(nanoseconds: 100_000_000)
        let foreground = sharedURLs.map { url in Task { await MoyePageDataStore.shared.data(url: url, referer: root, priority: true) } }
        started = CACurrentMediaTime()
        while try await count("/media/queue-blockers/shared/") < 4 {
            try require(CACurrentMediaTime() - started < 3, "Shared requests did not fill network slots")
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        foreground.forEach { $0.cancel() }
        for task in foreground { _ = await task.value }
        var reclaimed = false
        started = CACurrentMediaTime()
        let urgent = Task { reclaimed = await MoyeRuntimeData.imageData(url: root.appendingPathComponent("media/geometry/reclaimed.png"), referer: root) != nil }
        try await wait({ reclaimed }, "preloads retained all foreground slots", timeout: 1.5)
        timings["reclaim_preload_slot"] = CACurrentMediaTime() - started
        urgent.cancel()
        background.forEach { $0.cancel() }
        for task in background { _ = await task.value }
        // Four slow requests from an old spread must not occupy the next
        // spread or another chapter until their network timeouts expire.
        for id in 880002...880003 {
            let current = pages(id)
            view.configure(pages: current, chapter: chapter(id), mode: .spread, page: 4)
            started = CACurrentMediaTime()
            while try await count("/media/reader-queue/\(id)/") < 4 {
                try require(CACurrentMediaTime() - started < 3, "Old spread requests did not start")
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            started = CACurrentMediaTime()
            view.configure(pages: current, chapter: chapter(id), mode: .spread, page: 8)
            try await wait({ loaded(current, [8, 9]) }, "later spread blocked by old images", timeout: 1.5)
            timings["skip_stalled_spread"] = CACurrentMediaTime() - started
            view.configure(pages: current, chapter: chapter(id), mode: .spread, page: 4)
            try await Task.sleep(nanoseconds: 100_000_000)
            let next = pages(id + 10)
            started = CACurrentMediaTime()
            view.configure(pages: next, chapter: chapter(id + 10), mode: .spread, page: 0)
            try await wait({ loaded(next, [0, 1, 2, 3]) }, "new chapter blocked by old images", timeout: 1.5)
            timings["chapter_images_after_stalled_requests"] = CACurrentMediaTime() - started
        }
        let abandoned = pages(880009)
        view.configure(pages: abandoned, chapter: chapter(880009), mode: .spread, page: 4)
        try await Task.sleep(nanoseconds: 150_000_000)
        MoyeReaderViewportRepresentable.dismantleUIView(view, coordinator: ())
        let replacement = MoyeReaderViewport(frame: view.frame)
        replacement.testConfigure(imageRequests: true, animatedTurns: false)
        window!.rootViewController!.view.addSubview(replacement)
        let replacementPages = pages(880019)
        replacement.configure(pages: replacementPages, chapter: chapter(880019), mode: .spread, page: 0)
        try await wait({ loaded(replacementPages, [0, 1]) }, "closed reader retained image requests", timeout: 1.5)
        MoyeReaderViewportRepresentable.dismantleUIView(replacement, coordinator: ())
        replacement.removeFromSuperview()
        view.removeFromSuperview()
        cache.clear()
        MoyePageDataStore.shared.clear()
        checks.append("visible image promotion bypasses stalled preloads; obsolete spread/chapter requests release slots immediately")
    }

    private func verifyChapterPreload(root: URL, comic: MoyeComic) async throws {
        let chapters = (850001...850003).map { id in MoyeChapter(id: "\(id)", title: "preload \(id)", url: root.appendingPathComponent("photo/\(id)")) }
        func urls(_ id: String) -> [URL] { (1...12).map { root.appendingPathComponent("media/photos/\(id)/\($0).png") } }
        let pages = MoyePageSet(urls: urls(chapters[0].id), albumID: 850001, scrambleID: 0)
        let route = MoyeReaderRoute(comic: comic, title: comic.title, chapter: chapters[0], chapters: chapters, pages: pages)
        let oldOwner = UUID(), activeOwner = UUID()
        MoyeChapterPreloader.shared.start(route: route, catalog: service, owner: oldOwner)
        MoyeChapterPreloader.shared.start(route: route, catalog: service, owner: activeOwner)
        MoyeChapterPreloader.shared.cancel(owner: oldOwner)
        let expected = urls(chapters[0].id) + urls(chapters[1].id)
        try await wait({ expected.allSatisfy { MoyePageDataStore.shared.contains($0) } }, "current and next chapter originals")
        try require(urls(chapters[2].id).allSatisfy { !MoyePageDataStore.shared.contains($0) }, "Preloaded beyond the next chapter")
        let start = CACurrentMediaTime()
        let cached = await MoyeRuntimeData.imageData(url: expected.last!, referer: chapters[1].url)
        timings["preloaded_page_read"] = CACurrentMediaTime() - start
        try require(cached != nil, "Preloaded page cannot be reused")
        MoyeChapterPreloader.shared.cancel(owner: activeOwner)
        checks.append("all 24 current/next chapter originals preload without turning pages; later chapter untouched; stale reader exit cannot cancel active preload")
    }

    private func verifyLargeListing(root: URL) async throws {
        _ = try await URLSession.shared.data(from: root.appendingPathComponent("fixture/long-list-on"))
        let controller = window!.rootViewController!
        let catalog = service.independentLoader()
        let home = UIHostingController(rootView: MoyeHomeView(catalog: catalog).environment(\.scenePhase, .active))
        controller.addChild(home)
        home.view.frame = CGRect(x: 0, y: 0, width: 1000, height: 760)
        controller.view.addSubview(home.view); home.didMove(toParent: controller)
        try await wait({ catalog.comics.count == 80 && !catalog.isLoading }, "80-card native homepage")
        try await Task.sleep(nanoseconds: 650_000_000)
        try require(catalog.listingPage == 1 && catalog.comics.count == 80, "Homepage started loading later pages before scrolling near the end")
        let loaded = catalog.comics.filter { comic in
            comic.coverURL.map { MoyeReadingImageCache.covers.imageIfCached(url: $0, albumID: 0, scrambleID: 0) != nil } ?? false
        }.count
        try require(loaded < 60, "Offscreen covers were eagerly fetched and decoded")
        func scrollView(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.bounds.width > 300, scroll.bounds.height > 300 { return scroll }
            return view.subviews.compactMap(scrollView).first
        }
        guard let scroll = scrollView(home.view) else { throw SmokeFailure(message: "Native listing scroll view missing") }
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
        try await wait({ catalog.listingPage == 2 && !catalog.isLoading }, "load next page near the bottom")
        try require(catalog.comics.count == 160, "Continuous list lost previous results")
        home.willMove(toParent: nil); home.view.removeFromSuperview(); home.removeFromParent()
        _ = try await URLSession.shared.data(from: root.appendingPathComponent("fixture/long-list-off"))
        checks.append("80-card list remains on page 1 without scrolling, offscreen covers stay lazy, bottom scroll appends page 2")
    }

    private func verifySpreadPixels(_ image: UIImage, left: [Int], right: [Int]) throws {
        let cg = image.cgImage!
        let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        for (x, expected) in [(cg.width / 4, left), (cg.width * 3 / 4, right)] {
            let offset = (cg.height / 2 * cg.width + x) * 4
            try require((0..<3).allSatisfy { abs(Int(bytes[offset + $0]) - expected[$0]) < 20 }, "Tall page pixels were missing or painted over the adjacent column")
        }
    }

    @discardableResult private func screenshot(_ view: UIView, name: String) throws -> UIImage {
        func display(_ view: UIView) { view.layer.displayIfNeeded(); view.subviews.forEach(display) }
        view.layoutIfNeeded()
        display(view)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
        try image.pngData()!.write(to: documents.appendingPathComponent(name + ".png"))
        return image
    }
    private func finish(_ passed: Bool, message: String) {
        let report: [String: Any] = ["passed": passed, "message": message, "checks": checks, "timings_seconds": timings,
                                  "device": UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: documents.appendingPathComponent("result.json"))
        retainedLoaders.forEach { $0.cancel() }
        MoyeReadingImageCache.shared.clear()
        exit(passed ? 0 : 1)
    }
}
