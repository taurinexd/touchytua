import Foundation

/// A message-oriented connection to the Mac: one call, one frame.
public protocol FrameTransport: Sendable {
    /// Queues a frame. Frames leave in the order they were queued (the Mac
    /// rejects out-of-order counters), so this neither suspends nor throws:
    /// a dead connection shows up as an error from `receive`.
    func send(_ frame: Data)
    /// The next frame from the Mac. Throws when the connection is gone.
    func receive() async throws -> Data
    func close()
}

public enum LinkError: Error, Equatable {
    /// The Mac refused the handshake: unknown phone, or a QR secret that is
    /// wrong, used or expired.
    case rejected
    case closed
}
