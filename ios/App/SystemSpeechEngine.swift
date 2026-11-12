@preconcurrency import AVFoundation
import os
import Speech
import TouchyClient

/// Why a dictation failed, for Console. Never what was said.
private let log = Logger(subsystem: "touchytua", category: "speech")

/// Dictation on the device: the microphone feeds the system's speech
/// analyzer, and only text comes out. Audio never leaves the phone.
final class SystemSpeechEngine: SpeechEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var run: Run?

    func listen(locale: Locale, hints: [String]) -> AsyncThrowingStream<SpeechEvent, Error> {
        let (stream, events) = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        let run = Run(events: events)
        lock.withLock { self.run = run }
        Task { await run.go(locale: locale, hints: hints) }
        return stream
    }

    func stop() async {
        await lock.withLock { run }?.close(keepingLastWords: true)
    }

    func cancel() async {
        await lock.withLock { run }?.close(keepingLastWords: false)
    }

    /// The system's own matching of a locale to one it can transcribe.
    static func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        if SpeechTranscriber.isAvailable, let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return match
        }
        return await DictationTranscriber.supportedLocale(equivalentTo: locale)
    }

    /// Every language this phone can transcribe.
    static func supportedLocales() async -> [Locale] {
        var seen = Set<String>()
        let general = SpeechTranscriber.isAvailable ? await SpeechTranscriber.supportedLocales : []
        return (general + (await DictationTranscriber.supportedLocales))
            .filter { seen.insert($0.identifier(.bcp47)).inserted }
    }
}

/// One dictation, from opening the microphone to the last settled word.
private actor Run {
    private let events: AsyncThrowingStream<SpeechEvent, Error>.Continuation
    private var closed = false
    private var microphone: AVAudioEngine?
    private var audio: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var interruptions: Task<Void, Never>?

    init(events: AsyncThrowingStream<SpeechEvent, Error>.Continuation) {
        self.events = events
    }

    func go(locale: Locale, hints: [String]) async {
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw SpeechProblem.microphoneDenied }
            // The general-purpose model where the phone has it, as Apple
            // advises; the system dictation model on older devices and for
            // the other languages. Only the dictation model can be told
            // which words to expect.
            if SpeechTranscriber.isAvailable, let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
                let module = SpeechTranscriber(locale: match, preset: .progressiveTranscription)
                try await transcribe(with: module, locale: match, hints: []) { $0.text }
            } else if let match = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
                let module = DictationTranscriber(
                    locale: match, contentHints: [.shortForm], transcriptionOptions: [.punctuation],
                    reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
                try await transcribe(with: module, locale: match, hints: hints) { $0.text }
            } else {
                throw SpeechProblem.unsupportedLanguage
            }
            release()
            events.finish()
        } catch {
            release()
            // Closing the microphone ends the analyzer, and dropping what it
            // heard makes it throw: that is the dictation ending as asked.
            guard !closed else { return events.finish() }
            log.error("dictation failed: \(String(reflecting: error), privacy: .public)")
            events.finish(throwing: error as? SpeechProblem ?? SpeechProblem.failed)
        }
    }

    /// Closes the microphone. With `keepingLastWords` the analyzer settles
    /// what it already heard before the stream ends; without, it drops it.
    func close(keepingLastWords: Bool) async {
        guard !closed else { return }
        closed = true
        silence()
        guard let analyzer else { return }
        if keepingLastWords {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        } else {
            await analyzer.cancelAndFinishNow()
        }
    }

    private func transcribe<Module: SpeechModule>(
        with module: Module, locale: Locale, hints: [String], text: @Sendable (Module.Result) -> AttributedString
    ) async throws {
        try await install(module, locale: locale)
        guard !closed else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let microphone = AVAudioEngine()
        let heard = microphone.inputNode.outputFormat(forBus: 0)
        guard heard.sampleRate > 0 else {
            log.error("the microphone reports no audio format")
            throw SpeechProblem.failed
        }
        guard let wanted = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: heard)
        else {
            log.error("the analyzer accepts no audio format for \(locale.identifier(.bcp47), privacy: .public)")
            throw SpeechProblem.failed
        }

        let analyzer = SpeechAnalyzer(
            modules: [module], options: .init(priority: .userInitiated, modelRetention: .lingering))
        if !hints.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = hints
            try await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: wanted)
        guard !closed else { return }

        let (inputs, audio) = AsyncStream<AnalyzerInput>.makeStream()
        let tap = Tap(from: heard, to: wanted, audio: audio, events: events)
        microphone.inputNode.installTap(onBus: 0, bufferSize: 2048, format: heard) { buffer, _ in
            tap.take(buffer)
        }
        microphone.prepare()
        try microphone.start()
        self.microphone = microphone
        self.audio = audio
        self.analyzer = analyzer
        watchInterruptions()

        try await analyzer.start(inputSequence: inputs)
        events.yield(.listening)
        for try await result in module.results {
            let words = String(text(result).characters)
            events.yield(result.isFinal ? .final(words) : .partial(words))
        }
    }

    /// Fetches the language model when the phone doesn't have it yet.
    private func install(_ module: some SpeechModule, locale: Locale) async throws {
        guard await AssetInventory.status(forModules: [module]) != .installed else { return }
        try await download(module, locale: locale)
        // Nothing to download and still not installed: this device can't
        // run the model (the Simulator, for one).
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            log.error("no language model for \(locale.identifier(.bcp47), privacy: .public) after install")
            throw SpeechProblem.modelUnavailable
        }
    }

    private func download(_ module: some SpeechModule, locale: Locale) async throws {
        do {
            // The app gets a few language slots: free them for the new one.
            let reserved = await AssetInventory.reservedLocales
            let wanted = locale.identifier(.bcp47)
            if !reserved.contains(where: { $0.identifier(.bcp47) == wanted }),
               reserved.count >= AssetInventory.maximumReservedLocales {
                for old in reserved { await AssetInventory.release(reservedLocale: old) }
            }
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
            events.yield(.downloading(0))
            let events = events
            let watching = request.progress.observe(\.fractionCompleted) { progress, _ in
                events.yield(.downloading(progress.fractionCompleted))
            }
            defer { watching.invalidate() }
            try await request.downloadAndInstall()
        } catch {
            log.error("language model install failed: \(String(reflecting: error), privacy: .public)")
            throw SpeechProblem.modelUnavailable
        }
    }

    /// A phone call or another app taking the microphone ends the dictation
    /// and keeps what was said.
    private func watchInterruptions() {
        interruptions = Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                if raw == AVAudioSession.InterruptionType.began.rawValue {
                    await self?.close(keepingLastWords: true)
                }
            }
        }
    }

    private func silence() {
        microphone?.inputNode.removeTap(onBus: 0)
        microphone?.stop()
        microphone = nil
        audio?.finish()
        audio = nil
    }

    private func release() {
        silence()
        interruptions?.cancel()
        interruptions = nil
        analyzer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Runs on the audio thread: converts each buffer to the format the
/// analyzer asked for and measures how loud it is.
private final class Tap: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let wanted: AVAudioFormat
    private let audio: AsyncStream<AnalyzerInput>.Continuation
    private let events: AsyncThrowingStream<SpeechEvent, Error>.Continuation
    /// Only the audio thread touches it.
    private var meter = VoiceMeter()

    init(
        from heard: AVAudioFormat, to wanted: AVAudioFormat,
        audio: AsyncStream<AnalyzerInput>.Continuation,
        events: AsyncThrowingStream<SpeechEvent, Error>.Continuation
    ) {
        converter = heard == wanted ? nil : AVAudioConverter(from: heard, to: wanted)
        self.wanted = wanted
        self.audio = audio
        self.events = events
    }

    func take(_ buffer: AVAudioPCMBuffer) {
        events.yield(.level(meter.level(decibels: Self.loudness(of: buffer))))
        if let converted = convert(buffer) { audio.yield(AnalyzerInput(buffer: converted)) }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = wanted.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: wanted, frameCapacity: capacity) else { return nil }
        var given = false
        var failure: NSError?
        let status = converter.convert(to: converted, error: &failure) { _, state in
            if given {
                state.pointee = .noDataNow
                return nil
            }
            given = true
            state.pointee = .haveData
            return buffer
        }
        return status == .error || converted.frameLength == 0 ? nil : converted
    }

    /// How loud the buffer is, in decibels below full scale.
    private static func loudness(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -.infinity }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        return 10 * log10(max(sum / Float(buffer.frameLength), 1e-10))
    }
}
