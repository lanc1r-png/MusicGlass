import SwiftUI

// MARK: - Данные для витрины

struct RadioGenre: Identifiable {
    let id: String          // тег в каталоге
    let title: String
    let colors: [Color]
}

struct RadioCountry: Identifiable {
    let id: String          // код страны
    let title: String
    let flag: String
}

enum RadioShowcase {
    static let genres: [RadioGenre] = [
        RadioGenre(id: "pop", title: "Поп", colors: [.pink, .orange]),
        RadioGenre(id: "rock", title: "Рок", colors: [.red, .purple]),
        RadioGenre(id: "rap", title: "Хип-хоп", colors: [.indigo, .blue]),
        RadioGenre(id: "electronic", title: "Электроника", colors: [.cyan, .indigo]),
        RadioGenre(id: "dance", title: "Танцевальная", colors: [.purple, .pink]),
        RadioGenre(id: "jazz", title: "Джаз", colors: [.orange, .brown]),
        RadioGenre(id: "classical", title: "Классика", colors: [.teal, .blue]),
        RadioGenre(id: "chillout", title: "Расслабляющая", colors: [.mint, .teal]),
        RadioGenre(id: "metal", title: "Метал", colors: [.gray, .black]),
        RadioGenre(id: "oldies", title: "Ретро", colors: [.yellow, .orange]),
        RadioGenre(id: "russian", title: "Русская", colors: [.blue, .red])
    ]

    static let countries: [RadioCountry] = [
        RadioCountry(id: "RU", title: "Россия", flag: "🇷🇺"),
        RadioCountry(id: "US", title: "США", flag: "🇺🇸"),
        RadioCountry(id: "GB", title: "Великобритания", flag: "🇬🇧"),
        RadioCountry(id: "DE", title: "Германия", flag: "🇩🇪"),
        RadioCountry(id: "FR", title: "Франция", flag: "🇫🇷"),
        RadioCountry(id: "IT", title: "Италия", flag: "🇮🇹"),
        RadioCountry(id: "JP", title: "Япония", flag: "🇯🇵"),
        RadioCountry(id: "BR", title: "Бразилия", flag: "🇧🇷")
    ]
}

// MARK: - Модель списка станций

@MainActor
final class RadioListModel: ObservableObject {
    @Published var stations: [RadioStation] = []
    @Published var isLoading = false
    @Published var errorText: String?
    private var task: Task<Void, Never>?

    func load(name: String? = nil, tag: String? = nil,
              countryCode: String? = nil, debounce: Bool = false) {
        task?.cancel()
        errorText = nil

        // Сначала показываем сохранённый список (мгновенно), потом обновляем.
        var showedCache = false
        if let cached = RadioAPI.cached(name: name, tag: tag, countryCode: countryCode) {
            stations = cached.stations
            showedCache = true
            if cached.fresh {
                isLoading = false
                return
            }
        }

        isLoading = true
        task = Task {
            if debounce { try? await Task.sleep(nanoseconds: 400_000_000) }
            if Task.isCancelled { return }
            do {
                let list = try await RadioAPI.search(name: name, tag: tag, countryCode: countryCode)
                if Task.isCancelled { return }
                stations = list
            } catch {
                if Task.isCancelled { return }
                // Если уже показан сохранённый список, ошибку не выводим.
                if !showedCache {
                    stations = []
                    errorText = error.localizedDescription
                }
            }
            isLoading = false
        }
    }

    func clear() {
        task?.cancel()
        stations = []
        isLoading = false
        errorText = nil
    }
}

// MARK: - Карточка и сетка станций

struct StationCard: View {
    @EnvironmentObject var player: PlayerStore
    @ObservedObject private var lib = RadioLibrary.shared
    let station: RadioStation

    var body: some View {
        let isCurrent = player.currentTrack?.id == station.playerID
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                StationCover(station: station)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                if isCurrent {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                        .frame(width: 30, height: 30)
                        .glassEffect(.regular, in: .circle)
                        .padding(8)
                }
            }
            Text(station.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isCurrent ? Color.pink : Color.primary)
                .lineLimit(1)
            Text(station.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                lib.toggle(station)
            } label: {
                Label(lib.isFavorite(station.id) ? "Убрать из «Моих станций»" : "В «Мои станции»",
                      systemImage: lib.isFavorite(station.id) ? "heart.slash" : "heart")
            }
            if !station.homepage.isEmpty, let url = URL(string: station.homepage) {
                Link(destination: url) {
                    Label("Сайт станции", systemImage: "safari")
                }
            }
        }
    }
}

struct StationGrid: View {
    @EnvironmentObject var player: PlayerStore
    let stations: [RadioStation]
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 22) {
            ForEach(Array(stations.enumerated()), id: \.element.id) { index, s in
                StationCard(station: s)
                    .onTapGesture {
                        playRadio(stations, at: index, player: player)
                    }
            }
        }
    }
}

// MARK: - Вкладка «Радио»

struct RadioView: View {
    @EnvironmentObject var player: PlayerStore
    @ObservedObject private var lib = RadioLibrary.shared
    @StateObject private var popular = RadioListModel()
    @StateObject private var found = RadioListModel()
    @State private var query = ""

    private var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if trimmed.isEmpty {
                    home
                } else {
                    searchResults
                }
            }
            .navigationTitle("Радио")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: "Станции")
            .onChange(of: query) { _, new in
                let t = new.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty {
                    found.clear()
                } else {
                    found.load(name: t, debounce: true)
                }
            }
            .task {
                if popular.stations.isEmpty { popular.load() }
            }
        }
        .alert("Не удалось воспроизвести",
               isPresented: Binding(
                get: { player.playbackError != nil },
                set: { if !$0 { player.playbackError = nil } }
               )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(player.playbackError ?? "")
        }
    }

    // Главная витрина

    private var home: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !lib.favorites.isEmpty {
                section("Мои станции") { favoritesShelf }
            }
            section("Жанры") { genreRow }
            section("Страны") { countryRow }
            section("Популярные") { popularContent }

            Text("Каталог станций: radio-browser.info. Станции могут быть временно недоступны.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.bold))
            content()
        }
    }

    private var favoritesShelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(Array(lib.favorites.enumerated()), id: \.element.id) { index, s in
                    StationCard(station: s)
                        .frame(width: 150)
                        .onTapGesture {
                            playRadio(lib.favorites, at: index, player: player)
                        }
                }
            }
        }
    }

    private var genreRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(RadioShowcase.genres) { g in
                    NavigationLink {
                        RadioListView(title: g.title, tag: g.id, countryCode: nil)
                    } label: {
                        Text(g.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(14)
                            .frame(width: 150, height: 84, alignment: .bottomLeading)
                            .background(
                                LinearGradient(colors: g.colors,
                                               startPoint: .topLeading,
                                               endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var countryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(RadioShowcase.countries) { c in
                    NavigationLink {
                        RadioListView(title: c.title, tag: nil, countryCode: c.id)
                    } label: {
                        Text("\(c.flag) \(c.title)")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var popularContent: some View {
        if popular.isLoading && popular.stations.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
        } else if let e = popular.errorText, popular.stations.isEmpty {
            errorBlock(e) { popular.load() }
        } else {
            StationGrid(stations: popular.stations)
        }
    }

    // Результаты поиска

    @ViewBuilder
    private var searchResults: some View {
        VStack {
            if found.isLoading && found.stations.isEmpty {
                ProgressView().padding(.top, 40)
            } else if let e = found.errorText, found.stations.isEmpty {
                errorBlock(e) { found.load(name: trimmed) }
            } else if found.stations.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                StationGrid(stations: found.stations)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    private func errorBlock(_ text: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Label(text, systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Повторить", action: retry)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - Станции жанра или страны

struct RadioListView: View {
    let title: String
    let tag: String?
    let countryCode: String?
    @StateObject private var model = RadioListModel()

    var body: some View {
        ScrollView {
            Group {
                if model.isLoading && model.stations.isEmpty {
                    ProgressView().padding(.top, 40)
                } else if let e = model.errorText, model.stations.isEmpty {
                    VStack(spacing: 10) {
                        Label(e, systemImage: "wifi.slash")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Повторить") {
                            model.load(tag: tag, countryCode: countryCode)
                        }
                    }
                    .padding(.top, 40)
                } else if model.stations.isEmpty {
                    ContentUnavailableView("Станции не найдены", systemImage: "dot.radiowaves.left.and.right")
                } else {
                    StationGrid(stations: model.stations)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .task {
            if model.stations.isEmpty {
                model.load(tag: tag, countryCode: countryCode)
            }
        }
    }
}

// MARK: - Элементы экрана «Сейчас играет»

/// Вместо полосы перемотки для прямого эфира.
struct LiveRow: View {
    @EnvironmentObject var player: PlayerStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
            Text("В прямом эфире")
                .font(.footnote.weight(.semibold))
            Spacer()
        }
        .foregroundStyle(Color.primary.opacity(0.7))
        .frame(height: 44, alignment: .center)
    }
}

/// Сердечко «в мои станции» на экране плеера.
struct RadioFavoriteButton: View {
    @ObservedObject private var lib = RadioLibrary.shared
    let track: Track

    var body: some View {
        let station = RadioCatalog.shared.info(for: track)
        let isFav = station.map { lib.isFavorite($0.id) } ?? false
        Button {
            if let station { lib.toggle(station) }
        } label: {
            Image(systemName: isFav ? "heart.fill" : "heart")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isFav ? Color.pink : Color.primary)
                .frame(width: 40, height: 40)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
    }
}
