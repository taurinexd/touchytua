import Foundation
import Observation

/// What a speech engine reports while it listens.
public enum SpeechEvent: Sendable, Equatable {
    /// The language model is being fetched; 0…1.
    case downloading(Double)
    /// The microphone is open.
    case listening
    /// How loud the voice is right now; 0…1.
    case level(Float)
    /// The engine's current guess for the words not settled yet. Each guess
    /// replaces the one before.
    case partial(String)
    /// Words that will not change any more.
    case final(String)
}

public enum SpeechProblem: Error, Equatable, Sendable {
    case microphoneDenied
    case unsupportedLanguage
    case modelUnavailable
    case failed

    public var message: String {
        switch self {
        case .microphoneDenied:
            "touchytua can't hear you. Allow the microphone for touchytua in Settings."
        case .unsupportedLanguage:
            "Dictation isn't available in this language on this iPhone."
        case .modelUnavailable:
            "The dictation language couldn't be downloaded. Check your connection and try again."
        case .failed:
            "Dictation stopped unexpectedly. Try again."
        }
    }
}

/// Turns speech into text on the device. The app's engine wraps the system
/// frameworks; tests script one.
public protocol SpeechEngine: Sendable {
    /// Opens the microphone. The stream ends once everything said before
    /// `stop()` has settled, or throws a `SpeechProblem`.
    func listen(locale: Locale) -> AsyncThrowingStream<SpeechEvent, Error>
    /// Closes the microphone and lets the last words settle.
    func stop() async
    /// Closes the microphone and drops what has not settled.
    func cancel() async
}

/// One dictation into the prompt field: what was typed before, plus what is
/// being said.
@Observable @MainActor
public final class Dictation {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Getting ready; the fraction is the model download, when there is one.
        case preparing(Double?)
        case listening
        /// The microphone is closed and the last words are settling.
        case finishing
    }

    public private(set) var phase: Phase = .idle
    public private(set) var text = ""
    public private(set) var level: Float = 0
    public private(set) var problem: String?

    private let engine: any SpeechEngine
    private var typed = ""
    private var settled = ""
    private var guess = ""
    private var listener: Task<Void, Never>?

    public init(engine: any SpeechEngine) {
        self.engine = engine
    }

    /// Opens the microphone; what is said is added after `typed`.
    public func start(after typed: String, locale: Locale) {
        guard phase == .idle else { return }
        self.typed = typed
        settled = ""
        guess = ""
        text = typed
        problem = nil
        phase = .preparing(nil)
        let events = engine.listen(locale: locale)
        listener = Task { [weak self] in
            do {
                for try await event in events { self?.take(event) }
            } catch {
                self?.problem = ((error as? SpeechProblem) ?? .failed).message
            }
            self?.phase = .idle
            self?.level = 0
        }
    }

    /// Closes the microphone, waits for the last words and returns the text.
    public func finish() async -> String {
        guard let listener, phase != .idle else { return text }
        phase = .finishing
        await engine.stop()
        await listener.value
        return text
    }

    /// Closes the microphone and puts back what was typed.
    public func cancel() async {
        guard let listener, phase != .idle else { return }
        await engine.cancel()
        await listener.value
        text = typed
    }

    private func take(_ event: SpeechEvent) {
        switch event {
        case let .downloading(fraction):
            phase = .preparing(fraction)
        case .listening:
            if phase != .finishing { phase = .listening }
        case let .level(value):
            level = value
        case let .partial(words):
            guess = words
        case let .final(words):
            settled += words
            guess = ""
        }
        text = Self.join(typed, settled + guess)
    }

    /// The typed text and the spoken text, with one space between them
    /// unless the typed text already ends in one.
    static func join(_ typed: String, _ spoken: String) -> String {
        let spoken = String(spoken.drop { $0.isWhitespace })
        guard !spoken.isEmpty, let last = typed.last else { return typed + spoken }
        return last.isWhitespace ? typed + spoken : typed + " " + spoken
    }
}

/// The hold-to-talk gesture: release sends, unless there is nothing to send.
public enum HoldToTalk {
    /// A touch shorter than this is a slip of the finger, not a message.
    public static let shortestHold: TimeInterval = 0.3

    /// The prompt to send on release: what was typed plus what was said, or
    /// nothing when the touch was too short or nothing was said.
    public static func prompt(heldFor seconds: TimeInterval, typed: String, text: String) -> String? {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard seconds >= shortestHold, !prompt.isEmpty, text != typed else { return nil }
        return prompt
    }
}

public enum DictationLanguage {
    public struct Name: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
    }

    /// The language to dictate in: the one chosen in Settings while the
    /// phone still supports it, else the phone's language, else English.
    /// `equivalent` is the system's own matching of a locale to a supported one.
    public static func resolve(
        chosen: String?, device: Locale, equivalent: @Sendable (Locale) async -> Locale?
    ) async -> Locale? {
        if let chosen, let match = await equivalent(Locale(identifier: chosen)),
           match.identifier(.bcp47) == Locale(identifier: chosen).identifier(.bcp47) {
            return match
        }
        if let match = await equivalent(device) { return match }
        return await equivalent(Locale(identifier: "en_US"))
    }

    /// The languages for the Settings list, each named in its own language.
    public static func names(for locales: [Locale]) -> [Name] {
        locales.map { locale in
            let id = locale.identifier(.bcp47)
            let name = locale.localizedString(forIdentifier: locale.identifier) ?? id
            return Name(id: id, name: name.prefix(1).uppercased(with: locale) + name.dropFirst())
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
