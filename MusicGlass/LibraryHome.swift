import SwiftUI
import PhotosUI
import UIKit

// MARK: - Строка категории в стиле Apple Music

struct LibraryCategoryLabel: View {
    let item: LibraryCategory
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: item.icon)
                .font(.system(size: 22))
                .foregroundStyle(CategoryPalette.color(item.colorName))
                .frame(width: 30)
            Text(item.title)
                .font(.title3)
                .lineLimit(1)
                // Тонкий разделитель начинается от текста, а не от иконки.
                .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Медиатека

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @ObservedObject private var favorites = FavoritesStore.shared
    @ObservedObject private var layout = LibraryLayout.shared
    @AppStorage("profileName") private var profileName = ""

    @State private var recent: [Album] = []
    @State private var editMode: EditMode = .inactive
    @State private var showNewCategory = false
    @State private var editingCategory: LibraryCategory?
    @State private var deletingCategory: LibraryCategory?
    @State private var showProfile = false
    @State private var showAllAlbums = false
    @State private var openAlbum: Album.ID?

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
    private var editing: Bool { editMode.isEditing }

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
                            description: Text("Положите музыку в «Файлы» → «На iPhone» → «Opal» → «Музыка». Подробнее в профиле (кружок вверху справа).")
                        )
                    }
                } else {
                    content
                }
            }
            .navigationTitle("Медиатека")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar { toolbarContent }
            .navigationDestination(isPresented: $showAllAlbums) { AlbumsView() }
            .navigationDestination(item: $openAlbum) { id in
                if let album = library.albums.first(where: { $0.id == id }) {
                    AlbumDetailView(album: album)
                }
            }
        }
        .sheet(isPresented: $showNewCategory) {
            CategoryEditorView(existing: nil).presentationDetents([.medium, .large])
        }
        .sheet(item: $editingCategory) {
            CategoryEditorView(existing: $0).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showProfile) { ProfileView() }
        .alert("Удалить категорию «\(deletingCategory?.title ?? "")»?",
               isPresented: Binding(get: { deletingCategory != nil },
                                    set: { if !$0 { deletingCategory = nil } })) {
            Button("Удалить", role: .destructive) {
                if let c = deletingCategory { layout.delete(c.id) }
                deletingCategory = nil
            }
            Button("Отмена", role: .cancel) { deletingCategory = nil }
        } message: {
            Text("Сами песни останутся в медиатеке.")
        }
        .task(id: library.albums.count) { await loadRecent() }
    }

    // MARK: Верхние кнопки

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showNewCategory = true
            } label: {
                Image(systemName: "text.badge.plus")
            }
            Button {
                Haptics.tap()
                withAnimation(.snappy) {
                    editMode = editing ? .inactive : .active
                }
            } label: {
                Image(systemName: editing ? "checkmark" : "checklist")
                    .foregroundStyle(editing ? Color.pink : Color.primary)
            }
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showProfile = true
            } label: {
                AvatarView(name: profileName, size: 36)
            }
            .buttonStyle(.plain)
        }
        .sharedBackgroundVisibility(.hidden)
    }

    // MARK: Содержимое

    private var shownItems: [LibraryCategory] {
        editing ? layout.items : layout.items.filter { !$0.hidden }
    }

    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard editing else { return nil }
        return { from, to in layout.move(from: from, to: to) }
    }

    private var content: some View {
        List {
            ForEach(shownItems) { item in
                row(item)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
            .onMove(perform: moveAction)

            if !editing && !recent.isEmpty {
                recentSection
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }

            if editing {
                Text("Отметьте, что показывать в медиатеке, и перетащите строки, чтобы поменять порядок.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .padding(.top, 8)
            }
        }
        .listStyle(.plain)
        // Края мягко растворяются под шапкой и таб-баром.
        .scrollEdgeEffectStyle(.soft, for: .all)
        // Запас снизу, чтобы последние обложки не уходили под мини-плеер и таб-бар.
        .contentMargins(.bottom, 32, for: .scrollContent)
        .environment(\.editMode, $editMode)
        .animation(.snappy, value: editing)
    }

    @ViewBuilder
    private func row(_ item: LibraryCategory) -> some View {
        if editing {
            HStack(spacing: 14) {
                Button {
                    withAnimation(.snappy) { layout.toggleHidden(item.id) }
                } label: {
                    Image(systemName: item.hidden ? "circle" : "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(item.hidden ? Color.secondary : Color.pink)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                LibraryCategoryLabel(item: item)
                    .opacity(item.hidden ? 0.5 : 1)
            }
        } else {
            NavigationLink {
                destination(for: item)
            } label: {
                LibraryCategoryLabel(item: item, detail: count(for: item))
            }
            .contextMenu {
                if item.isCustom {
                    Button {
                        editingCategory = item
                    } label: {
                        Label("Изменить", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        deletingCategory = item
                    } label: {
                        Label("Удалить категорию", systemImage: "trash")
                    }
                } else {
                    Button {
                        withAnimation(.snappy) { layout.toggleHidden(item.id) }
                    } label: {
                        Label("Скрыть из медиатеки", systemImage: "eye.slash")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func destination(for item: LibraryCategory) -> some View {
        switch item.id {
        case "favorites": FavoritesView()
        case "artists": ArtistsView()
        case "albums": AlbumsView()
        case "songs": SongsView(title: "Песни", tracks: library.tracks, indexed: true)
        default: CustomCategoryView(categoryID: item.id)
        }
    }

    private func count(for item: LibraryCategory) -> String {
        switch item.id {
        case "favorites": return "\(favorites.ids.intersection(library.trackIDs).count)"
        case "artists": return "\(library.artists.count)"
        case "albums": return "\(library.albums.count)"
        case "songs": return "\(library.tracks.count)"
        default:
            return "\(item.trackIDs.filter { library.trackIDs.contains($0) }.count)"
        }
    }

    // MARK: Недавно добавленные

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                showAllAlbums = true
            } label: {
                HStack(spacing: 6) {
                    Text("Недавно добавленные")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color.primary)
                    Image(systemName: "chevron.right")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            // Стеклянные кнопки play рисуются одним проходом.
            GlassEffectContainer {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                    ForEach(recent) { album in
                        RecentAlbumCard(album: album) {
                            openAlbum = album.id
                        }
                    }
                }
            }
        }
        .padding(.top, 28)
        .padding(.bottom, 20)
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

// MARK: - Карточка «Недавно добавленные»

struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct RecentAlbumCard: View {
    @Environment(\.playerControl) private var player
    @EnvironmentObject var library: LibraryStore
    @ObservedObject private var status = PlaybackStatus.shared
    let album: Album
    let open: () -> Void

    private var isCurrent: Bool {
        guard let id = status.currentID else { return false }
        return album.tracks.contains { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Button(action: open) {
                    ArtworkView(track: album.tracks.first, corner: 14, maxPixels: 500)
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
                }
                .buttonStyle(CardPressStyle())

                Button {
                    Haptics.tap()
                    if isCurrent {
                        player?.togglePlayPause()
                    } else {
                        if player?.shuffleOn == true { player?.toggleShuffle() }
                        player?.play(album.tracks, startAt: 0)
                    }
                } label: {
                    Image(systemName: isCurrent && status.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular.tint(.black.opacity(0.25)).interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .padding(10)
            }

            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isCurrent ? Color.pink : Color.primary)
                        .lineLimit(1)
                    Text(album.artist)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            AlbumMenuItems(tracks: album.tracks)
        } preview: {
            AlbumPreview(album: album)
                .environmentObject(library)
        }
    }
}

// MARK: - Своя категория

struct CustomCategoryView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.playerControl) private var player
    @ObservedObject private var layout = LibraryLayout.shared
    let categoryID: String
    @State private var showEditor = false

    private var category: LibraryCategory? { layout.category(categoryID) }

    private var tracks: [Track] {
        guard let c = category else { return [] }
        return c.trackIDs.compactMap { library.byID[$0] }
    }

    var body: some View {
        let list = tracks
        Group {
            if list.isEmpty {
                ContentUnavailableView(
                    category?.title ?? "Категория",
                    systemImage: category?.icon ?? "music.note",
                    description: Text("Добавляйте песни через «⋯» → «Добавить в категорию» или долгим нажатием на альбом.")
                )
            } else {
                List {
                    PlayShuffleButtons(tracks: list)
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Haptics.tap()
                                player?.play(list, startAt: index)
                            }
                    }
                    .onDelete { offsets in
                        layout.remove(offsets.map { list[$0].id }, from: categoryID)
                    }
                }
                .listStyle(.plain)
                .scrollEdgeEffectStyle(.soft, for: .all)
                .contentMargins(.bottom, 24, for: .scrollContent)
            }
        }
        .navigationTitle(category?.title ?? "")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showEditor = true
                } label: {
                    Image(systemName: "pencil")
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            if let c = category { CategoryEditorView(existing: c) }
        }
    }
}

// MARK: - Создание и изменение категории

struct CategoryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let existing: LibraryCategory?
    @State private var title: String
    @State private var icon: String
    @State private var colorName: String

    init(existing: LibraryCategory?) {
        self.existing = existing
        _title = State(initialValue: existing?.title ?? "")
        _icon = State(initialValue: existing?.icon ?? "heart.fill")
        _colorName = State(initialValue: existing?.colorName ?? "pink")
    }

    private var color: Color { CategoryPalette.color(colorName) }
    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        Image(systemName: icon)
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 92, height: 92)
                            .background(
                                LinearGradient(colors: [color, color.opacity(0.65)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                            )
                            .shadow(color: color.opacity(0.4), radius: 14, y: 6)
                            .contentTransition(.symbolEffect(.replace))
                        TextField("Например, «Любимые»", text: $title)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .padding(.vertical, 10)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section("Цвет") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                        ForEach(CategoryPalette.colorNames, id: \.self) { name in
                            Circle()
                                .fill(CategoryPalette.color(name))
                                .frame(width: 34, height: 34)
                                .overlay {
                                    if name == colorName {
                                        Circle().strokeBorder(Color.primary.opacity(0.6), lineWidth: 3)
                                            .frame(width: 44, height: 44)
                                    }
                                }
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                                .onTapGesture {
                                    withAnimation(.snappy) { colorName = name }
                                }
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section("Значок") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(CategoryPalette.icons, id: \.self) { name in
                            Image(systemName: name)
                                .font(.system(size: 20))
                                .foregroundStyle(name == icon ? color : Color.primary)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(name == icon ? color.opacity(0.18) : Color(.tertiarySystemFill)))
                                .contentShape(Circle())
                                .onTapGesture {
                                    withAnimation(.snappy) { icon = name }
                                }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle(existing == nil ? "Новая категория" : "Категория")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        if let existing {
                            LibraryLayout.shared.update(existing.id, title: trimmed, icon: icon, colorName: colorName)
                        } else {
                            LibraryLayout.shared.create(title: trimmed, icon: icon, colorName: colorName)
                        }
                        dismiss()
                    }
                    .disabled(trimmed.isEmpty)
                }
            }
        }
    }
}

// MARK: - Аватар и профиль

/// Фото профиля: хранится в папке приложения (квадрат 600×600).
@MainActor
final class AvatarStore: ObservableObject {
    static let shared = AvatarStore()
    @Published private(set) var image: UIImage?

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("avatar.jpg")
    }

    private init() {
        image = UIImage(contentsOfFile: fileURL.path)
    }

    func set(_ data: Data) {
        guard let source = UIImage(data: data) else { return }
        let side: CGFloat = 600
        let scale = max(side / source.size.width, side / source.size.height)
        let w = source.size.width * scale
        let h = source.size.height * scale
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let square = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            source.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
        if let jpg = square.jpegData(compressionQuality: 0.88) {
            try? jpg.write(to: fileURL, options: .atomic)
        }
        image = square
        Haptics.tap()
    }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
        image = nil
    }
}

struct AvatarView: View {
    @ObservedObject private var avatar = AvatarStore.shared
    let name: String
    var size: CGFloat = 36

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " })
        return String(words.prefix(2).compactMap { $0.first }).uppercased()
    }

    var body: some View {
        ZStack {
            if let img = avatar.image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 0.62, green: 0.68, blue: 0.93),
                                                  Color(red: 0.42, green: 0.45, blue: 0.78)],
                                         startPoint: .top, endPoint: .bottom))
                if initials.isEmpty {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
    }
}

struct ProfileView: View {
    @EnvironmentObject var library: LibraryStore
    @ObservedObject private var favorites = FavoritesStore.shared
    @ObservedObject private var layout = LibraryLayout.shared
    @ObservedObject private var avatar = AvatarStore.shared
    @AppStorage("profileName") private var name = ""
    @Environment(\.dismiss) private var dismiss
    @State private var pickerItem: PhotosPickerItem?
    @State private var loadingPhoto = false
    @AppStorage(PlaybackSettings.crossfadeKey) private var crossfade: Double = 0

    private var filesAppURL: URL? {
        let path = library.musicFolderURL.path
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "shareddocuments://" + encoded)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            AvatarView(name: name, size: 110)
                                .overlay {
                                    if loadingPhoto {
                                        Circle().fill(.black.opacity(0.35))
                                        ProgressView().tint(.white)
                                    }
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 34, height: 34)
                                        .background(Circle().fill(Color.pink))
                                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 3))
                                }
                        }
                        .buttonStyle(.plain)

                        Text(name.isEmpty ? "Ваше имя" : name)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(name.isEmpty ? .secondary : .primary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section("Имя") {
                    TextField("Как вас зовут", text: $name)
                        .textInputAutocapitalization(.words)
                }
                Section("Фото") {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(avatar.image == nil ? "Выбрать фото" : "Изменить фото",
                              systemImage: "photo.on.rectangle")
                    }
                    if avatar.image != nil {
                        Button(role: .destructive) {
                            withAnimation { avatar.remove() }
                        } label: {
                            Label("Удалить фото", systemImage: "trash")
                        }
                    }
                }
                Section {
                    if let url = filesAppURL {
                        Link(destination: url) {
                            Label("Открыть папку «Музыка»", systemImage: "folder")
                        }
                    }
                    Button {
                        Task { await library.rescan(userInitiated: true) }
                    } label: {
                        if library.isScanning {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Сканирую…")
                            }
                        } else {
                            Label("Обновить медиатеку", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(library.isScanning)
                } header: {
                    Text("Музыка")
                } footer: {
                    Text("Кладите аудиофайлы или целые папки в «Файлы» → «На iPhone» → «Opal» → «Музыка». Файлы читаются на месте и никуда не копируются, медиатека обновляется сама при каждом открытии приложения.")
                }

                Section {
                    Toggle(isOn: Binding(get: { crossfade > 0 },
                                         set: { crossfade = $0 ? 6 : 0 })) {
                        Label("Плавный переход", systemImage: "wave.3.right")
                    }
                    if crossfade > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Длительность")
                                Spacer()
                                Text("\(Int(crossfade)) с")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $crossfade, in: 1...12, step: 1)
                        }
                    }
                } header: {
                    Text("Воспроизведение")
                } footer: {
                    Text(crossfade > 0
                         ? "Конец трека плавно затихает, а следующий так же плавно нарастает."
                         : "Треки идут друг за другом без паузы: следующий загружается заранее.")
                }

                Section("Медиатека") {
                    LabeledContent("Песни", value: "\(library.tracks.count)")
                    LabeledContent("Альбомы", value: "\(library.albums.count)")
                    LabeledContent("Исполнители", value: "\(library.artists.count)")
                    LabeledContent("В избранном", value: "\(favorites.ids.intersection(library.trackIDs).count)")
                    LabeledContent("Свои категории", value: "\(layout.custom.count)")
                }
            }
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                loadingPhoto = true
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        withAnimation { avatar.set(data) }
                    }
                    loadingPhoto = false
                    pickerItem = nil
                }
            }
        }
    }
}
