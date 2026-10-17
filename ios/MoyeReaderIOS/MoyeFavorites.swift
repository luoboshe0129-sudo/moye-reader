import SwiftUI

@MainActor
final class MoyeFavoritesStore: ObservableObject {
    static let shared = MoyeFavoritesStore()
    @Published private(set) var comics: [MoyeComic]
    private let defaults: UserDefaults
    private let key = "moye.favorites.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var seen = Set<String>()
        comics = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([MoyeComic].self, from: $0) }?
            .filter { seen.insert($0.id).inserted } ?? []
    }

    func contains(_ comic: MoyeComic) -> Bool { comics.contains { $0.id == comic.id } }

    func toggle(_ comic: MoyeComic) {
        if contains(comic) { comics.removeAll { $0.id == comic.id } }
        else { comics.insert(comic, at: 0) }
        save()
    }

    // Fill missing metadata after a direct JM search without replacing the
    // original cover or changing the order of an existing collection.
    func refresh(_ comic: MoyeComic) {
        guard let index = comics.firstIndex(where: { $0.id == comic.id }) else { return }
        let previous = comics[index]
        let updated = MoyeComic(id: previous.id, title: comic.title, author: comic.author,
            metadata: previous.metadata.isEmpty ? comic.metadata : previous.metadata,
            tags: previous.tags.isEmpty ? comic.tags : previous.tags,
            coverURL: previous.coverURL ?? comic.coverURL, url: previous.url)
        guard previous != updated else { return }
        comics[index] = updated
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(comics) { defaults.set(data, forKey: key) }
    }
}

struct MoyeFavoriteButton: View {
    let comic: MoyeComic
    @ObservedObject var favorites: MoyeFavoritesStore

    var body: some View {
        Button { favorites.toggle(comic) } label: {
            Image(systemName: favorites.contains(comic) ? "heart.fill" : "heart")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(favorites.contains(comic) ? "取消收藏" : "加入收藏")
        .accessibilityIdentifier("favorite-" + comic.id)
        .accessibilityValue(favorites.contains(comic) ? "已收藏" : "未收藏")
    }
}
