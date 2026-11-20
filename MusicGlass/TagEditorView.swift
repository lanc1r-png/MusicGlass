import SwiftUI
import PhotosUI
import UIKit

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
    /// Своя обложка из галереи (после обрезки). Важнее найденной.
    @State private var customCover: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var photoToCrop: CropSource?
    @State private var loadingPhoto = false

    var body: some View {
        NavigationStack {
            List {
                Section("Поиск информации") {
                    TextField("Название для поиска", text: $query)
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    Picker("Источник", selection: $source) {
                        Text("iTunes").tag(0)
                        Text("Deezer").tag(2)
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
                } header: {
                    Text("Что запишется в файл")
                } footer: {
                    Text("Пустые поля не меняются. Данные и обложка записываются прямо в MP3-файл.")
                }

                Section {
                    if let customCover {
                        Image(uiImage: customCover)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .frame(maxWidth: .infinity, maxHeight: 240)
                        Button(role: .destructive) {
                            withAnimation { self.customCover = nil }
                        } label: {
                            Label("Убрать своё фото", systemImage: "xmark.circle")
                        }
                    } else if let url = selected?.coverURL {
                        Toggle("Записать найденную обложку", isOn: $useCover)
                        if useCover {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFit()
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                } else if phase.error != nil {
                                    Text("Обложка для этого варианта недоступна")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ProgressView()
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: 240)
                        }
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        if loadingPhoto {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Открываю фото…")
                            }
                        } else {
                            Label(customCover == nil ? "Выбрать обложку из галереи" : "Выбрать другое фото",
                                  systemImage: "photo.on.rectangle")
                        }
                    }
                } header: {
                    Text("Обложка")
                } footer: {
                    Text("Фото обрезается в квадрат и записывается в файл в размере 1200×1200.")
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
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                loadingPhoto = true
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        // Огромные фото уменьшаем, чтобы обрезка не тормозила.
                        let longest = max(img.size.width, img.size.height)
                        let k = min(1, 2400 / max(longest, 1))
                        let size = CGSize(width: img.size.width * k, height: img.size.height * k)
                        let ready = await img.byPreparingThumbnail(ofSize: size) ?? img
                        photoToCrop = CropSource(image: ready)
                    }
                    loadingPhoto = false
                    photoItem = nil
                }
            }
            .fullScreenCover(item: $photoToCrop) { src in
                CoverCropView(image: src.image) { cropped in
                    withAnimation { customCover = cropped }
                }
            }
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
        if let id = item.deezerAlbumID {
            Task {
                if let info = await MetadataSearch.deezerAlbumInfo(id), selected?.id == item.id {
                    if !info.year.isEmpty { year = info.year }
                    if !info.genre.isEmpty { genre = info.genre }
                }
            }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        isSearching = true
        searchDone = false
        message = nil
        selected = nil
        do {
            switch source {
            case 0: results = try await MetadataSearch.itunes(q)
            case 2: results = try await MetadataSearch.deezer(q)
            default: results = try await MetadataSearch.musicBrainz(q)
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
        if let customCover {
            coverData = customCover.jpegData(compressionQuality: 0.9)
        } else if useCover, let coverURL = selected?.coverURL {
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

// MARK: - Обрезка обложки

struct CropSource: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Квадратная рамка: фото двигается пальцем и увеличивается щипком.
struct CoverCropView: View {
    let image: UIImage
    let onDone: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height) - 32
                let base = baseSize(side)
                let shown = CGSize(width: base.width * scale, height: base.height * scale)
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: shown.width, height: shown.height)
                        .offset(offset)
                    // Затемнение вокруг квадрата
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .reverseMask {
                            RoundedRectangle(cornerRadius: 4).frame(width: side, height: side)
                        }
                        .allowsHitTesting(false)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.white, lineWidth: 1.5)
                        .frame(width: side, height: side)
                        .allowsHitTesting(false)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    SimultaneousGesture(
                        MagnifyGesture()
                            .onChanged { v in
                                scale = max(1, min(lastScale * v.magnification, 6))
                                offset = clamp(offset, side: side, base: base)
                            }
                            .onEnded { _ in
                                lastScale = scale
                                offset = clamp(offset, side: side, base: base)
                                lastOffset = offset
                            },
                        DragGesture()
                            .onChanged { v in
                                let o = CGSize(width: lastOffset.width + v.translation.width,
                                               height: lastOffset.height + v.translation.height)
                                offset = clamp(o, side: side, base: base)
                            }
                            .onEnded { _ in lastOffset = offset }
                    )
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Отмена") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") {
                            onDone(render(side: side, base: base))
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Обложка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    /// Размер фото, при котором оно целиком закрывает квадрат.
    private func baseSize(_ side: CGFloat) -> CGSize {
        let w = max(image.size.width, 1)
        let h = max(image.size.height, 1)
        return w >= h ? CGSize(width: side * w / h, height: side)
                      : CGSize(width: side, height: side * h / w)
    }

    private func clamp(_ o: CGSize, side: CGFloat, base: CGSize) -> CGSize {
        let maxX = max(0, (base.width * scale - side) / 2)
        let maxY = max(0, (base.height * scale - side) / 2)
        return CGSize(width: min(max(o.width, -maxX), maxX),
                      height: min(max(o.height, -maxY), maxY))
    }

    private func render(side: CGFloat, base: CGSize) -> UIImage {
        let out: CGFloat = 1200
        let k = out / side
        let dw = base.width * scale
        let dh = base.height * scale
        let x0 = dw / 2 - side / 2 - offset.width
        let y0 = dh / 2 - side / 2 - offset.height
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: out, height: out), format: format).image { _ in
            image.draw(in: CGRect(x: -x0 * k, y: -y0 * k, width: dw * k, height: dh * k))
        }
    }
}

private extension View {
    /// Вырезает форму из вида (для затемнения вокруг рамки).
    func reverseMask<M: View>(@ViewBuilder _ mask: () -> M) -> some View {
        self.mask {
            Rectangle()
                .overlay {
                    mask().blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}
