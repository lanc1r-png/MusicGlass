import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject var library: LibraryStore
    @State private var showFolderPicker = false
    @State private var showFilePicker = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Добавить файлы", systemImage: "music.note.list")
                    }
                    if library.fileSourceCount > 0 {
                        HStack {
                            Text("Добавлено файлов")
                            Spacer()
                            Text("\(library.fileSourceCount)").foregroundStyle(.secondary)
                        }
                        Button(role: .destructive) {
                            library.removeAllFiles()
                        } label: {
                            Label("Убрать все добавленные файлы", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("Файлы")
                } footer: {
                    Text("В окне «Файлов» откройте папку с музыкой, нажмите «Выбрать», затем «Выбрать все» и «Открыть». Файлы остаются на месте, ничего не копируется.")
                }

                Section {
                    ForEach(library.folderSources) { folder in
                        Label(folder.name, systemImage: "folder")
                    }
                    .onDelete { offsets in
                        let items = offsets.map { library.folderSources[$0] }
                        for item in items { library.removeFolder(item) }
                    }
                    Button {
                        showFolderPicker = true
                    } label: {
                        Label("Добавить папку", systemImage: "folder.badge.plus")
                    }
                } header: {
                    Text("Папки")
                } footer: {
                    Text("Свайп влево убирает папку из списка, сами файлы не трогаются.")
                }

                Section {
                    HStack {
                        Text("Треков в медиатеке")
                        Spacer()
                        Text("\(library.tracks.count)").foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await library.rescan() }
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
                }
            }
            .navigationTitle("Источники")
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: [.audio],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    library.addFiles(urls)
                }
            }
            .sheet(isPresented: $showFolderPicker) {
                FolderPicker(
                    onPick: { urls in
                        library.addFolders(urls)
                        showFolderPicker = false
                    },
                    onCancel: { showFolderPicker = false }
                )
                .ignoresSafeArea()
            }
        }
    }
}
