import AVFoundation
import NaturalLanguage
import SwiftUI

@main
struct WristChatWatchApp: App {
    @StateObject private var chat = WatchChat()

    var body: some Scene {
        WindowGroup { ChatScreen(chat: chat) }
    }
}

private struct ChatScreen: View {
    @ObservedObject var chat: WatchChat
    @State private var confirmReset = false
    @State private var speech = AVSpeechSynthesizer()

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("WristChat").font(.headline)
                        Spacer()
                        if chat.connected {
                            Button { confirmReset = true } label: {
                                Image(systemName: "square.and.pencil")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Новый чат")
                            .disabled(chat.messages.isEmpty || chat.sending)
                        }
                    }

                    if chat.connected {
                        ForEach(chat.messages) { message in
                            bubble(message)
                        }
                        if let pending = chat.pending { bubble(pending) }
                        if chat.sending { ProgressView("Жду ответ…").font(.caption) }
                    } else {
                        Label("Войди в ChatGPT в приложении WristChat на iPhone.", systemImage: "iphone")
                            .font(.footnote)
                    }

                    if let error = chat.error {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }

                    if chat.connected {
                        HStack(spacing: 5) {
                            TextField("Сообщение", text: $chat.draft)
                            Button { Task { await chat.send() } } label: {
                                Image(systemName: "arrow.up").fontWeight(.semibold)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel("Отправить")
                            .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .disabled(chat.sending)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.vertical, 4)
            }
            .onChange(of: chat.messages.last?.id) { _, _ in scroll.scrollTo("end", anchor: .bottom) }
            .onChange(of: chat.sending) { _, _ in scroll.scrollTo("end", anchor: .bottom) }
        }
        .confirmationDialog("Начать новый чат?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Новый чат", role: .destructive) {
                speech.stopSpeaking(at: .immediate)
                chat.reset()
            }
        }
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let own = message.role == .user
        return VStack(alignment: .leading, spacing: 5) {
            Text(message.content)
                .font(.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(own ? Color.blue.opacity(0.45) : Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 13))
            if !own {
                Button { speak(message.content) } label: {
                    Label("Прочитать", systemImage: "speaker.wave.2")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: own ? .trailing : .leading)
    }

    private func speak(_ text: String) {
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        if let language = NLLanguageRecognizer.dominantLanguage(for: text) {
            let locale = language == .russian ? "ru-RU" : language.rawValue
            utterance.voice = AVSpeechSynthesisVoice(language: locale)
        }
        speech.speak(utterance)
    }
}
