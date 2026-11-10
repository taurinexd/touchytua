import Foundation

/// The daemon's brain: folds hook events into session state, holds
/// permission/question requests open, and applies the phone's decisions.
/// Transport-free so it can be tested directly.
public actor Hub {
    public enum Change: Sendable {
        case session(Session)
        case sessionRemoved(id: String)
        case pending(PendingRequests.Event)
        case usage(Usage)
    }

    public private(set) var sessions: [String: Session] = [:]
    /// Inbox credentials by session id. Kept apart from `sessions` so that
    /// nothing sent to the phone can contain them.
    public private(set) var inbox: [String: InboxCredentials] = [:]
    public private(set) var usage: Usage?
    /// Latest cumulative cost per session, summed into `usage.totalCostUSD`.
    private var costBySession: [String: Double] = [:]
    public let pending: PendingRequests
    private let onChange: @Sendable (Change) -> Void
    private let persist: (@Sendable ([StoredSession]) -> Void)?

    /// `persist` receives the whole registry, credentials included, each
    /// time something worth keeping across a restart changes.
    public init(
        onChange: @escaping @Sendable (Change) -> Void = { _ in },
        persist: (@Sendable ([StoredSession]) -> Void)? = nil
    ) {
        self.onChange = onChange
        self.persist = persist
        pending = PendingRequests { onChange(.pending($0)) }
    }

    /// Sessions saved by a previous run. Live ones win: an event received
    /// since startup is newer than anything on disk.
    public func restore(_ saved: [StoredSession]) {
        for entry in saved where sessions[entry.session.id] == nil {
            sessions[entry.session.id] = entry.session
            inbox[entry.session.id] = entry.inbox
        }
    }

    private func save() {
        persist?(sessions.values.map { StoredSession(session: $0, inbox: inbox[$0.id]) })
    }

    /// Handles one hook envelope and returns the line the hook prints.
    public func handle(_ envelope: HookEnvelope) async -> Data {
        guard let name = envelope.eventName, let sessionId = envelope.sessionId else {
            return PendingRequests.emptyReply
        }
        if name == "touchytua_usage" {
            applyUsage(sessionId, envelope.event["statusline"])
            return PendingRequests.emptyReply
        }
        let settled = PendingPolicy.requestsToClose(after: envelope, open: await pending.openRequests)
        await pending.close(ids: settled, by: .terminal)

        let before = sessions[sessionId]
        let existed = before != nil
        SessionReducer.apply(envelope, to: &sessions)
        if name == "Stop" || name == "StopFailure" { enrichRound(sessionId, envelope) }
        if let session = sessions[sessionId] {
            // Every event carries the inbox credentials: a daemon restarted
            // mid-session never sees that session's SessionStart again.
            let known = inbox[sessionId]
            if let seen = envelope.inbox { inbox[sessionId] = seen }
            // Most events (every tool call) change nothing the phone shows.
            let visible = before.map { !session.looksTheSame(as: $0) } ?? true
            if visible { onChange(.session(session)) }
            if visible || inbox[sessionId] != known { save() }
        } else if existed {
            inbox[sessionId] = nil
            onChange(.sessionRemoved(id: sessionId))
            save()
        }

        guard name == "PermissionRequest" else { return PendingRequests.emptyReply }
        let tool = envelope.event["tool_name"]?.stringValue ?? "unknown"
        let request = PendingRequest(
            id: PendingRequest.makeId(), sessionId: sessionId,
            kind: tool == "AskUserQuestion" ? .question : .permission,
            toolName: tool, toolInput: envelope.event["tool_input"]?.objectValue ?? [:],
            createdAt: Date(timeIntervalSince1970: envelope.capturedAt)
        )
        return await pending.open(request)
    }

    /// Drops the sessions whose inbox `isAlive` rejects: those that ended without a
    /// SessionEnd (crash, kill, closed terminal). Their requests close too.
    /// A session without an inbox cannot be probed and is kept.
    public func reap(isAlive: @Sendable (InboxCredentials) -> Bool) async {
        for (id, credentials) in inbox where !isAlive(credentials) {
            sessions[id] = nil
            inbox[id] = nil
            await pending.cancelAll(sessionId: id, by: .terminal)
            onChange(.sessionRemoved(id: id))
            save()
        }
    }

    /// The phone approved or denied. False when the request is no longer open.
    public func decide(requestId: String, allow: Bool, message: String?) async -> Bool {
        guard let request = await pending.openRequests.first(where: { $0.id == requestId }) else { return false }
        let reply = HookReply.permission(
            allow: allow, message: message, toolName: request.toolName, toolInput: request.toolInput)
        return await pending.resolve(id: requestId, reply: reply)
    }

    /// The phone answered an AskUserQuestion.
    public func answer(requestId: String, answers: [String: String]) async -> Bool {
        guard let request = await pending.openRequests.first(where: { $0.id == requestId }),
              request.kind == .question else { return false }
        return await pending.resolve(id: requestId, reply: HookReply.question(toolInput: request.toolInput, answers: answers))
    }

    /// Statusline input forwarded by `touchytua-statusline`: per-session cost
    /// is cumulative, so keep the latest per session and sum; rate limits are
    /// account-wide, so the newest reading wins, window by window.
    private func applyUsage(_ sessionId: String, _ statusline: JSONValue?) {
        guard let statusline, let data = try? JSONEncoder().encode(statusline),
              let reading = StatusLineChain.usage(fromStatusLineInput: data) else { return }
        if let cost = reading.totalCostUSD { costBySession[sessionId] = cost }
        var next = usage ?? Usage()
        next.totalCostUSD = costBySession.isEmpty ? nil : costBySession.values.reduce(0, +)
        if let five = reading.fiveHourPct { next.fiveHourPct = five }
        if let seven = reading.sevenDayPct { next.sevenDayPct = seven }
        usage = next
        onChange(.usage(next))
    }

    private func enrichRound(_ id: String, _ envelope: HookEnvelope) {
        guard var session = sessions[id],
              let path = envelope.event["transcript_path"]?.stringValue else { return }
        if let start = session.round?.startedAt {
            session.round?.tokens = RoundStats.outputTokens(transcriptPath: path, since: start)
        }
        let peek = TranscriptPeek.read(path: path)
        if let title = peek.aiTitle ?? peek.sessionName ?? peek.firstUserPrompt, !title.isEmpty {
            session.title = title
        }
        sessions[id] = session
    }
}
