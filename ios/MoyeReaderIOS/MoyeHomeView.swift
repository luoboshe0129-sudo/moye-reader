import SwiftUI

private struct MoyeListingBottom: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private final class MoyeListingPosition {
    var bottom: CGFloat = .greatestFiniteMagnitude
    var height: CGFloat = 0
    var nearEnd: Bool { height > 0 && bottom < height + 120 }
}

enum MoyeSiteRoute: String, CaseIterable, Identifiable, Hashable {
    case internationalVIP = "18comic.vip"
    case internationalINK = "18comic.ink"
    case southeastAsiaOne = "jmcomic-zzz.one"
    case southeastAsiaORG = "jmcomic-zzz.org"

    var id: String { rawValue }
    var rootURL: URL { URL(string: "https://\(rawValue)")! }
    var displayName: String {
        switch self {
        case .internationalVIP: return "国际线路 · 18comic.vip"
        case .internationalINK: return "国际线路 · 18comic.ink"
        case .southeastAsiaOne: return "东南亚线路 · jmcomic-zzz.one"
        case .southeastAsiaORG: return "东南亚线路 · jmcomic-zzz.org"
        }
    }
}

struct MoyeHomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("moye.appearance") private var appearance = "system"
    @StateObject private var catalog: MoyeCatalogService
    @ObservedObject private var favorites: MoyeFavoritesStore
    @State private var showingFavorites: Bool
    @State private var query = ""
    @State private var selectedComic: MoyeComic?
    @State private var showSettings = false
    @State private var rankingOrder = "mv"
    @State private var resultTitle = "每月热看 · 按观看数排序"
    @State private var activeQuery = ""
    @State private var isSearching = false
    @AppStorage("moye.route") private var routeValue = "18comic.vip"
    @AppStorage("moye.columns") private var columns = 2
    @State private var didInitialLoad = false
    @State private var listingPosition = MoyeListingPosition()
    @FocusState private var searchFocused: Bool

    private var route: MoyeSiteRoute { MoyeSiteRoute(rawValue: routeValue) ?? .internationalVIP }

    init(catalog: MoyeCatalogService? = nil, favorites: MoyeFavoritesStore? = nil, showingFavorites: Bool = false) {
        _catalog = StateObject(wrappedValue: catalog ?? MoyeCatalogService(route: .internationalVIP))
        _favorites = ObservedObject(wrappedValue: favorites ?? .shared)
        _showingFavorites = State(initialValue: showingFavorites)
    }

    private var displayComics: [MoyeComic] { showingFavorites ? favorites.comics : catalog.comics }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [colorScheme == .dark ? Color(red: 0.18, green: 0.16, blue: 0.23) : Color(red: 0.94, green: 0.92, blue: 0.99), Color(uiColor: .systemGroupedBackground)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ).ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    searchBox
                    rankingPicker
                    listingHeader
                    if let error = catalog.errorMessage, !catalog.comics.isEmpty, !showingFavorites {
                        Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal, 16)
                    }
                    if catalog.isLoading && !catalog.isAppendingListing && !showingFavorites {
                        HStack(spacing: 8) { ProgressView(); Text(catalog.loadingMessage).font(.caption).lineLimit(2); Spacer(); Button("取消") { catalog.cancel() }.font(.caption) }
                            .padding(.horizontal, 16).padding(.vertical, 7)
                    }
                    if showingFavorites && displayComics.isEmpty {
                        ContentUnavailableView("还没有收藏", systemImage: "heart", description: Text("点击作品卡片、详情页或阅读页的爱心，将想看的作品加入收藏。"))
                            .frame(maxHeight: .infinity)
                    } else if !showingFavorites && catalog.isLoading && catalog.comics.isEmpty {
                        Spacer()
                        ProgressView("正在载入漫画卡片…")
                        Spacer()
                    } else if let error = catalog.errorMessage, catalog.comics.isEmpty, !showingFavorites {
                        ContentUnavailableView {
                            Label("暂时无法载入", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("重试") { reloadListing() }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxHeight: .infinity)
                    } else if displayComics.isEmpty {
                        ContentUnavailableView("没有找到作品", systemImage: "books.vertical", description: Text("换个关键词试试。"))
                            .frame(maxHeight: .infinity)
                    } else {
                        ScrollView {
                          VStack(spacing: 12) {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: displayColumns), alignment: .center, spacing: 16) {
                                ForEach(displayComics) { comic in
                                    Button { selectedComic = comic.onSite(catalog.rootURL); if catalog.isAppendingListing { catalog.cancel() } } label: {
                                        MoyeComicCard(comic: comic, reserveFavoriteSpace: true)
                                    }
                                    .buttonStyle(.plain)
                                    .overlay(alignment: .bottomTrailing) {
                                        MoyeFavoriteButton(comic: comic, favorites: favorites)
                                            .foregroundStyle(.purple)
                                            .background(.regularMaterial, in: Circle())
                                            .padding(.trailing, 5).padding(.bottom, 2)
                                    }
                                }
                            }
                            .frame(maxWidth: 1080)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 14)
                            .padding(.top, 5)
                            if !showingFavorites {
                              loadMoreIndicator.frame(height: 36)
                                .background { GeometryReader { proxy in
                                    Color.clear.preference(key: MoyeListingBottom.self, value: proxy.frame(in: .named("moye-listing")).minY)
                                } }
                            }
                          }
                          .padding(.bottom, 20)
                        }
                        .coordinateSpace(name: "moye-listing")
                        .background { GeometryReader { proxy in
                            Color.clear.onAppear { listingPosition.height = proxy.size.height; loadNextPage() }
                                .onChange(of: proxy.size.height) { _, height in listingPosition.height = height; loadNextPage() }
                        } }
                        .onPreferenceChange(MoyeListingBottom.self) { bottom in
                            listingPosition.bottom = bottom
                            loadNextPage()
                        }

                    }
                }
                .frame(maxWidth: 1120)
                .frame(maxWidth: .infinity)

                // The invisible WebKit engine fetches and parses site data; all
                // browsing results and reader controls remain native SwiftUI.
                MoyeHiddenWebView(webView: catalog.webView)
                    .frame(width: 2, height: 2)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $selectedComic) { comic in
                MoyeDetailScreen(comic: comic, catalog: catalog, favorites: favorites)
            }
            .sheet(isPresented: $showSettings) {
                MoyeSettingsSheet(appearance: $appearance, routeValue: $routeValue, columns: $columns)
            }
            .onChange(of: routeValue) { _, _ in
                catalog.setRoute(route)
                reloadListing()
            }
            .onAppear {
                catalog.setRoute(route)
                guard !didInitialLoad else { return }
                didInitialLoad = true
                DispatchQueue.main.async { reloadListing() }
            }
        }
        .tint(Color(red: 0.48, green: 0.36, blue: 0.66))
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image("MoyeMascot")
                .resizable()
                .scaledToFill()
                .frame(width: 47, height: 47)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("墨夜阅读器")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(showingFavorites ? "我的收藏 · 保存在本机" : resultTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, 16)
        .padding(.top, 9)
        .padding(.bottom, 12)
    }

    private var searchBox: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("作品名、作者名或 JM 车号", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit(performSearch)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .accessibilityLabel("清空")
            }
            Button(action: performSearch) {
                Image(systemName: "arrow.right")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color(red: 0.48, green: 0.36, blue: 0.66), in: RoundedRectangle(cornerRadius: 13))
            }
            .accessibilityLabel("搜索")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 52)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.55), lineWidth: 1))
        .padding(.horizontal, 16)
    }

    private var displayColumns: Int { MoyeComicCardLayout.columnCount(requested: columns) }

    private var rankingPicker: some View {
        HStack(spacing: 8) {
            Button("每月热看") {
                showingFavorites = false
                isSearching = false
                searchFocused = false
                query = ""
                reloadListing()
            }
            .buttonStyle(.bordered).tint(!isSearching && !showingFavorites ? .purple : .secondary)
            .accessibilityIdentifier("show-monthly")
            Button("我的收藏") {
                showingFavorites = true
                searchFocused = false
                catalog.cancel()
            }
                .buttonStyle(.bordered).tint(showingFavorites ? .purple : .secondary)
                .accessibilityIdentifier("show-favorites")
            if !showingFavorites {
                Divider().frame(height: 24)
                Button("按观看数") { rankingOrder = "mv"; reloadListing() }
                    .buttonStyle(.bordered).tint(rankingOrder == "mv" ? .purple : .secondary)
                    .disabled(catalog.isLoading && !catalog.isAppendingListing)
                Button("按点赞数") { rankingOrder = "tf"; reloadListing() }
                    .buttonStyle(.bordered).tint(rankingOrder == "tf" ? .purple : .secondary)
                    .disabled(catalog.isLoading && !catalog.isAppendingListing)
            }
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 16).padding(.vertical, 7)
        .frame(height: 50)
    }

    private var listingHeader: some View {
        HStack {
            Text(showingFavorites ? "我的收藏" : isSearching ? "搜索结果" : "每月热看").font(.headline)
            Spacer()
            HStack(spacing: 4) {
                ForEach(1...3, id: \.self) { count in
                    Button { columns = count } label: {
                        Text("\(count)").font(.caption.weight(.semibold))
                            .frame(width: 34, height: 32)
                            .background(displayColumns == count ? Color.purple.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain).foregroundStyle(displayColumns == count ? .purple : .secondary)
                    .accessibilityLabel("\(count) 列").accessibilityIdentifier("columns-\(count)")
                    .accessibilityAddTraits(displayColumns == count ? .isSelected : [])
                }
            }
            Text("\(displayComics.count) 部").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 17).padding(.top, 7).padding(.bottom, 7)
    }

    @ViewBuilder private var loadMoreIndicator: some View {
        if catalog.hasMoreListing {
            if catalog.isAppendingListing {
                ProgressView("正在加载更多…").font(.caption).padding(10)
            } else if catalog.errorMessage != nil {
                Button("重新加载更多作品") { loadNextPage() }.font(.caption).padding(10)
            } else {
                Color.clear.frame(height: 1)
            }
        }
    }

    private func loadNextPage() {
        guard !showingFavorites, listingPosition.nearEnd, selectedComic == nil, !catalog.isLoading, catalog.hasMoreListing, catalog.listingPage > 0 else { return }
        reloadListing(append: true)
    }

    private func reloadListing(append: Bool = false) {
        guard !showingFavorites else { return }
        let sort = rankingOrder == "tf" ? "点赞数" : "观看数"
        let page = append ? catalog.listingPage + 1 : 1
        if isSearching {
            resultTitle = "搜索结果 · 按\(sort)排序"
            catalog.search(activeQuery, order: rankingOrder, page: page, append: append)
        } else {
            resultTitle = "每月热看 · 按\(sort)排序"
            catalog.loadRanking(order: rankingOrder, page: page, append: append)
        }
    }

    private func performSearch() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        showingFavorites = false
        searchFocused = false
        isSearching = true
        activeQuery = value
        resultTitle = "搜索结果"
        if let id = albumID(from: value) {
            let comic = MoyeComic(id: id, title: "JM \(id)", author: "", metadata: "", tags: [], coverURL: nil, url: catalog.rootURL.appending(path: "album/\(id)"))
            catalog.showDirectResult(comic)
            selectedComic = comic
        } else {
            reloadListing()
        }
    }

    private func albumID(from query: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^\s*(?:JM[-\s]?)?([0-9]{3,})\s*$"#, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(query.startIndex..<query.endIndex, in: query)
        guard let match = regex.firstMatch(in: query, range: range), let idRange = Range(match.range(at: 1), in: query) else { return nil }
        return String(query[idRange])
    }
}

struct MoyeDetailScreen: View {
    let comic: MoyeComic
    let catalog: MoyeCatalogService
    var favorites: MoyeFavoritesStore = .shared

    var body: some View {
        MoyeDetailContent(comic: comic, catalog: catalog, favorites: favorites).id(comic.url)
    }
}

private struct MoyeDetailContent: View {
    let comic: MoyeComic
    @ObservedObject var catalog: MoyeCatalogService
    let favorites: MoyeFavoritesStore
    @StateObject private var session: MoyeWorkSession
    @State private var showDownload = false
    private var detail: MoyeComicDetail? { session.detail }
    private var loading: Bool { session.loading }

    init(comic: MoyeComic, catalog: MoyeCatalogService, favorites: MoyeFavoritesStore) {
        self.comic = comic
        self.catalog = catalog
        self.favorites = favorites
        _session = StateObject(wrappedValue: MoyeWorkSession(comic: comic, catalog: catalog))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                if let detail {
                    HStack(alignment: .top, spacing: 16) {
                        MoyeRemoteImage(url: comic.coverURL ?? detail.coverURL, referer: comic.url, contentMode: .fill)
                            .frame(width: 138, height: 190)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        VStack(alignment: .leading, spacing: 9) {
                            Text(detail.title).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                            if !detail.author.isEmpty { Label(detail.author, systemImage: "person").font(.subheadline).foregroundStyle(.secondary) }
                            Label("JM \(comic.id)", systemImage: "number").font(.subheadline).foregroundStyle(.secondary)
                            Button {
                                guard let first = detail.chapters.first else { session.alertMessage = "这部作品暂时没有可读章节。"; return }
                                session.open(first)
                            } label: {
                                Label("开始阅读", systemImage: "book.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 15)
                                    .padding(.vertical, 10)
                                    .background(Color(red: 0.48, green: 0.36, blue: 0.66), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(session.openingChapter)
                            .padding(.top, 2)
                            Button { showDownload = true } label: {
                                Label("下载章节", systemImage: "arrow.down.to.line")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color(red: 0.48, green: 0.36, blue: 0.66))
                                    .padding(.horizontal, 15)
                                    .padding(.vertical, 9)
                                    .background(Color.purple.opacity(0.10), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(session.openingChapter)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    HStack {
                        Text(detail.chapters.count > 1 ? "请选择要阅读的章节" : "章节").font(.headline)
                        Spacer()
                        Text("\(detail.chapters.count) 话").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 3)

                    if detail.chapters.isEmpty {
                        ContentUnavailableView("暂时没有章节", systemImage: "books.vertical")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 25)
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(detail.chapters.enumerated()), id: \.element.id) { index, chapter in
                                Button { session.open(chapter) } label: {
                                    HStack(spacing: 12) {
                                        Text(String(format: "%02d", index + 1))
                                            .font(.caption.monospacedDigit().weight(.bold))
                                            .foregroundStyle(.purple)
                                            .frame(width: 34, height: 34)
                                            .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                                        Text(chapter.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                            .lineLimit(2).multilineTextAlignment(.leading)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                    }
                                    .padding(11)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(session.openingChapter)
                            }
                        }
                    }
                } else if loading {
                    ProgressView("正在读取作品和章节…")
                        .frame(maxWidth: .infinity, minHeight: 250)
                } else {
                    ContentUnavailableView {
                        Label("作品详情暂时无法读取", systemImage: "exclamationmark.triangle")
                    } actions: {
                        Button("重试") { session.load() }.buttonStyle(.borderedProminent)
                    }
                        .frame(maxWidth: .infinity, minHeight: 250)
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("作品详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                MoyeFavoriteButton(comic: comic.resolved(with: detail), favorites: favorites)
            }
        }
        .navigationDestination(item: $session.readerRoute) { route in
            MoyeComicReaderScreen(route: route, catalog: catalog, favorites: favorites)
        }
        .sheet(isPresented: $showDownload) {
            if let detail {
                MoyeDownloadSheet(comic: comic, detail: detail, catalog: catalog)
            }
        }
        .task(id: comic.id) { session.load() }
        .onChange(of: detail) { _, value in favorites.refresh(comic.resolved(with: value)) }
        .onDisappear { if session.readerRoute == nil { session.cancel() } }
        .alert("无法打开作品", isPresented: Binding(
            get: { session.alertMessage != nil },
            set: { if !$0 { session.alertMessage = nil } }
        )) {
            Button("好", role: .cancel) { session.alertMessage = nil }
        } message: { Text(session.alertMessage ?? "") }
        .overlay {
            if catalog.isLoading && !loading && session.readerRoute == nil {
                ProgressView("正在载入…").padding(14).background(.regularMaterial, in: Capsule())
            }
        }
    }

}

private struct MoyeSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var appearance: String
    @Binding var routeValue: String
    @Binding var columns: Int
    @State private var clearingCache = false
    @State private var cacheMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("站点线路") {
                    Picker("线路", selection: $routeValue) {
                        ForEach(MoyeSiteRoute.allCases) { route in Text(route.displayName).tag(route.rawValue) }
                    }
                }
                Section("外观") {
                    Picker("外观模式", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    Picker("首页列数", selection: $columns) { ForEach(1...3, id: \.self) { Text("\($0) 列").tag($0) } }
                        .pickerStyle(.segmented)
                    Text("始终按所选列数显示。窄卡片会精简介绍，封面保持原比例，等比例填充封面框。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("缓存") {
                    Button {
                        clearingCache = true
                        cacheMessage = nil
                        URLCache.shared.removeAllCachedResponses()
                        MoyeReadingImageCache.covers.clear()
                        MoyeReadingImageCache.shared.clearAll {
                            clearingCache = false
                            cacheMessage = "缓存已清除。"
                        }
                    } label: {
                        if clearingCache {
                            Label("正在清除…", systemImage: "hourglass")
                        } else {
                            Label("立即清除缓存", systemImage: "trash")
                        }
                    }
                    .disabled(clearingCache)
                    if let cacheMessage {
                        Text(cacheMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("阅读时优先加载当前可见页，只预加载附近少量页面。缓存会在 APP 进入后台时自动清除，已导出的 ZIP 文件会保留。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("版本", value: "3.5.16 · iOS/iPadOS")
                    Text("搜索结果、作品详情与阅读页使用原生卡片和控件。网页仅用于后台解析站点数据。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
