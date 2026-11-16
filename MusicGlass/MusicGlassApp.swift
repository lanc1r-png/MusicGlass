import SwiftUI

@main
struct MusicGlassApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var player = PlayerStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(player)
                .tint(.pink)
                .onAppear { player.attach(library) }
        }
    }
}
