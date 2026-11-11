import Foundation

extension PendingRequest {
    /// Longest string of a tool input that is sent to the phone as is.
    public static let phoneStringLimit = 2000

    /// What the phone receives: the same request with every string of the
    /// tool input longer than `limit` cut and marked. The hook is always
    /// answered from the original.
    public func forPhone(limit: Int = PendingRequest.phoneStringLimit) -> PendingRequest {
        var cut = false
        func shorten(_ value: JSONValue) -> JSONValue {
            switch value {
            case let .string(text) where text.count > limit:
                cut = true
                return .string(text.prefix(limit) + "…")
            case let .array(items):
                return .array(items.map(shorten))
            case let .object(fields):
                return .object(fields.mapValues(shorten))
            default:
                return value
            }
        }
        let input = toolInput.mapValues(shorten)
        guard cut else { return self }
        return PendingRequest(id: id, sessionId: sessionId, kind: kind, toolName: toolName,
                              toolInput: input, createdAt: createdAt, truncated: true)
    }

    /// 8 random characters from [a-z0-9].
    public static func makeId() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }
}

/// Holds hook connections open until the phone decides, or until the
/// request is settled elsewhere.
public actor PendingRequests {
    public enum Event: Equatable, Sendable {
        case opened(PendingRequest)
        case resolved(id: String, by: ResolvedBy)
    }

    /// The reply a hook prints when the phone did not decide: nothing to say.
    public static let emptyReply = Data("{}\n".utf8)

    private var requests: [String: PendingRequest] = [:]
    private var waiters: [String: CheckedContinuation<Data, Never>] = [:]
    private let onChange: @Sendable (Event) -> Void

    public init(onChange: @escaping @Sendable (Event) -> Void) {
        self.onChange = onChange
    }

    public var openRequests: [PendingRequest] {
        requests.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Suspends until `resolve` (phone) or `close`/`cancelAll` (elsewhere).
    public func open(_ request: PendingRequest) async -> Data {
        await withCheckedContinuation { continuation in
            requests[request.id] = request
            waiters[request.id] = continuation
            onChange(.opened(request))
        }
    }

    /// The phone's answer. False when the id is no longer open (a late tap).
    @discardableResult
    public func resolve(id: String, reply: Data) -> Bool {
        finish(id: id, reply: reply, by: .phone)
    }

    public func close(ids: [String], by: ResolvedBy) {
        for id in ids { finish(id: id, reply: Self.emptyReply, by: by) }
    }

    public func cancelAll(sessionId: String, by: ResolvedBy) {
        close(ids: requests.values.filter { $0.sessionId == sessionId }.map(\.id), by: by)
    }

    @discardableResult
    private func finish(id: String, reply: Data, by: ResolvedBy) -> Bool {
        guard requests.removeValue(forKey: id) != nil,
              let waiter = waiters.removeValue(forKey: id) else { return false }
        waiter.resume(returning: reply)
        onChange(.resolved(id: id, by: by))
        return true
    }
}

/// Which open requests a hook event proves settled. Claude Code does not
/// terminate a hook whose request was answered elsewhere (phase-0 T2b), so
/// the daemon infers it from what the session does next.
public enum PendingPolicy {
    public static func requestsToClose(after envelope: HookEnvelope, open: [PendingRequest]) -> [String] {
        guard let name = envelope.eventName, let session = envelope.sessionId else { return [] }
        let mine = open.filter { $0.sessionId == session }
        switch name {
        case "PostToolUse", "PostToolUseFailure":
            // Only the call that ran: parallel sibling calls must not close it.
            let tool = envelope.event["tool_name"]?.stringValue
            let input = envelope.event["tool_input"]?.objectValue
            return mine.filter { $0.toolName == tool && $0.toolInput == input }.map(\.id)
        case "PermissionRequest":
            // Permission prompts are sequential: a new one means the old one is gone.
            return mine.map(\.id)
        case "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd":
            return mine.map(\.id)
        default:
            return []
        }
    }
}
