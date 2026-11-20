import Foundation

@main
struct ChatChecks {
    static func main() throws {
        precondition(MathText.readable(#"\[a+b]^n"#) == "(a+b)ⁿ")
        precondition(MathText.readable(#"\(x_2 + \frac{a}{b} \leq \sqrt{4}\)"#) == "x₂ + (a)⁄(b) ≤ √(4)")
        precondition(MathText.readable("Costs $5 and $10.") == "Costs $5 and $10.")

        let legacy = Data(#"[{"id":"0A12223A-1222-4222-8222-000000000000","role":"user","content":"Здравствуйте"}]"#.utf8)
        let messages = try JSONDecoder().decode([ChatMessage].self, from: legacy)
        precondition(messages.first?.content == "Здравствуйте" && messages.first?.photo == nil)

        let thread = UUID()
        var book = ChatBook()
        book.add(messages, to: thread)
        precondition(book.latestThreads.count == 1 && book.latestThreads.first?.id == thread)

        let initial = ReasoningChange(subject: "test", threadID: nil, mode: .fast)
        let alternate = ReasoningChange(subject: "test", threadID: thread, mode: .deep, date: .distantPast)
        precondition(book.apply(initial) && book.apply(alternate))
        precondition(book.mode(for: thread) == .deep && book.mode(for: UUID()) == .fast)
        let followDefault = ReasoningChange(subject: "test", threadID: thread, mode: nil)
        precondition(book.apply(followDefault))
        precondition(!book.apply(alternate) && book.mode(for: thread) == .fast)

        let encoded = try JSONEncoder().encode(HistorySnapshot(subject: "test", book: book))
        let received = try JSONDecoder().decode(HistorySnapshot.self, from: encoded)
        precondition(received.book.mode(for: thread) == .fast)
        precondition(received.book.changes[followDefault.key]?.stamp == followDefault.stamp)
        print("Chat history, reasoning sync, and math formatting passed")
    }
}
