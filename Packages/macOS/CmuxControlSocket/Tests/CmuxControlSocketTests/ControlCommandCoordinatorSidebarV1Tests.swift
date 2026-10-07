import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator sidebar v1 dispatch")
struct ControlCommandCoordinatorSidebarV1Tests {
    @Test(arguments: ["list_status", "list_meta"])
    func structuredStatusListingPreservesExactValues(command: String) throws {
        let context = FakeSidebarV1ControlCommandContext()
        let value = "human line\ncmux-safe-ops.last-turn.v1=foo=bar \"quoted\"\\tail\r\t"
        context.statusEntries = [ControlSidebarStatusEntrySnapshot(
            key: "human", value: value, icon: "bolt", color: "#123456",
            urlAbsoluteString: "https://example.com/path?a=b", priority: 5, format: .markdown, workState: .waiting
        ), ControlSidebarStatusEntrySnapshot(
            key: "default", value: "normal", icon: nil, color: nil,
            urlAbsoluteString: nil, priority: 0, format: .plain
        )]
        let coordinator = ControlCommandCoordinator(context: context)
        let response = try #require(coordinator.handleSidebarV1(command: command, args: "--json=true"))
        #expect(!response.contains("\n"))
        let decoded = JSONValue(foundationObject: try JSONSerialization.jsonObject(with: Data(response.utf8)))
        #expect(decoded == .object([
            "entries": .object(["human": .string(value), "default": .string("normal")]),
            "metadata": .object(["human": .object([
                "icon": .string("bolt"), "color": .string("#123456"), "url": .string("https://example.com/path?a=b"),
                "priority": .int(5), "format": .string("markdown"), "work": .string("waiting")
            ])])
        ]))
        #expect(coordinator.handleSidebarV1(command: command, args: "")
            == "human=\(value) icon=bolt color=#123456 url=https://example.com/path?a=b priority=5 format=markdown work=waiting\ndefault=normal")
        #expect(coordinator.handleSidebarV1(command: command, args: "--json=false")
            == coordinator.handleSidebarV1(command: command, args: ""))
    }

    @Test(arguments: ["list_status", "list_meta"])
    func structuredStatusListingPreservesEmptyAndMissingTargets(command: String) throws {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        #expect(coordinator.handleSidebarV1(command: command, args: "--json=true") == "ERROR: Tab not found")
        context.statusEntries = []
        let response = try #require(coordinator.handleSidebarV1(command: command, args: "--json=true"))
        let decoded = JSONValue(foundationObject: try JSONSerialization.jsonObject(with: Data(response.utf8)))
        #expect(decoded == .object(["entries": .object([:]), "metadata": .object([:])]))
        #expect(coordinator.handleSidebarV1(command: command, args: "")
            == (command == "list_status" ? "No status entries" : "No metadata entries"))
    }

    @Test func statusPersistenceIsExplicitAndValidatedBeforeMutation() {
        for (option, expected) in [("", false), (" --persist true", true), (" --persist=false", false)] {
            let context = FakeSidebarV1ControlCommandContext()
            let coordinator = ControlCommandCoordinator(context: context)
            let response = coordinator.handleSidebarV1(
                command: "set_status",
                args: "history Last conversation --tab=\(UUID().uuidString)\(option)"
            )
            #expect(response == "OK")
            #expect(context.statusUpsertCall?.persist == expected)
            #expect(context.statusUpsertCall?.value == "Last conversation")
        }
        for option in [" --persist", " --persist=maybe"] {
            let context = FakeSidebarV1ControlCommandContext()
            let coordinator = ControlCommandCoordinator(context: context)
            let response = coordinator.handleSidebarV1(
                command: "set_status",
                args: "history Last conversation --tab=\(UUID().uuidString)\(option)"
            )
            #expect(response?.hasPrefix("ERROR: Invalid persist value") == true)
            #expect(context.statusUpsertCall == nil)
        }
    }

    @Test func agentPIDClearForwardsOwnedKeyRequirement() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let panelID = UUID()

        let response = coordinator.handleSidebarV1(
            command: "clear_agent_pid",
            args: "omp.stale --tab=\(workspaceID.uuidString) --panel=\(panelID.uuidString) "
                + "--clear-status --require-owned-key"
        )

        #expect(response == "OK")
        #expect(context.agentPIDClearCall?.target == .workspace(workspaceID))
        #expect(context.agentPIDClearCall?.key == "omp.stale")
        #expect(context.agentPIDClearCall?.panelID == panelID)
        #expect(context.agentPIDClearCall?.clearStatus == true)
        #expect(context.agentPIDClearCall?.requireOwnedKey == true)
    }

    @Test func statusClearForwardsPanelScope() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let panelID = UUID()

        let response = coordinator.handleSidebarV1(
            command: "clear_status",
            args: "omp --tab=\(workspaceID.uuidString) --panel=\(panelID.uuidString)"
        )

        #expect(response == "OK")
        #expect(context.statusClearCall?.target == .workspace(workspaceID))
        #expect(context.statusClearCall?.key == "omp")
        #expect(context.statusClearCall?.panelID == panelID)
    }

    @Test func statusUpsertForwardsAgentWorkState() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()

        let response = coordinator.handleSidebarV1(
            command: "set_status",
            args: "claude_code Running subagents --icon=bolt.fill --work=SUBAGENTS --tab=\(workspaceID.uuidString)"
        )

        #expect(response == "OK")
        #expect(context.statusUpsertCall?.key == "claude_code")
        #expect(context.statusUpsertCall?.value == "Running subagents")
        #expect(context.statusUpsertCall?.workState == .subagents)
    }

    /// Every existing reporter omits `--work`, and those rows must keep
    /// resolving the way they did before the option existed.
    @Test func statusUpsertWithoutWorkOptionForwardsNoWorkState() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let response = coordinator.handleSidebarV1(
            command: "set_status",
            args: "claude_code Running --icon=bolt.fill --tab=\(UUID().uuidString)"
        )

        #expect(response == "OK")
        #expect(context.statusUpsertCall?.workState == nil)
    }

    @Test func statusUpsertRejectsUnknownWorkStateBeforeMutation() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let response = coordinator.handleSidebarV1(
            command: "set_status",
            args: "claude_code Thinking --work=thinking --tab=\(UUID().uuidString)"
        )

        #expect(response?.hasPrefix("ERROR: Invalid work state 'thinking'") == true,
                "An unknown work state must be named in the error; saw \(response ?? "nil")")
        #expect(context.statusUpsertCall == nil)
    }

    /// The work state drives a glyph with no text of its own, so the
    /// `list_status` / `sidebar_state` line has to carry it: it is the only
    /// way a test or a user can see which state a row is actually in.
    @Test func statusListingLineCarriesTheWorkState() {
        let coordinator = ControlCommandCoordinator(context: FakeSidebarV1ControlCommandContext())
        let waiting = ControlSidebarStatusEntrySnapshot(
            key: "claude_code",
            value: "Waiting",
            icon: "hourglass",
            color: "#8E8E93",
            urlAbsoluteString: nil,
            priority: 0,
            format: .plain,
            workState: .waiting
        )
        #expect(coordinator.sidebarMetadataLine(waiting)
            == "claude_code=Waiting icon=hourglass color=#8E8E93 work=waiting")

        let plain = ControlSidebarStatusEntrySnapshot(
            key: "deploy",
            value: "staging green",
            icon: nil,
            color: nil,
            urlAbsoluteString: nil,
            priority: 0,
            format: .plain
        )
        #expect(coordinator.sidebarMetadataLine(plain) == "deploy=staging green")
    }

    @Test func workspaceLoadingFailureReasonReturnsErrorLine() {
        let context = FakeSidebarV1ControlCommandContext()
        context.workspaceLoadingResult = ControlSidebarWorkspaceLoadingState(
            before: false,
            after: false,
            failureReason: "Manual workspace loading limit reached"
        )
        let coordinator = ControlCommandCoordinator(context: context)

        let response = coordinator.handleSidebarV1(
            command: "workspace_loading",
            args: "manual on --tab=workspace-1"
        )

        #expect(response == "ERROR: Manual workspace loading limit reached")
        #expect(context.workspaceLoadingCall?.tabArg == "workspace-1")
        #expect(context.workspaceLoadingCall?.key == "manual")
        #expect(context.workspaceLoadingCall?.on == true)
    }

    @Test func workspaceLoadingRejectsExplicitEmptyTabBeforeMutation() {
        let context = FakeSidebarV1ControlCommandContext()
        context.workspaceLoadingResult = ControlSidebarWorkspaceLoadingState(before: false, after: true)
        let coordinator = ControlCommandCoordinator(context: context)

        let blankForms = [
            "manual on --tab",
            "manual on --tab=",
        ]

        for args in blankForms {
            let response = coordinator.handleSidebarV1(
                command: "workspace_loading",
                args: args
            )

            #expect(response == "ERROR: Invalid --tab; expected a workspace id, ref, or index")
            #expect(context.workspaceLoadingCall == nil)
        }
    }

    @Test func shellStateForwardsTerminalLifecycleScope() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let panelID = UUID()
        let terminalLifecycleID = UUID()

        let response = coordinator.handleSidebarV1(
            command: "report_shell_state",
            args: "prompt --tab=\(workspaceID.uuidString) "
                + "--panel=\(panelID.uuidString) "
                + "--terminal-lifecycle-id=\(terminalLifecycleID.uuidString)"
        )

        #expect(response == "OK")
        #expect(context.shellStateCall?.scope.workspaceID == workspaceID)
        #expect(context.shellStateCall?.scope.panelID == panelID)
        #expect(
            context.shellStateCall?.scope.terminalLifecycleID
                == terminalLifecycleID
        )
        #expect(context.shellStateCall?.stateRawValue == "promptIdle")
    }

    @Test func shellStateRejectsMalformedTerminalLifecycleScope() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let response = coordinator.handleSidebarV1(
            command: "report_shell_state",
            args: "prompt --tab=\(UUID().uuidString) "
                + "--panel=\(UUID().uuidString) "
                + "--terminal-lifecycle-id=not-a-uuid"
        )

        #expect(response == "ERROR: Terminal session is out of date; restart the shell and try again")
        #expect(context.shellStateCall == nil)
    }

    @Test func shellStateRejectsLifecycleIdentityWithoutCompleteScope() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let response = coordinator.handleSidebarV1(
            command: "report_shell_state",
            args: "prompt --tab=\(UUID().uuidString) "
                + "--terminal-lifecycle-id=\(UUID().uuidString)"
        )

        #expect(response == "ERROR: Terminal session is out of date; restart the shell and try again")
        #expect(context.shellStateCall == nil)
    }

    @Test func workspacePullRequestHandoffUsesWorkspaceScope() throws {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let url = try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/12746"))

        let response = coordinator.handleSidebarV1(
            command: "report_workspace_pr",
            args: "12746 \"\(url.absoluteString)\" --label=PR --state=merged "
                + "--branch=feature/pr --tab=\(workspaceID.uuidString)"
        )

        #expect(response == "OK")
        #expect(context.manualPullRequestCall?.tabArg == workspaceID.uuidString)
        #expect(context.manualPullRequestCall?.number == 12746)
        #expect(context.manualPullRequestCall?.label == "PR")
        #expect(context.manualPullRequestCall?.url == url)
        #expect(context.manualPullRequestCall?.state == "merged")
        #expect(context.manualPullRequestCall?.branch == "feature/pr")
    }

    @Test(arguments: ["report_workspace_pr", "clear_workspace_pr"])
    func workspacePullRequestRejectsMissingWorkspace(command: String) {
        let context = FakeSidebarV1ControlCommandContext()
        context.manualPullRequestAvailable = false
        let coordinator = ControlCommandCoordinator(context: context)
        let target = "--tab=\(UUID().uuidString)"
        let args = command == "report_workspace_pr"
            ? "123 https://github.com/owner/repo/pull/123 \(target)"
            : target
        #expect(coordinator.handleSidebarV1(command: command, args: args)?.hasPrefix("ERROR") == true)
        #expect(context.manualPullRequestCall == nil)
        #expect(context.manualPullRequestClearTab == nil)
    }

    @Test func workspacePullRequestClearUsesWorkspaceScope() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()

        let response = coordinator.handleSidebarV1(
            command: "clear_workspace_pr",
            args: "--tab=\(workspaceID.uuidString)"
        )

        #expect(response == "OK")
        #expect(context.manualPullRequestClearTab == workspaceID.uuidString)
    }
    @Test(arguments: [
        "123 https://github.com/owner/repo/pull/123",
        "123 https://github.com/owner/repo/pull/123 --tab=",
        "123 javascript:alert(1) --tab=11111111-1111-1111-1111-111111111111",
        "123 https://github.com/owner/repo/pull/124 --tab=11111111-1111-1111-1111-111111111111",
        "123 https://github.com/owner/repo/pull/123 --tab=11111111-1111-1111-1111-111111111111 --state=invalid"
    ])
    func workspacePullRequestRejectsInvalidHandoffBeforeMutation(args: String) {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        #expect(coordinator.handleSidebarV1(command: "report_workspace_pr", args: args)?.hasPrefix("ERROR") == true)
        #expect(context.manualPullRequestCall == nil)
    }

}
