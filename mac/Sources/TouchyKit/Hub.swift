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
    /// Claude's task list per session, as far as its calls were seen.
    private var boards: [String: TaskBoard] = [:]
    /// When each session's running token count was last read, by the
    /// clock of its hook events.
    private var countedAt: [String: Double] = [:]
    /// How long a running token count stays as it is: the transcript is
    /// not read at every tool call.
    static let countEvery: Double = 5
    public let pending: PendingRequests
    private let onChange: @Sendable (Change) -> Void
    private let persist: (@Sendable ([StoredSession]) -> Void)?
    /// When to read the transcript again after a round ends: its last
    /// message can be written after the Stop hook has run.
    private let secondLooks: [Duration]
    private let pause: @Sendable (Duration) async -> Void

    /// `persist` receives the whole registry, credentials included, each
    /// time something worth keeping across a restart changes.
    public init(
        onChange: @escaping @Sendable (Change) -> Void = { _ in },
        persist: (@Sendable ([StoredSession]) -> Void)? = nil,
        secondLooks: [Duration] = [.seconds(1), .seconds(4)],
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.onChange = onChange
        self.persist = persist
        self.secondLooks = secondLooks
        self.pause = pause
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
        follow(sessionId, name, envelope)
        if let session = sessions[sessionId] {
            // Every event carries the inbox credentials: a daemon restarted
            // mid-session never sees that session's SessionStart again.
            let known = inbox[sessionId]
            if let seen = envelope.inbox { inbox[sessionId] = seen }
            // Many events change nothing the phone shows.
            let visible = before.map { !session.looksTheSame(as: $0) } ?? true
            if visible { onChange(.session(session)) }
            let worthKeeping = before.map { !session.isWorthKeepingTheSame(as: $0) } ?? true
            if worthKeeping || inbox[sessionId] != known { save() }
        } else if existed {
            inbox[sessionId] = nil
            boards[sessionId] = nil
            countedAt[sessionId] = nil
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

    /// Keeps the running round's line about what the session is doing,
    /// and its token count, up to date with a tool call.
    private func follow(_ id: String, _ name: String, _ envelope: HookEnvelope) {
        guard var round = sessions[id]?.round, round.endedAt == nil,
              let tool = envelope.event["tool_name"]?.stringValue else { return }
        let input = envelope.event["tool_input"]?.objectValue ?? [:]
        switch name {
        case "PreToolUse":
            // The task in progress says more than the tool in use.
            if let line = boards[id]?.current ?? Activity.line(tool: tool, input: input) { round.activity = line }
        case "PostToolUse":
            let task = boards[id]?.current
            boards[id, default: TaskBoard()].note(tool: tool, input: input, response: envelope.event["tool_response"])
            if let now = boards[id]?.current {
                round.activity = now
            } else if task != nil, round.activity == task {
                round.activity = nil
            }
            if let path = envelope.event["transcript_path"]?.stringValue,
               envelope.capturedAt - (countedAt[id] ?? -.infinity) >= Self.countEvery {
                countedAt[id] = envelope.capturedAt
                round.tokens = RoundStats.outputTokens(transcriptPath: path, since: round.startedAt) ?? round.tokens
            }
        default:
            return
        }
        sessions[id]?.round = round
    }

    /// Drops the sessions whose inbox `isAlive` rejects: those that ended without a
    /// SessionEnd (crash, kill, closed terminal). Their requests close too.
    /// A session without an inbox cannot be probed and is kept.
    public func reap(isAlive: @Sendable (InboxCredentials) -> Bool) async {
        for (id, credentials) in inbox where !isAlive(credentials) {
            sessions[id] = nil
            inbox[id] = nil
            boards[id] = nil
            countedAt[id] = nil
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
            lookAgain(id, path: path, roundStartedAt: start)
        }
        let peek = TranscriptPeek.read(path: path)
        if let title = peek.aiTitle ?? peek.sessionName ?? peek.firstUserPrompt, !title.isEmpty {
            session.title = title
        }
        sessions[id] = session
    }

    private func lookAgain(_ id: String, path: String, roundStartedAt start: Date) {
        let (delays, pause) = (secondLooks, pause)
        Task { [weak self] in
            for delay in delays {
                await pause(delay)
                guard await self?.recount(id, path: path, roundStartedAt: start) == true else { return }
            }
        }
    }

    /// False once the round is no longer the session's latest finished one.
    private func recount(_ id: String, path: String, roundStartedAt start: Date) -> Bool {
        guard var session = sessions[id], session.round?.startedAt == start, session.round?.endedAt != nil else {
            return false
        }
        if let tokens = RoundStats.outputTokens(transcriptPath: path, since: start), tokens != session.round?.tokens {
            session.round?.tokens = tokens
            sessions[id] = session
            onChange(.session(session))
            save()
        }
        return true
    }
}
