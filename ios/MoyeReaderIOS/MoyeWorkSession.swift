import Foundation
import SwiftUI

// All entry points use the same loading and chapter-selection policy.
@MainActor
final class MoyeWorkSession: ObservableObject {
    @Published private(set) var detail: MoyeComicDetail?
    @Published private(set) var loading = false
    @Published private(set) var openingChapter = false
    @Published var readerRoute: MoyeReaderRoute?
    @Published var alertMessage: String?
    private let comic: MoyeComic
    private let catalog: MoyeCatalogService
    private let requestOwner = UUID()
    private var request = UUID()
    private var didAutoOpen = false

    init(comic: MoyeComic, catalog: MoyeCatalogService) { self.comic = comic; self.catalog = catalog }

    func load() {
        guard detail == nil, !loading else { return }
        request = UUID()
        let active = request
        loading = true
        catalog.loadDetail(comic, owner: requestOwner) { [weak self] result in
            guard let self, self.request == active else { return }
            self.loading = false
            guard let result else { self.alertMessage = self.catalog.errorMessage ?? "请稍后重试。"; return }
            self.detail = result
            if let chapter = result.automaticChapter, !self.didAutoOpen {
                self.didAutoOpen = true
                self.open(chapter)
            }
        }
    }

    func open(_ chapter: MoyeChapter) {
        guard !loading, !openingChapter else { return }
        request = UUID()
        let active = request
        openingChapter = true
        alertMessage = nil
        MoyeChapterPreloader.shared.cancel()
        catalog.loadPages(for: comic, chapter: chapter, owner: requestOwner) { [weak self] pages in
            guard let self, self.request == active else { return }
            self.openingChapter = false
            guard let pages else { self.alertMessage = self.catalog.errorMessage ?? "这一章暂时无法读取。"; return }
            self.readerRoute = MoyeReaderRoute(comic: self.comic.resolved(with: self.detail), title: self.detail?.title ?? self.comic.title,
                chapter: chapter, chapters: self.detail?.chapters ?? [chapter], pages: pages)
            MoyeChapterPreloader.shared.start(route: self.readerRoute!, catalog: self.catalog)
        }
    }

    func cancel() {
        request = UUID()
        loading = false; openingChapter = false
        catalog.cancel(owner: requestOwner)
    }
}

@MainActor
final class MoyeChapterPreloader {
    static let shared = MoyeChapterPreloader()
    private var task: Task<Void, Never>?
    private var loader: MoyeCatalogService?
    private var chapterURL: URL?
    private var owner: UUID?

    func start(route: MoyeReaderRoute, catalog: MoyeCatalogService, owner: UUID? = nil) {
        if chapterURL == route.chapter.url {
            if let owner { self.owner = owner }
            return
        }
        task?.cancel(); loader?.cancel()
        chapterURL = route.chapter.url
        self.owner = owner
        task = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await Self.preload(route.pages, referer: route.chapter.url) }
                if let index = route.chapters.firstIndex(where: { $0.id == route.chapter.id }), index + 1 < route.chapters.count {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    let loader: MoyeCatalogService
                    if let existing = self.loader, existing.rootURL == catalog.rootURL { loader = existing }
                    else { loader = catalog.independentLoader(); self.loader = loader }
                    let next = route.chapters[index + 1]
                    let pages: MoyePageSet? = await withCheckedContinuation { continuation in
                        loader.loadPages(for: route.comic, chapter: next) { continuation.resume(returning: $0) }
                    }
                    if let pages, !Task.isCancelled {
                        group.addTask { await Self.preload(pages, referer: next.url) }
                    }
                }
            }
        }
    }

    private static func preload(_ pages: MoyePageSet, referer: URL) async {
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func enqueue() {
                let url = pages.urls[next]
                next += 1
                group.addTask { _ = await MoyePageDataStore.shared.data(url: url, referer: referer, priority: false) }
            }
            for _ in 0..<min(2, pages.urls.count) { enqueue() }
            while await group.next() != nil {
                guard !Task.isCancelled else { group.cancelAll(); return }
                if next < pages.urls.count { enqueue() }
            }
        }
    }

    func cancel(owner expected: UUID? = nil) {
        if let expected, expected != owner { return }
        task?.cancel(); task = nil; loader?.cancel(); chapterURL = nil; owner = nil
    }
}
