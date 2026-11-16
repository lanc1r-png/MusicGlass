import SwiftUI

struct CategoryRow: View {
    let title: String
    let icon: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Color.pink)
                .frame(width: 30)
            Text(title)
                .font(.title3)
            Spacer()
            if let detail {
                Text(detail).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @ObservedObject private var favorites = FavoritesStore.shared
    @State private var recent: [Album] = []

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        NavigationStack {
            Group {
                if library.tracks.isEmpty {
                    if library.isScanning {
                        ProgressView("Сканирую музыку…")
                    } else {
                        ContentUnavailableView(
                            "Пока пусто",
                            systemImage: "folder.badge.plus",
                            description: Text("Положите музыку в папку приложения в «Файлах» или добавьте её на вкладке «Источники».")
                        )
                    }
                } else {
                    content
                }
            }
            .navigationTitle("Медиатека")
            .navigationBarTitleDisplayMode(.large)
        }
        .task(id: library.albums.count) { await loadRecent() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                NavigationLink {
                    FavoritesView()
                } label: {
                    CategoryRow(title: "Избранное", icon: "heart.fill",
                                detail: "\(favorites.ids.count)")
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 44)

                NavigationLink {
                    ArtistsView()
                } label: {
                    CategoryRow(title: "Исполнители", icon: "music.mic",
                                detail: "\(library.artists.count)")
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 44)

                NavigationLink {
                    AlbumsView()
                } label: {
                    CategoryRow(title: "Альбомы", icon: "square.stack",
                                detail: "\(library.albums.count)")
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 44)

                NavigationLink {
                    SongsView(title: "Песни", tracks: library.tracks)
                } label: {
                    CategoryRow(title: "Песни", icon: "music.note",
                                detail: "\(library.tracks.count)")
                }
                .buttonStyle(.plain)

                if !recent.isEmpty {
                    Text("Недавно добавленные")
                        .font(.title2.weight(.bold))
                        .padding(.top, 28)
                        .padding(.bottom, 12)
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(recent) { album in
                            NavigationLink {
                                AlbumDetailView(album: album)
                            } label: {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private func loadRecent() async {
        let items: [(Album, URL)] = library.albums.compactMap { album in
            guard let t = album.tracks.first, let url = library.url(for: t) else { return nil }
            return (album, url)
        }
        let sorted: [Album] = await Task.detached(priority: .utility) {
            items
                .map { (album, url) -> (Album, Date) in
                    let d = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    return (album, d)
                }
                .sorted { $0.1 > $1.1 }
                .prefix(12)
                .map { $0.0 }
        }.value
        recent = sorted
    }
}
