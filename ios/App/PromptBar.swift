import SwiftUI
import TouchyClient

/// Where the dictation choices made in Settings are kept.
enum DictationSettings {
    /// Hold the microphone and release to send, instead of tap, review, send.
    static let holdToSend = "dictation.holdToSend"
    /// A language identifier such as "it-IT"; empty follows the iPhone.
    static let language = "dictation.language"

    /// The iPhone's language. Not `Locale.current`: that one follows the
    /// languages the app is translated into, and the app is English only.
    static var deviceLocale: Locale {
        Locale(identifier: Locale.preferredLanguages.first ?? "en-US")
    }
}

/// The prompt at the bottom of a session: typed, dictated, or both.
struct PromptBar: View {
    @Environment(ConnectionManager.self) private var connection
    @Environment(Dictation.self) private var dictation
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(DictationSettings.holdToSend) private var holdToSend = false
    @AppStorage(DictationSettings.language) private var language = ""
    let sessionId: String
    @State private var text = ""
    @FocusState private var typing: Bool
    /// When the finger went down on the microphone, in hold-to-talk.
    @State private var heldSince: Date?
    /// What was in the field when the hold began.
    @State private var typedBeforeHold = ""
    /// The finger slid off the microphone: releasing now discards.
    @State private var slidAway = false
    /// True while the finger is on the microphone. The system resets it
    /// even when it takes the touch away without telling the gesture.
    @GestureState private var touching = false
    /// The language to dictate in, worked out before the first touch:
    /// asking the system takes a moment.
    @State private var locale: Locale?
    /// The microphone was touched and is about to open.
    @State private var starting = false

    private var connected: Bool {
        if case .connected = connection.status { return true }
        return false
    }

    private var dictating: Bool { starting || dictation.phase != .idle }

    /// What the microphone shows: busy from the touch, before the engine says so.
    private var phase: Dictation.Phase {
        starting && dictation.phase == .idle ? .preparing(nil) : dictation.phase
    }

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var micEnabled: Bool { !holdToSend || connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = connection.notice ?? dictation.problem {
                Text(notice)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.red)
            } else if let hint {
                Text(hint)
                    .font(Theme.body(13))
                    .foregroundStyle(slidAway ? Theme.red : Theme.textTertiary)
                    .monospacedDigit()
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(phase == .listening ? "Listening…" : "Message Claude", text: $text, axis: .vertical)
                    .font(Theme.body(16))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1...5)
                    .focused($typing)
                    .disabled(dictating)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .card(glow: phase == .listening ? Theme.green : nil, radius: 20)
                microphone
                if hasText, !dictating {
                    Button {
                        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        text = ""
                        typing = false
                        Task { await connection.prompt(sessionId: sessionId, text: prompt) }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Color.black)
                            .frame(width: 42, height: 42)
                            .background(Theme.green, in: Circle())
                    }
                    .disabled(!connected)
                    .opacity(connected ? 1 : 0.35)
                    .accessibilityLabel("Send message")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: dictating)
            .animation(.snappy(duration: 0.2), value: hasText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.background)
        .task(id: language) { locale = await resolveLocale() }
        .onChange(of: dictation.text) { _, spoken in
            if dictating { text = spoken }
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the app closes the microphone; what was said stays in
            // the field and is not sent.
            if phase != .active, dictating { Task { await stopKeepingText() } }
        }
        .onDisappear {
            let dictation = dictation
            Task { await dictation.cancel() }
        }
    }

    /// One line above the field about what the microphone is doing.
    private var hint: String? {
        switch phase {
        case .idle: nil
        case .preparing(nil): "Getting dictation ready…"
        case let .preparing(fraction?): "Downloading the dictation language… \(Int(fraction * 100))%"
        case .listening where holdToSend: slidAway ? "Release to cancel" : "Release to send · slide away to cancel"
        case .listening: "Tap again when you're done"
        case .finishing: "Finishing…"
        }
    }

    @ViewBuilder private var microphone: some View {
        let label = MicrophoneLabel(phase: phase, level: dictation.level, cancelling: slidAway)
            .opacity(micEnabled ? 1 : 0.35)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(dictating ? "Stop dictation" : "Dictate")
        if holdToSend {
            label
                .gesture(hold, isEnabled: micEnabled)
                // A touch the system took away (a scroll, a system gesture)
                // never reaches the gesture's end: treat it as a cancel.
                .onChange(of: touching) { _, touching in
                    if !touching { released(discard: true) }
                }
                // VoiceOver can't hold: there the microphone works by taps.
                .accessibilityAction { Task { await toggle() } }
        } else {
            label
                .contentShape(Rectangle())
                .onTapGesture { Task { await toggle() } }
        }
    }

    /// Tap to start, tap to stop: the text stays in the field to be read
    /// and sent with the arrow.
    private func toggle() async {
        if dictating {
            await stopKeepingText()
        } else {
            await start()
        }
    }

    private func start(held: Bool = false) async {
        guard !dictating else { return }
        typing = false
        starting = true
        defer { starting = false }
        let locale = if let locale { locale } else { await resolveLocale() }
        // The finger may already be gone: don't open a microphone nobody closes.
        if held, heldSince == nil { return }
        // With no supported language the engine itself reports the problem.
        dictation.start(after: text, locale: locale ?? DictationSettings.deviceLocale)
    }

    private func resolveLocale() async -> Locale? {
        await DictationLanguage.resolve(
            chosen: language.isEmpty ? nil : language, device: DictationSettings.deviceLocale,
            equivalent: SystemSpeechEngine.supportedLocale)
    }

    private func stopKeepingText() async {
        heldSince = nil
        slidAway = false
        // Not open yet: there is nothing to keep.
        guard dictation.phase != .idle else { return }
        text = await dictation.finish()
    }

    /// Hold to talk, release to send, slide away to cancel.
    private var hold: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, touching, _ in touching = true }
            .onChanged { finger in
                if heldSince == nil {
                    heldSince = .now
                    typedBeforeHold = text
                    slidAway = false
                    Task { await start(held: true) }
                }
                slidAway = hypot(finger.translation.width, finger.translation.height) > 70
            }
            .onEnded { _ in released(discard: slidAway) }
    }

    /// The finger left the microphone. Only the first call for a hold counts.
    private func released(discard: Bool) {
        // Nil when leaving the app already closed the microphone.
        guard let since = heldSince else { return }
        let held = Date.now.timeIntervalSince(since)
        heldSince = nil
        slidAway = false
        Task {
            // Released before the microphone opened: nothing was said.
            guard dictation.phase != .idle else { return }
            if discard {
                await dictation.cancel()
                text = typedBeforeHold
                return
            }
            let spoken = await dictation.finish()
            if let prompt = HoldToTalk.prompt(heldFor: held, typed: typedBeforeHold, text: spoken) {
                text = ""
                await connection.prompt(sessionId: sessionId, text: prompt)
            } else {
                text = typedBeforeHold
            }
        }
    }
}

/// The microphone button; while listening it becomes the green pill with
/// the moving waveform.
struct MicrophoneLabel: View {
    let phase: Dictation.Phase
    let level: Float
    var cancelling = false

    private var color: Color { cancelling ? Theme.red : Theme.green }

    private var listening: Bool { phase == .listening }
    private var busy: Bool { phase != .idle && phase != .listening }

    // All three faces stay in the view and only fade: replacing the view
    // under a finger cancels the hold gesture.
    var body: some View {
        ZStack {
            Image(systemName: "mic.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.green)
                .opacity(phase == .idle ? 1 : 0)
            ProgressView()
                .tint(Theme.green)
                .opacity(busy ? 1 : 0)
            Waveform(level: listening ? level : 0, color: color)
                .opacity(listening ? 1 : 0)
        }
        .frame(width: listening ? 76 : 42, height: 42)
        .background(Theme.surfaceRaised, in: Capsule())
        .overlay { Capsule().strokeBorder(color.opacity(listening ? 1 : 0.55), lineWidth: 1.5) }
        .shadow(color: color.opacity(listening ? 0.5 : 0), radius: 8)
        .contentShape(Capsule())
    }
}

/// Slanted bars that rise with the voice, as on the reference device.
struct Waveform: View {
    let level: Float
    var color = Theme.green
    private let bars = 9

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<bars, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: height(of: index, at: time))
                }
            }
            // The reference bars lean to the right.
            .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.28, d: 1, tx: 5, ty: 0))
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }

    /// Short dots in silence; with a voice, each bar swings on its own beat
    /// and the middle ones reach higher.
    private func height(of index: Int, at time: TimeInterval) -> CGFloat {
        let middle = 1 - abs(Double(index) - Double(bars - 1) / 2) / Double(bars)
        let swing = 0.55 + 0.45 * sin(time * 9 + Double(index) * 1.3)
        return 3 + 19 * CGFloat(Double(level) * middle * swing)
    }
}
