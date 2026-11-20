import SwiftUI

@main
struct WristChatPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            ContentUnavailableView(
                "Открой WristChat на часах",
                systemImage: "applewatch",
                description: Text("Нажми «Проверить запуск» на Apple Watch.")
            )
        }
    }
}
