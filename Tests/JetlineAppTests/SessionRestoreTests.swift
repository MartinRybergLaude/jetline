import XCTest
@testable import JetlineApp

final class SessionRestoreTests: XCTestCase {
    func testPlanGroupsTabsByWorkspaceInOrder() {
        let plans = SessionRestore.plans(
            for: [
                tab("w1", 200, .terminal, .shell),
                tab("w1", 100, .terminal, .codex),
                tab("w2", 100, .chat, .claude)
            ],
            hasClaudeConversation: { _ in false }
        )
        XCTAssertEqual(plans.map(\.workspaceId), ["w1", "w2"])
        XCTAssertEqual(plans[0].terminals.map(\.agent), [.codex, .shell])
        XCTAssertFalse(plans[0].restoresChats)
        XCTAssertTrue(plans[1].restoresChats)
        XCTAssertTrue(plans[1].terminals.isEmpty)
    }

    func testOnlyTheFirstClaudeTabContinuesItsConversation() {
        let plans = SessionRestore.plans(
            for: [tab("w1", 100, .terminal, .claude), tab("w1", 200, .terminal, .claude)],
            hasClaudeConversation: { _ in true }
        )
        XCTAssertEqual(plans[0].terminals.map(\.launchArgs), [["--continue"], []])
    }

    func testClaudeStartsFreshWithoutAConversationToContinue() {
        let plans = SessionRestore.plans(
            for: [tab("w1", 100, .terminal, .claude)],
            hasClaudeConversation: { _ in false }
        )
        XCTAssertEqual(plans[0].terminals.map(\.launchArgs), [[]])
    }

    func testClaudeProjectDirectoryEncodesTheWorkingDirectory() {
        XCTAssertEqual(
            AgentLauncher.claudeProjectDirectoryName(forWorkingDirectory: "/Users/me/.jetline/worktrees/app/fix_bug"),
            "-Users-me--jetline-worktrees-app-fix-bug"
        )
    }

    func testClaudeSessionNeedsAUserMessageToContinue() {
        XCTAssertFalse(AgentLauncher.claudeSessionHasUserMessage(#"{"type":"file-history-snapshot"}"#))
        XCTAssertFalse(AgentLauncher.claudeSessionHasUserMessage(""))
        XCTAssertTrue(AgentLauncher.claudeSessionHasUserMessage(
            #"{"type":"summary"}"# + "\n" + #"{"parentUuid":null,"type":"user","message":{}}"#
        ))
    }

    func testStoreReplacesTheRecordedTabs() throws {
        _ = TestSupport.dataDir
        try SessionRestoreStore.replace(with: [tab("w1", 100, .terminal, .claude)])
        try SessionRestoreStore.replace(with: [tab("w2", 100, .chat, .codex), tab("w2", 200, .terminal, .shell)])
        let stored = try SessionRestoreStore.all()
        XCTAssertEqual(stored, [tab("w2", 100, .chat, .codex), tab("w2", 200, .terminal, .shell)])
    }

    private func tab(
        _ workspaceId: String,
        _ displayOrder: Int,
        _ kind: RestorableTab.Kind,
        _ agent: Workspace.AgentKind
    ) -> RestorableTab {
        RestorableTab(workspaceId: workspaceId, displayOrder: displayOrder, kind: kind, agent: agent)
    }
}
