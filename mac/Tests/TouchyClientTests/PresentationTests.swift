import Foundation
import Testing
@testable import TouchyClient
import TouchyProtocol

@Suite struct FormatTests {
    @Test func durationsReadLikeTheReference() {
        #expect(Format.duration(0) == "0s")
        #expect(Format.duration(42.9) == "42s")
        #expect(Format.duration(95) == "1m35s")
        #expect(Format.duration(190) == "3m10s")
        #expect(Format.duration(3600) == "1h00m")
        #expect(Format.duration(3905) == "1h05m")
        #expect(Format.duration(-5) == "0s")
    }

    @Test func tokensAreRounded() {
        #expect(Format.tokens(0) == "0 token")
        #expect(Format.tokens(850) == "850 token")
        #expect(Format.tokens(1_999) == "2k token")
        #expect(Format.tokens(3_200) == "3k token")
        #expect(Format.tokens(999_600) == "1.0M token")
        #expect(Format.tokens(1_300_000) == "1.3M token")
    }

    @Test func costKeepsCentsOnlyWhenSmall() {
        #expect(Format.cost(0) == "$0.00")
        #expect(Format.cost(1.234) == "$1.23")
        #expect(Format.cost(12.36) == "$12.4")
        #expect(Format.cost(284.61) == "$284.6")
    }

    @Test func percentHasNoDecimals() {
        #expect(Format.percent(55.4) == "55%")
        #expect(Format.percent(9) == "9%")
        #expect(Format.percent(99.6) == "100%")
    }
}

@Suite struct RequestPresentationTests {
    private func request(_ tool: String, _ input: [String: JSONValue], kind: PendingRequest.Kind = .permission) -> PendingRequest {
        PendingRequest(id: "r", sessionId: "s", kind: kind, toolName: tool, toolInput: input, createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test func aShellCommandShowsTheCommand() {
        #expect(request("Bash", ["command": .string("rm -rf build"), "description": .string("Clean")]).detail == "rm -rf build")
    }

    @Test func aFileToolShowsThePath() {
        #expect(request("Write", ["file_path": .string("/p/a.swift"), "content": .string("…")]).detail == "/p/a.swift")
        #expect(request("Edit", ["file_path": .string("/p/b.swift"), "old_string": .string("x")]).detail == "/p/b.swift")
    }

    @Test func webToolsShowWhereTheyGo() {
        #expect(request("WebFetch", ["url": .string("https://example.com"), "prompt": .string("read")]).detail == "https://example.com")
        #expect(request("WebSearch", ["query": .string("swift actors")]).detail == "swift actors")
    }

    @Test func aPlanShowsThePlan() {
        #expect(request("ExitPlanMode", ["plan": .string("1. Do it")]).detail == "1. Do it")
    }

    /// Tools this build has never heard of (MCP ones, future ones) still say something.
    @Test func anUnknownToolListsItsSimpleInputs() {
        let r = request("mcp__db__query", ["sql": .string("select 1"), "limit": .number(10), "dry": .bool(true), "opts": .object([:])])
        #expect(r.detail == "dry: true\nlimit: 10\nsql: select 1")
    }

    @Test func noInputShowsNothing() {
        #expect(request("Mystery", [:]).detail == "")
    }

    @Test func questionsAreReadFromTheToolInput() {
        let r = request("AskUserQuestion", ["questions": .array([.object([
            "question": .string("Which one?"), "header": .string("Pick"), "multiSelect": .bool(true),
            "options": .array([
                .object(["label": .string("Alpha"), "description": .string("The first")]),
                .object(["label": .string("Beta")]),
            ]),
        ])])], kind: .question)
        #expect(r.questions == [Question(text: "Which one?", header: "Pick", multiSelect: true, options: [
            Question.Option(label: "Alpha", description: "The first"), Question.Option(label: "Beta", description: nil),
        ])])
    }

    @Test func aRequestWithoutQuestionsHasNone() {
        #expect(request("Bash", ["command": .string("ls")]).questions.isEmpty)
        #expect(request("AskUserQuestion", ["questions": .string("oops")], kind: .question).questions.isEmpty)
    }

    @Test func answersAreKeyedByQuestionAndKeepTheOptionOrder() {
        let questions = [
            Question(text: "Which one?", header: nil, multiSelect: false, options: [.init(label: "A", description: nil), .init(label: "B", description: nil)]),
            Question(text: "Which ones?", header: nil, multiSelect: true, options: [.init(label: "X", description: nil), .init(label: "Y", description: nil), .init(label: "Z", description: nil)]),
        ]
        let picked: [String: Set<String>] = ["Which one?": ["B"], "Which ones?": ["Z", "X"]]
        #expect(Question.answers(to: questions, picked: picked) == ["Which one?": "B", "Which ones?": "X, Z"])
    }

    @Test func answersAreNotReadyUntilEveryQuestionHasOne() {
        let questions = [
            Question(text: "One?", header: nil, multiSelect: false, options: [.init(label: "A", description: nil)]),
            Question(text: "Two?", header: nil, multiSelect: false, options: [.init(label: "B", description: nil)]),
        ]
        #expect(Question.answers(to: questions, picked: ["One?": ["A"]]) == nil)
        #expect(Question.answers(to: questions, picked: ["One?": ["A"], "Two?": []]) == nil)
        #expect(Question.answers(to: [], picked: [:]) == nil)
    }

    private var one: Question {
        Question(text: "One?", header: nil, multiSelect: false, options: [.init(label: "A", description: nil), .init(label: "B", description: nil)])
    }

    private var many: Question {
        Question(text: "Many?", header: nil, multiSelect: true, options: [.init(label: "X", description: nil), .init(label: "Y", description: nil)])
    }

    @Test func anAnswerInTheirOwnWordsStandsInForAPick() {
        #expect(Question.answers(to: [one], picked: [:], written: ["One?": "  Use SQLite instead\n"]) == ["One?": "Use SQLite instead"])
    }

    @Test func theirOwnWordsReplaceThePickOfASingleChoice() {
        #expect(Question.answers(to: [one], picked: ["One?": ["A"]], written: ["One?": "Neither"]) == ["One?": "Neither"])
    }

    @Test func theirOwnWordsComeAfterThePicksOfAMultipleChoice() {
        #expect(Question.answers(to: [many], picked: ["Many?": ["Y", "X"]], written: ["Many?": "and Z"]) == ["Many?": "X, Y, and Z"])
    }

    @Test func blankWordsAreNoAnswer() {
        #expect(Question.answers(to: [one], picked: [:], written: ["One?": "  \n"]) == nil)
        #expect(Question.answers(to: [one], picked: ["One?": ["B"]], written: ["One?": " "]) == ["One?": "B"])
    }
}

@Suite struct SessionPresentationTests {
    private func session(_ title: String, round: Round? = nil) -> Session {
        Session(id: "s", title: title, cwd: "/Users/me/Code/shop", state: .working, round: round, lastEventAt: Date(timeIntervalSince1970: 0))
    }

    @Test func theRowShowsOneLineOfTheTitle() {
        #expect(session("Fix the cart\n\nand the checkout too").headline == "Fix the cart")
        #expect(session("  \n  Second line first ").headline == "Second line first")
    }

    @Test func aSessionWithoutATitleIsNamedAfterItsFolder() {
        #expect(session("").headline == "shop")
        #expect(session("   ").headline == "shop")
    }

    @Test func aFinishedRoundSaysHowLongAndHowMuch() {
        let start = Date(timeIntervalSince1970: 1_000)
        let round = Round(startedAt: start, endedAt: start.addingTimeInterval(95), tokens: 2_100, summary: "Done")
        #expect(round.caption(now: start.addingTimeInterval(500)) == "Worked for 1m35s · 2k token")
    }

    @Test func aRunningRoundCountsUp() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(Round(startedAt: start).caption(now: start.addingTimeInterval(12)) == "Working for 12s")
        #expect(Round(startedAt: start, tokens: 900).caption(now: start.addingTimeInterval(12)) == "Working for 12s · 900 token")
    }
}

@Suite struct MarkdownTests {
    @Test func splitsAnAnswerIntoItsBlocks() {
        let text = """
        ## Titolo

        Testo **uno**
        continua

        1. Primo
        2. Secondo
        - punto
        * altro

        ```sh
        dig a.com
          +short
        ```
        fine
        """
        #expect(MarkdownBlock.parse(text) == [
            .heading(level: 2, text: "Titolo"),
            .paragraph("Testo **uno**\ncontinua"),
            .item(marker: "1.", text: "Primo"),
            .item(marker: "2.", text: "Secondo"),
            .item(marker: "•", text: "punto"),
            .item(marker: "•", text: "altro"),
            .code("dig a.com\n  +short"),
            .paragraph("fine"),
        ])
    }

    @Test func plainTextIsOneParagraph() {
        #expect(MarkdownBlock.parse("PONG7") == [.paragraph("PONG7")])
    }

    @Test func aCodeBlockLeftOpenRunsToTheEnd() {
        #expect(MarkdownBlock.parse("```\nls -la") == [.code("ls -la")])
    }

    @Test func hashesInsideAWordAreNotAHeading() {
        #expect(MarkdownBlock.parse("#hashtag e 2.5 volte") == [.paragraph("#hashtag e 2.5 volte")])
    }
}

@Suite struct WaitingCaptionTests {
    @Test func aRoundWaitingOnThePersonDoesNotClaimToBeWorking() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(Round(startedAt: start).caption(now: start.addingTimeInterval(76), waiting: true) == "Paused for your answer")
        #expect(Round(startedAt: start).caption(now: start.addingTimeInterval(76), waiting: false) == "Working for 1m16s")
    }

    @Test func aRunningRoundSaysWhatItIsDoing() {
        let start = Date(timeIntervalSince1970: 1000)
        let round = Round(startedAt: start, tokens: 3700, activity: "Writing the draft")
        #expect(round.doing == "Writing the draft…")
        #expect(round.progress(now: start.addingTimeInterval(79)) == "1m19s · ↓ 4k token")
    }

    @Test func aRunningRoundWithNothingToSayIsWorking() {
        let start = Date(timeIntervalSince1970: 1000)
        #expect(Round(startedAt: start).doing == "Working…")
        #expect(Round(startedAt: start).progress(now: start.addingTimeInterval(12)) == "12s")
    }

    @Test func anActivityAlreadyCutIsNotCutTwice() {
        #expect(Round(startedAt: Date(), activity: "Reading a very long name…").doing == "Reading a very long name…")
    }

    /// A dialog only the terminal can answer: the phone has no card for it,
    /// and "your answer" would point at nothing.
    @Test func aPauseThePhoneCannotAnswerSaysWhereToAnswer() {
        let start = Date(timeIntervalSince1970: 1000)
        let caption = Round(startedAt: start).caption(now: start.addingTimeInterval(76), waiting: true, answerable: false)
        #expect(caption == "Waiting for you on your Mac")
    }
}

@Suite struct RoundPromptTests {
    private func session(title: String, prompt: String?) -> Session {
        Session(
            id: "s", title: title, cwd: "/Users/me/Code/shop", state: .done,
            round: Round(startedAt: Date(timeIntervalSince1970: 0), prompt: prompt),
            lastEventAt: Date(timeIntervalSince1970: 0))
    }

    @Test func thePromptOfTheRoundIsShown() {
        #expect(session(title: "tt-voice", prompt: "Run the tests").roundPrompt == "Run the tests")
    }

    @Test func aPromptAlreadyShownAsTheTitleIsNotRepeated() {
        #expect(session(title: "Run the tests", prompt: "Run the tests").roundPrompt == nil)
    }

    @Test func aTitleCutFromThePromptCountsAsTheSame() {
        let prompt = "Fix the cart and then run every test in the suite"
        #expect(session(title: "Fix the cart and then run…", prompt: prompt).roundPrompt == nil)
    }

    @Test func aLongerPromptThanItsTitleLineIsShown() {
        #expect(session(title: "Fix the cart", prompt: "Fix the cart\nand the tests").roundPrompt == "Fix the cart\nand the tests")
    }

    @Test func aRoundWithoutAPromptShowsNone() {
        #expect(session(title: "tt-voice", prompt: nil).roundPrompt == nil)
    }
}
