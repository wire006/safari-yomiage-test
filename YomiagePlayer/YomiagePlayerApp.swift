import SwiftUI

@main
struct YomiagePlayerApp: App {
    @StateObject private var speech = SpeechManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(speech)
        }
    }
}
