import SwiftUI
import UIKit

// MARK: - Действия над треком (одни и те же для «⋯» и долгого нажатия)

struct TrackActionButtons: View {
    @ObservedObject private var favorites = FavoritesStore.shared
    @Environment(\.playerControl) private var player
    let track: Track
    @Binding var showEditor: Bool

    var body: some View {
        Button {
            player?.playNext([track])
        } label: {
            Label("Играть следующей", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            player?.addToQueue([track])
        } label: {
            Label("В конец очереди", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        Divider()
        Button {
            favorites.toggle(track)
        } label: {
            Label(favorites.contains(track) ? "Убрать из избранного" : "В избранное",
                  systemImage: favorites.contains(track) ? "heart.slash" : "heart")
        }
        Button {
            showEditor = true
        } label: {
            Label("Найти данные и обложку", systemImage: "square.and.pencil")
        }
        AddToCategoryMenu(tracks: [track])
    }
}

// MARK: - Строка трека

struct TrackRow: View {
    @ObservedObject private var status = PlaybackStatus.shared
    @ObservedObject private var favorites = FavoritesStore.shared
    let track: Track
    @State private var showEditor = false

    var body: some View {
        let isCurrent = status.currentID == track.id
        HStack(spacing: 12) {
            ZStack {
                ArtworkView(track: track, corner: 8, maxPixels: 160)
                if isCurrent {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.4))
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, isActive: status.isPlaying)
                }
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.pink : Color.primary)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)

            if favorites.contains(track) {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.pink)
            }

            Menu {
                TrackActionButtons(track: track, showEditor: $showEditor)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 40)
                    .contentShape(Rectangle())
            }
        }
        .contextMenu {
            TrackActionButtons(track: track, showEditor: $showEditor)
        }
        .sheet(isPresented: $showEditor) {
            TagEditorView(track: track)
        }
    }
}

// MARK: - Песни

struct SongsView: View {
    @Environment(\.playerControl) private var player
    let title: String
    let tracks: [Track]
    /// Показывать алфавитную полоску справа, как в Apple Music.
    var indexed: Bool = false

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableView("Здесь пока пусто", systemImage: "music.note")
            } else if indexed {
                IndexedSongsList(tracks: tracks)
            } else {
                List {
                    PlayShuffleButtons(tracks: tracks)
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Haptics.tap()
                                player?.play(tracks, startAt: index)
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Список песен с алфавитом

enum AlphabetIndexing {
    /// Буква раздела: латиница A–Z, кириллица А–Я, всё остальное «#».
    static func letter(for title: String) -> String {
        guard let ch = title.trimmingCharacters(in: .whitespacesAndNewlines).first else { return "#" }
        var s = String(ch).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).uppercased()
        if s == "Ё" { s = "Е" }
        guard let u = s.unicodeScalars.first, s.unicodeScalars.count == 1 else { return "#" }
        if (65...90).contains(u.value) || (0x410...0x42F).contains(u.value) { return s }
        return "#"
    }
}

struct IndexedSongsList: View {
    @Environment(\.playerControl) private var player
    private let ordered: [Track]
    private let letters: [String]
    private let firstID: [String: String]

    init(tracks: [Track]) {
        let sorted = tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let named = sorted.filter { AlphabetIndexing.letter(for: $0.title) != "#" }
        let other = sorted.filter { AlphabetIndexing.letter(for: $0.title) == "#" }
        let all = named + other
        var letters: [String] = []
        var first: [String: String] = [:]
        for t in all {
            let l = AlphabetIndexing.letter(for: t.title)
            if first[l] == nil {
                first[l] = t.id
                letters.append(l)
            }
        }
        ordered = all
        self.letters = letters
        firstID = first
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                PlayShuffleButtons(tracks: ordered)
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, track in
                    TrackRow(track: track)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Haptics.tap()
                            player?.play(ordered, startAt: index)
                        }
                }
            }
            .listStyle(.plain)
            .contentMargins(.trailing, letters.count > 1 ? 22 : 0, for: .scrollContent)
            .overlay(alignment: .trailing) {
                if letters.count > 1 {
                    AlphabetIndex(letters: letters) { l in
                        if let id = firstID[l] {
                            proxy.scrollTo(id, anchor: .top)
                        }
                    }
                }
            }
        }
    }
}

/// Полоска букв справа. При ведении пальцем рядом появляется стеклянный пузырь с буквой.
struct AlphabetIndex: View {
    let letters: [String]
    let onSelect: (String) -> Void
    @State private var active: String?
    private let selection = UISelectionFeedbackGenerator()

    private var rowHeight: CGFloat { letters.count > 30 ? 11 : 15 }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(letters, id: \.self) { l in
                Text(l)
                    .font(.system(size: rowHeight > 12 ? 11 : 9, weight: .bold, design: .rounded))
                    .foregroundStyle(active == l ? Color.white : Color.pink)
                    .frame(width: 18, height: rowHeight)
                    .background {
                        if active == l {
                            Circle().fill(Color.pink).frame(width: 17, height: 17)
                        }
                    }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 2)
        .glassEffect(.regular.interactive(), in: .capsule)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let i = Int((v.location.y - 8) / rowHeight)
                    let l = letters[min(max(i, 0), letters.count - 1)]
                    if l != active {
                        withAnimation(.snappy(duration: 0.15)) { active = l }
                        selection.selectionChanged()
                        onSelect(l)
                    }
                }
                .onEnded { _ in
                    withAnimation(.easeOut(duration: 0.3).delay(0.25)) { active = nil }
                }
        )
        .overlay(alignment: .leading) {
            if let active {
                Text(active)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.pink)
                    .frame(width: 72, height: 72)
                    .glassEffect(.regular, in: .circle)
                    .offset(x: -96)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .padding(.trailing, 3)
    }
}

// MARK: - Исполнители

struct ArtistsView: View {
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        List(library.artists) { artist in
            NavigationLink {
                LocalArtistView(artist: artist)
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(track: artist.tracks.first, corner: 26, maxPixels: 160)
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artist.name).lineLimit(1)
                        Text("\(artist.tracks.count) песен")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Исполнители")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Поиск

struct SearchView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.playerControl) private var player
    @State private var query = ""

    private var results: [Track] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let found = library.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.artist.localizedCaseInsensitiveContains(q)
                || $0.album.localizedCaseInsensitiveContains(q)
        }
        return Array(found.prefix(300))
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView("Поиск по медиатеке",
                                           systemImage: "magnifyingglass",
                                           description: Text("Песни, альбомы и исполнители"))
                } else {
                    let list = results
                    if list.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        List {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, track in
                                TrackRow(track: track)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        Haptics.tap()
                                        player?.play(list, startAt: index)
                                    }
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle("Поиск")
            .searchable(text: $query, prompt: "Песни, альбомы, исполнители")
        }
    }
}
