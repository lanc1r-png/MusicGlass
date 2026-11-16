import SwiftUI

struct CandidateRow: View {
    let item: MetaCandidate
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.thumbURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.2)
                        .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                Text(item.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text([item.album, item.year].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.pink)
            }
        }
        .contentShape(Rectangle())
    }
}

struct TagEditorView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let track: Track

    @State private var query = ""
    @State private var source = 0
    @State private var results: [MetaCandidate] = []
    @State private var selected: MetaCandidate?
    @State private var isSearching = false
    @State private var searchDone = false
    @State private var isSaving = false
    @State private var message: String?

    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var year = ""
    @State private var genre = ""
    @State private var useCover = true

    var body: some View {
        NavigationStack {
            List {
                Section("Поиск информации") {
                    TextField("Название для поиска", text: $query)
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    Picker("Источник", selection: $source) {
                        Text("iTunes").tag(0)
                        Text("MusicBrainz").tag(1)
                    }
                    .pickerStyle(.segmented)
                    Button {
                        Task { await search() }
                    } label: {
                        if isSearching {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Ищу…")
                            }
                        } else {
                            Label("Найти", systemImage: "magnifyingglass")
                        }
                    }
                    .disabled(isSearching || query.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !results.isEmpty {
                    Section("Найдено (нажмите, чтобы выбрать)") {
                        ForEach(results) { item in
                            Button {
                                choose(item)
                            } label: {
                                CandidateRow(item: item, isSelected: selected?.id == item.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else if searchDone && !isSearching {
                    Section {
                        Text("Ничего не найдено. Измените запрос или попробуйте другой источник.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Название", text: $title)
                    TextField("Исполнитель", text: $artist)
                    TextField("Альбом", text: $album)
                    TextField("Год", text: $year).keyboardType(.numberPad)
                    TextField("Жанр", text: $genre)
                    if let url = selected?.coverURL {
                        Toggle("Записать обложку", isOn: $useCover)
                        if useCover {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFit()
                                } else if phase.error != nil {
                                    Text("Обложка для этого варианта недоступна")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ProgressView()
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: 220)
                        }
                    }
                } header: {
                    Text("Что запишется в файл")
                } footer: {
                    Text("Пустые поля не меняются. Данные и обложка записываются прямо в MP3-файл.")
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Записываю…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Label("Записать в файл", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }

                if let message {
                    Section { Text(message) }
                }
            }
            .navigationTitle("Данные трека")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .onAppear { prefill() }
        }
    }

    private func prefill() {
        title = track.title
        artist = track.artist == "Неизвестный артист" ? "" : track.artist
        album = track.album == "Неизвестный альбом" ? "" : track.album
        query = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func choose(_ item: MetaCandidate) {
        selected = item
        title = item.title
        if !item.artist.isEmpty { artist = item.artist }
        if !item.album.isEmpty { album = item.album }
        if !item.year.isEmpty { year = item.year }
        if !item.genre.isEmpty { genre = item.genre }
        useCover = true
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        isSearching = true
        searchDone = false
        message = nil
        selected = nil
        do {
            if source == 0 {
                results = try await MetadataSearch.itunes(q)
            } else {
                results = try await MetadataSearch.musicBrainz(q)
            }
        } catch {
            results = []
            message = "Ошибка поиска: \(error.localizedDescription)"
        }
        isSearching = false
        searchDone = true
    }

    private func save() async {
        guard let url = library.url(for: track) else {
            message = "Файл недоступен."
            return
        }
        isSaving = true
        message = nil

        var coverData: Data?
        var warning = ""
        if useCover, let coverURL = selected?.coverURL {
            do {
                coverData = try await MetadataSearch.downloadCover(coverURL)
            } catch {
                warning = " Обложку скачать не удалось, записаны только текстовые данные."
            }
        }

        var fields = ID3Writer.Fields()
        fields.title = title
        fields.artist = artist
        fields.album = album
        fields.year = year
        fields.genre = genre
        fields.cover = coverData
        let toWrite = fields

        do {
            try await Task.detached(priority: .userInitiated) {
                try ID3Writer.write(toWrite, to: url)
            }.value
            ArtworkLoader.shared.clear()
            library.applyMetadata(
                trackID: track.id,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
                album: album.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            isSaving = false
            if warning.isEmpty {
                dismiss()
            } else {
                message = "Готово." + warning
            }
        } catch {
            isSaving = false
            message = "Не удалось записать: \(error.localizedDescription)"
        }
    }
}
