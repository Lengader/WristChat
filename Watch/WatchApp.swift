import SwiftUI

@main
struct WristChatWatchApp: App {
    var body: some Scene {
        WindowGroup {
            LaunchCheckView()
        }
    }
}

private struct LaunchCheckView: View {
    @State private var didCheckLaunch = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("WristChat")
                    .font(.headline)

                Button("Проверить запуск") {
                    didCheckLaunch = true
                }
                .buttonStyle(.borderedProminent)

                if didCheckLaunch {
                    Label("Работает на часах", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}
