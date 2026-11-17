import SwiftUI

@main
struct MusicGlassApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var player = PlayerStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Self.prepareDocuments()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(player)
                .environment(\.playerControl, player)
                .tint(.pink)
                .onAppear { player.attach(library) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await library.rescan() }
                    }
                }
        }
    }

    /// Создаёт видимую в «Файлах» папку «Музыка» внутри папки приложения.
    private static func prepareDocuments() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let music = docs.appendingPathComponent("Музыка", isDirectory: true)
        try? fm.createDirectory(at: music, withIntermediateDirectories: true)
        let note = music.appendingPathComponent("Положите музыку сюда.txt")
        if !fm.fileExists(atPath: note.path) {
            let text = "Положите сюда аудиофайлы или целые папки с музыкой. Приложение найдёт их само."
            try? text.write(to: note, atomically: true, encoding: .utf8)
        }
    }
}
