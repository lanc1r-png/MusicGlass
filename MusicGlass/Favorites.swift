import SwiftUI
import UIKit

enum Haptics {
    @MainActor
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var ids: Set<String> = []
    private let key = "favoriteTrackIDs"

    private init() {
        if let arr = UserDefaults.standard.array(forKey: key) as? [String] {
            ids = Set(arr)
        }
    }

    func contains(_ track: Track) -> Bool {
        ids.contains(track.id)
    }

    func toggle(_ track: Track) {
        if ids.contains(track.id) {
            ids.remove(track.id)
        } else {
            ids.insert(track.id)
        }
        UserDefaults.standard.set(Array(ids), forKey: key)
        Haptics.tap()
    }
}

/// Кнопка-сердечко из стекла (для экрана «Сейчас играет»).
struct FavoriteButton: View {
    @ObservedObject private var favorites = FavoritesStore.shared
    let track: Track

    var body: some View {
        Button {
            favorites.toggle(track)
        } label: {
            Image(systemName: favorites.contains(track) ? "heart.fill" : "heart")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(favorites.contains(track) ? Color.pink : Color.primary)
                .frame(width: 40, height: 40)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
    }
}

struct FavoritesView: View {
    @EnvironmentObject var library: LibraryStore
    @ObservedObject private var favorites = FavoritesStore.shared

    var body: some View {
        let tracks = library.tracks.filter { favorites.ids.contains($0.id) }
        SongsView(title: "Избранное", tracks: tracks)
    }
}
