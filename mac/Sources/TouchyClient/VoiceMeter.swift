import Foundation

/// Turns the loudness of the microphone into the height of the waveform.
/// It measures the voice against the room rather than on a fixed scale:
/// the microphone runs without gain control, and the same sentence is
/// twenty decibels quieter with the phone on a desk than held to the mouth.
public struct VoiceMeter: Sendable {
    /// The last few seconds of loudness, in decibels: their quietest slice
    /// is the room. It starts as a quiet room, so that speaking from the
    /// first instant already shows.
    private var recent: [Float]
    private var next = 0
    private var shown: Float = 0

    public init(memory: Int = 100) {
        recent = Array(repeating: -55, count: max(1, memory))
    }

    /// Takes the loudness of one slice of audio in decibels and returns
    /// the level to draw, 0…1. Call it once per slice, in order.
    public mutating func level(decibels: Float) -> Float {
        var voice: Float = 0
        if decibels.isFinite {
            let heard = min(0, max(-80, decibels))
            recent[next] = heard
            next = (next + 1) % recent.count
            // Speech dips to the room between words; steady noise is the room.
            let room = recent.min() ?? heard
            // Six decibels above the room is still the room; sixteen more is a voice.
            voice = min(1, max(0, (heard - room - 6) / 16))
        }
        // Up at once, down gently: syllables would otherwise flicker.
        shown = voice > shown ? voice : shown * 0.75 + voice * 0.25
        if shown < 0.01 { shown = 0 }
        return shown
    }
}
