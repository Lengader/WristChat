import AVFoundation
import NaturalLanguage
import PhotosUI
import SwiftUI

@main
struct WristChatWatchApp: App {
    @StateObject private var chat = WatchChat()

    var body: some Scene {
        WindowGroup { WatchHistory(chat: chat) }
    }
}

private struct WatchHistory: View {
    private enum Destination: Hashable { case thread(UUID), settings }

    @ObservedObject var chat: WatchChat
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [Destination] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if chat.connected {
                    Button { path.append(.thread(UUID())) } label: {
                        Label("Новый чат", systemImage: "square.and.pencil")
                    }
                    ForEach(chat.book.latestThreads) { thread in
                        NavigationLink(value: Destination.thread(thread.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(thread.title).lineLimit(2)
                                Text(thread.updated, style: .relative).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    NavigationLink(value: Destination.settings) {
                        Label("Режим по умолчанию", systemImage: "slider.horizontal.3")
                            .font(.footnote)
                    }
                } else {
                    Label("Войди в ChatGPT в WristChat на iPhone.", systemImage: "iphone").font(.footnote)
                    if let error = chat.error { Text(error).font(.footnote) }
                }
            }
            .navigationTitle("WristChat")
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .thread(let id): WatchThread(chat: chat, id: id)
                case .settings: reasoningSettings
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { chat.sync() }
        }
    }

    private var reasoningSettings: some View {
        List {
            Picker("Режим", selection: Binding(
                get: { chat.book.preference(for: nil) ?? .automatic },
                set: { chat.setMode($0, for: nil) }
            )) {
                ForEach(ReasoningMode.allCases) { Text($0.title).tag($0) }
            }
        }
        .navigationTitle("По умолчанию")
    }
}

private struct WatchThread: View {
    @ObservedObject var chat: WatchChat
    let id: UUID

    @State private var draft = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photo: Data?
    @State private var loadingPhoto = false
    @State private var photoError: String?
    @State private var speech = AVSpeechSynthesizer()

    private var thread: ChatThread? { chat.book.threads.first { $0.id == id } }
    private var replying: Bool { chat.replyingTo == id }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(thread?.messages ?? []) { bubble($0) }
                    if replying {
                        if chat.liveText.isEmpty {
                            ProgressView("Жду ответ…").font(.caption)
                        } else {
                            FormattedReply(text: chat.liveText)
                                .font(.subheadline)
                                .padding(8)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 13))
                        }
                    }
                    if let error = photoError ?? chat.error {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.vertical, 4)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .onAppear { scroll.scrollTo("end", anchor: .bottom) }
            .onChange(of: replying) { _, replying in
                if replying { scroll.scrollTo("end", anchor: .bottom) }
            }
        }
        .navigationTitle(thread?.title ?? "Новый чат")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    List {
                        Picker("Режим", selection: Binding<ReasoningMode?>(
                            get: { chat.book.preference(for: id) },
                            set: { chat.setMode($0, for: id) }
                        )) {
                            Text("По умолчанию").tag(nil as ReasoningMode?)
                            ForEach(ReasoningMode.allCases) { Text($0.title).tag(Optional($0)) }
                        }
                    }
                    .navigationTitle("Режим чата")
                } label: {
                    Image(systemName: "slider.horizontal.3").accessibilityLabel("Режим чата")
                }
            }
        }
        .task(id: selectedPhoto) { await loadPhoto() }
    }

    private var composer: some View {
        VStack(spacing: 4) {
            if replying {
                Button(role: .destructive) { chat.stop() } label: {
                    Label("Стоп", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            } else {
                if loadingPhoto { ProgressView("Загружаю фото…").font(.caption2) }
                if photo != nil {
                    Button("Убрать фото", systemImage: "xmark.circle") {
                        photo = nil
                        selectedPhoto = nil
                    }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                }
                HStack(spacing: 4) {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Image(systemName: "photo").accessibilityLabel("Выбрать фото")
                    }
                    .buttonStyle(.borderless)
                    TextField("Сообщение", text: $draft)
                    Button {
                        if chat.startReply(to: id, text: draft, photo: photo) {
                            draft = ""
                            photo = nil
                            selectedPhoto = nil
                            photoError = nil
                        }
                    } label: {
                        Image(systemName: "arrow.up").fontWeight(.semibold)
                    }
                    .accessibilityLabel("Отправить")
                    .buttonStyle(.borderedProminent)
                    .disabled(loadingPhoto || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photo == nil))
                }
                .disabled(chat.replyingTo != nil)
            }
        }
        .padding(.vertical, 2)
        .background(.background)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let own = message.role == .user
        return VStack(alignment: .leading, spacing: 4) {
            MessageBody(message: message)
                .font(.subheadline)
                .padding(8)
                .background(own ? Color.blue.opacity(0.45) : Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 13))
            if !own, !message.content.isEmpty {
                Button { speak(message.content) } label: {
                    Label("Прочитать", systemImage: "speaker.wave.2").font(.caption2)
                }
                .buttonStyle(.borderless)
                if let model = message.modelTitle {
                    Text(model).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: own ? .trailing : .leading)
    }

    private func loadPhoto() async {
        guard let selection = selectedPhoto else { loadingPhoto = false; return }
        loadingPhoto = true
        photo = nil
        photoError = nil
        do {
            guard let original = try await selection.loadTransferable(type: Data.self) else { throw WristError.unreadablePhoto }
            guard !Task.isCancelled, selection == selectedPhoto else { return }
            photo = try WatchPhoto.compressedJPEG(original)
        } catch {
            guard !Task.isCancelled, selection == selectedPhoto else { return }
            photoError = WristError.unreadablePhoto.localizedDescription
        }
        loadingPhoto = false
    }

    private func speak(_ text: String) {
        speech.stopSpeaking(at: .immediate)
        let readable = MathText.readable(text)
        let utterance = AVSpeechUtterance(string: readable)
        if let language = NLLanguageRecognizer.dominantLanguage(for: readable) {
            let locale = language == .russian ? "ru-RU" : language.rawValue
            utterance.voice = AVSpeechSynthesisVoice(language: locale)
        }
        speech.speak(utterance)
    }
}
