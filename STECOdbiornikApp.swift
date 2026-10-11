// S-TEC Odbiornik – odbiera zdjęcia i filmy z programu S-TEC (Windows) po kablu USB albo przez Wi-Fi
// i zapisuje je w aplikacji Zdjęcia. Autorzy: Tom Stec & Uncle Claude
import SwiftUI

@main
struct STECOdbiornikApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear { model.becameActive() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                model.becameActive()
            }
        }
    }
}

/// Tekst po polsku albo po angielsku – zależnie od języka telefonu.
func T(_ pl: String, _ en: String) -> String {
    (Locale.preferredLanguages.first ?? "en").hasPrefix("pl") ? pl : en
}
