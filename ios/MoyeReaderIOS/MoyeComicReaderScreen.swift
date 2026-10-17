import SwiftUI

struct MoyeReaderRoute: Identifiable, Hashable {
    let comic: MoyeComic
    let title: String
    let chapter: MoyeChapter
    let chapters: [MoyeChapter]
    let pages: MoyePageSet
    var id: String { "\(comic.id)-\(chapter.id)" }
}

struct MoyeComicReaderScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var catalog: MoyeCatalogService
    let favorites: MoyeFavoritesStore
    @State private var route: MoyeReaderRoute
    @StateObject private var bridge = MoyeReaderBridge()
    @State private var pageIndex = 0
    @State private var showChrome = true
    @State private var changingChapter = false
    @State private var chapterRequest = UUID()
    @State private var requestOwner = UUID()
    @State private var alertMessage: String?
    @State private var showDownload = false
    @AppStorage("MoyeReader.ReadingMode") private var modeValue = "spread"

    init(route: MoyeReaderRoute, catalog: MoyeCatalogService, favorites: MoyeFavoritesStore? = nil) {
        self.catalog = catalog
        self.favorites = favorites ?? .shared
        _route = State(initialValue: route)
    }
    private var mode: MoyeReadingMode { MoyeReadingMode.resolve(modeValue) }
    private var chapterIndex: Int { route.chapters.firstIndex(where: { $0.id == route.chapter.id }) ?? 0 }
    private var canGoBack: Bool { (mode == .webtoon && !bridge.state.atTop) || pageIndex > 0 || chapterIndex > 0 }
    private var canGoForward: Bool {
        (mode == .webtoon && !bridge.state.atBottom) || (mode == .spread && pageIndex + 2 < route.pages.urls.count) || chapterIndex + 1 < route.chapters.count
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MoyeReaderViewportRepresentable(pages: route.pages, chapter: route.chapter, mode: mode, page: pageIndex, bridge: bridge,
                onTurn: turn, onToggleChrome: { showChrome.toggle() })
                .ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                footer
            }
            .opacity(showChrome ? 1 : 0)
            .animation(.easeInOut(duration: 0.18), value: showChrome)
            .allowsHitTesting(showChrome)
            .accessibilityHidden(!showChrome)
            if changingChapter {
                ProgressView(catalog.loadingMessage.isEmpty ? "正在打开章节…" : catalog.loadingMessage)
                    .padding(15).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .environment(\.colorScheme, .dark)
        .statusBarHidden(!showChrome)
        .onAppear {
            modeValue = mode.rawValue
            bridge.resume()
            MoyeChapterPreloader.shared.start(route: route, catalog: catalog, owner: requestOwner)
        }
        .onChange(of: bridge.state.page) { _, page in if mode != .spread { pageIndex = page } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { bridge.resume() } else if phase == .background { bridge.suspend() }
        }
        .onDisappear {
            chapterRequest = UUID()
            bridge.pauseLoading()
            MoyeChapterPreloader.shared.cancel(owner: requestOwner)
            if changingChapter { catalog.cancel(owner: requestOwner); changingChapter = false }
        }
        .sheet(isPresented: $showDownload) {
            let detail = MoyeComicDetail(comicID: route.comic.id, title: route.title, author: route.comic.author, description: "", coverURL: route.comic.coverURL, chapters: route.chapters)
            MoyeDownloadSheet(comic: route.comic, detail: detail, catalog: catalog)
        }
        .alert("章节暂时无法载入", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("好", role: .cancel) { alertMessage = nil }
        } message: { Text(alertMessage ?? "") }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    chapterRequest = UUID()
                    if changingChapter { catalog.cancel(owner: requestOwner); changingChapter = false }
                    dismiss()
                } label: { Image(systemName: "chevron.left").frame(width: 36, height: 38) }
                    .accessibilityLabel("返回选话")
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(route.chapter.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                MoyeFavoriteButton(comic: route.comic, favorites: favorites)
                Button { showDownload = true } label: { Image(systemName: "arrow.down.to.line").frame(width: 36, height: 38) }
                    .accessibilityLabel("下载章节")
                Menu {
                    ForEach(route.chapters) { chapter in
                        Button { changeChapter(chapter) } label: {
                            if chapter.id == route.chapter.id { Label(chapter.title, systemImage: "book.fill") }
                            else { Text(chapter.title) }
                        }
                    }
                } label: { Image(systemName: "list.number").frame(width: 36, height: 38) }
                .accessibilityLabel("选择章节")
            }
            .padding(.horizontal, 10).padding(.top, 4)
            Picker("阅读方式", selection: Binding(get: { modeValue }, set: { value in
                pageIndex = bridge.state.page
                if value == "spread" { pageIndex = (pageIndex / 2) * 2 }
                modeValue = value
            })) {
                ForEach(MoyeReadingMode.allCases, id: \.rawValue) { mode in Text(mode.title).tag(mode.rawValue) }
            }
            .pickerStyle(.segmented).frame(maxWidth: 520).padding(.horizontal, 12).padding(.vertical, 7)
        }
        .foregroundStyle(.primary).background(.ultraThinMaterial)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            if route.chapters.count > 1 {
                HStack {
                    Button("上一章") { if chapterIndex > 0 { changeChapter(route.chapters[chapterIndex - 1]) } }
                        .disabled(chapterIndex == 0 || changingChapter)
                    Spacer()
                    Text("第 \(chapterIndex + 1) / \(route.chapters.count) 章").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("下一章") { if chapterIndex + 1 < route.chapters.count { changeChapter(route.chapters[chapterIndex + 1]) } }
                        .disabled(chapterIndex + 1 >= route.chapters.count || changingChapter)
                }
                .font(.caption.weight(.semibold))
            }
            HStack(spacing: 24) {
                Button { turn(MoyeReaderNavigation.forward(onLeft: true, mode: mode)) } label: { Image(systemName: mode == .webtoon ? "chevron.up" : "chevron.left").frame(width: 44, height: 34) }
                    .disabled(!(mode == .spread ? canGoForward : canGoBack) || changingChapter)
                    .accessibilityLabel(mode == .spread ? "下一组双页从左侧进入" : "向前一屏")
                Text(pageCounter).font(.caption.monospacedDigit().weight(.semibold)).lineLimit(1)
                Button { turn(MoyeReaderNavigation.forward(onLeft: false, mode: mode)) } label: { Image(systemName: mode == .webtoon ? "chevron.down" : "chevron.right").frame(width: 44, height: 34) }
                    .disabled(!(mode == .spread ? canGoBack : canGoForward) || changingChapter)
                    .accessibilityLabel(mode == .spread ? "上一组双页从右侧进入" : "向后一屏")
            }
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .padding(.horizontal, 18).padding(.vertical, 7).background(.ultraThinMaterial)
    }

    private var pageCounter: String {
        let count = route.pages.urls.count
        if mode == .spread, pageIndex + 1 < count { return "第 \(pageIndex + 1)–\(min(count, pageIndex + 2)) / \(count) 页" }
        return "第 \(min(count, pageIndex + 1)) / \(count) 页"
    }

    private func turn(_ forward: Bool) {
        guard !changingChapter, !route.pages.urls.isEmpty else { return }
        if mode == .webtoon && bridge.advance(forward: forward) { return }
        switch MoyeReaderNavigation.action(mode: mode, forward: forward, page: pageIndex,
            count: route.pages.urls.count, chapter: chapterIndex, chapterCount: route.chapters.count) {
        case .page(let page): bridge.prepareTurn(forward: forward); pageIndex = page
        case .chapter(let index): changeChapter(route.chapters[index])
        case .none: break
        }
    }

    private func changeChapter(_ chapter: MoyeChapter) {
        guard !changingChapter, chapter.id != route.chapter.id else { return }
        chapterRequest = UUID()
        let active = chapterRequest
        bridge.pauseLoading()
        MoyeChapterPreloader.shared.cancel(owner: requestOwner)
        changingChapter = true
        catalog.loadPages(for: route.comic, chapter: chapter, owner: requestOwner) { pages in
            guard chapterRequest == active else { return }
            changingChapter = false
            guard let pages else {
                bridge.resume()
                MoyeChapterPreloader.shared.start(route: route, catalog: catalog, owner: requestOwner)
                alertMessage = catalog.errorMessage ?? "请检查网络后重试。"
                return
            }
            pageIndex = 0
            route = MoyeReaderRoute(comic: route.comic, title: route.title, chapter: chapter, chapters: route.chapters, pages: pages)
            MoyeChapterPreloader.shared.start(route: route, catalog: catalog, owner: requestOwner)
        }
    }
}
