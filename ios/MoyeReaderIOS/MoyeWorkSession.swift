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
        catalog.loadPages(for: comic, chapter: chapter, owner: requestOwner) { [weak self] pages in
            guard let self, self.request == active else { return }
            self.openingChapter = false
            guard let pages else { self.alertMessage = self.catalog.errorMessage ?? "这一章暂时无法读取。"; return }
            self.readerRoute = MoyeReaderRoute(comic: self.comic, title: self.detail?.title ?? self.comic.title,
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

    func start(route: MoyeReaderRoute, catalog: MoyeCatalogService) {
        guard chapterURL != route.chapter.url else { return }
        task?.cancel(); loader?.cancel()
        chapterURL = route.chapter.url
        task = Task {
            await withTaskGroup(of: Void.self) { group in
                func enqueue(_ pages: MoyePageSet, referer: URL) {
                    for url in pages.urls {
                        group.addTask {
                            _ = await MoyePageDataStore.shared.data(url: url, referer: referer, priority: false)
                        }
                    }
                }
                enqueue(route.pages, referer: route.chapter.url)
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
                    if let pages, !Task.isCancelled { enqueue(pages, referer: next.url) }
                }
            }
        }
    }

    func cancel() {
        task?.cancel(); task = nil; loader?.cancel(); loader = nil; chapterURL = nil
    }
}
