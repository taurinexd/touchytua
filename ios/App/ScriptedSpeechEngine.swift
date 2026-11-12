#if DEBUG
import Foundation
import TouchyClient

/// A stand-in voice for the Simulator, which has no microphone worth
/// transcribing: says the given words one at a time. Debug builds only,
/// and only when a script asks for it (see TouchytuaApp).
final class ScriptedSpeechEngine: SpeechEngine, @unchecked Sendable {
    private let words: [Substring]
    private let lock = NSLock()
    private var speaking: Task<Void, Never>?
    private var said = ""
    private var events: AsyncThrowingStream<SpeechEvent, Error>.Continuation?

    init(words: String) {
        self.words = words.split(separator: " ")
    }

    func listen(locale: Locale, hints: [String]) -> AsyncThrowingStream<SpeechEvent, Error> {
        let (stream, events) = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        let words = words
        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            events.yield(.listening)
            var said = ""
            for word in words {
                for _ in 0..<4 {
                    events.yield(.level(Float.random(in: 0.35...0.95)))
                    try? await Task.sleep(for: .milliseconds(90))
                    if Task.isCancelled { return }
                }
                said += (said.isEmpty ? "" : " ") + word
                self?.lock.withLock { self?.said = said }
                events.yield(.partial(said))
            }
            while !Task.isCancelled {
                events.yield(.level(Float.random(in: 0...0.12)))
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
        lock.withLock {
            said = ""
            speaking = task
            self.events = events
        }
        return stream
    }

    func stop() async {
        let (task, events, said) = lock.withLock { (speaking, self.events, self.said) }
        task?.cancel()
        await task?.value
        if !said.isEmpty { events?.yield(.final(said)) }
        events?.finish()
    }

    func cancel() async {
        let (task, events) = lock.withLock { (speaking, self.events) }
        task?.cancel()
        await task?.value
        events?.finish()
    }
}
#endif
