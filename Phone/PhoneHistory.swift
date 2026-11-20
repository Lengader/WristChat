import SwiftUI

struct PhoneHistory: View {
    @ObservedObject var account: PhoneSignIn

    var body: some View {
        NavigationStack {
            List {
                if account.historySubject != nil {
                    Section("Чаты с Apple Watch") {
                        if account.history.threads.isEmpty {
                            Text("Открой WristChat на часах, чтобы синхронизировать переписку.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(account.history.latestThreads) { thread in
                            NavigationLink(value: thread.id) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(thread.title)
                                    Text(thread.updated, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section("Настройки ответов") {
                        Picker("Режим по умолчанию", selection: Binding(
                            get: { account.history.preference(for: nil) ?? .automatic },
                            set: { account.setMode($0, for: nil) }
                        )) {
                            ForEach(ReasoningMode.allCases) { Text($0.title).tag($0) }
                        }
                    }
                }
                Section("Аккаунт ChatGPT") {
                    Button("Continue with ChatGPT") { account.begin() }
                        .disabled(account.busy || !account.watchReady)
                    if account.busy { ProgressView() }
                    if let status = account.status {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    } else if !account.watchReady {
                        Text("Открой WristChat на Apple Watch.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("WristChat")
            .navigationDestination(for: UUID.self) { id in PhoneThread(account: account, id: id) }
        }
    }
}

private struct PhoneThread: View {
    @ObservedObject var account: PhoneSignIn
    let id: UUID

    private var thread: ChatThread? { account.history.threads.first { $0.id == id } }

    var body: some View {
        List {
            Section {
                Picker("Режим чата", selection: Binding<ReasoningMode?>(
                    get: { account.history.preference(for: id) },
                    set: { account.setMode($0, for: id) }
                )) {
                    Text("По умолчанию").tag(nil as ReasoningMode?)
                    ForEach(ReasoningMode.allCases) { Text($0.title).tag(Optional($0)) }
                }
            }
            Section {
                ForEach(thread?.messages ?? []) { message in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(message.role == .user ? "Ты" : (message.modelTitle ?? "ChatGPT"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        MessageBody(message: message).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle(thread?.title ?? "Чат")
        .navigationBarTitleDisplayMode(.inline)
    }
}
