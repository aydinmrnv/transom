import Foundation

/// Ordered input work. Motion may replace only adjacent motion for the same
/// window, never jump across a click, key, focus change, or disconnect barrier.
struct InputMailbox {
    enum Work {
        case message(ClientMessage)
        case reset
    }
    private var work: [Work] = []

    mutating func append(_ message: ClientMessage) {
        if case let .input(id, .mouseMove, _) = message,
           case let .message(.input(previousID, .mouseMove, _))? = work.last,
           id == previousID {
            work[work.count - 1] = .message(message)
        } else {
            work.append(.message(message))
        }
    }

    mutating func reset() { work = [.reset] }
    mutating func next() -> Work? { work.isEmpty ? nil : work.removeFirst() }
}
