#!/usr/bin/env python3
"""Run the native sidebar projection with distinct view, panel and remote IDs."""

import json
import subprocess
import unittest
from pathlib import Path

from regression_helpers import extract_block

ROOT = Path(__file__).resolve().parents[1]


class CustomSidebarAgentFocusTests(unittest.TestCase):
    def test_agent_focus_targets_match_tabs_and_preserve_roster_membership(self):
        source = (ROOT / "Sources/Workspace+CustomSidebarSnapshot.swift").read_text()
        signatures = [
            "private func customSidebarAgentSnapshots() -> [CustomSidebarAgentSnapshot]",
            "private func customSidebarSurfaceSnapshots(focusedPanelId: UUID?) -> [CustomSidebarSurfaceSnapshot]",
        ]
        helper = "private func customSidebarFocusSurfaceId(panelId: UUID) -> UUID?"
        if helper in source:
            signatures.append(helper)
        methods = "\n".join(signature + " " + extract_block(source, signature) for signature in signatures)
        snapshots = "\n".join(
            (ROOT / "Packages/macOS/CmuxSidebar/Sources/CmuxSidebar/Layout" / filename).read_text()
            for filename in ["CustomSidebarAgentSnapshot.swift", "CustomSidebarSurfaceSnapshot.swift"]
        )
        harness = r"""
import Foundation
struct TabID { let uuid: UUID }
struct Tab { let id: TabID; let title = "terminal" }
struct Bonsplit {
    let tabs: [Tab]
    var allPaneIds: [Int] { [0] }
    func tabs(inPane: Int) -> [Tab] { tabs }
}
enum State { case idle, working(Date), needsInput(Date), ended }
struct Kind { let sourceName = "claude"; let displayName = "Claude" }
struct Record {
    let sessionID: String
    let surfaceID: String?
    let workspaceID: String?
    let state: State = .needsInput(Date(timeIntervalSince1970: 100))
    let agentKind = Kind()
    let lastActivityAt = Date(timeIntervalSince1970: 101)
    let title: String? = "Needs attention"
    let workingDirectory: String? = nil
    let transcriptPath: String? = nil
    let pid: Int? = nil
    let children: [CustomSidebarAgentChildSnapshot] = []
}
struct Service {
    let records: [Record]
    func sessionRecords(workspaceID: String?) -> [Record] { records }
}
@MainActor final class TerminalController {
    static let shared = TerminalController()
    var agentChatTranscriptService: Service?
}
struct Projection { let surfaceID: UUID }
struct Git { let branch: String; let isDirty: Bool }
struct Prompt { let message: String; let submittedAt: Date }
@MainActor struct Workspace {
    let id: UUID
    let bonsplitController: Bonsplit
    let panelIds: [UUID: UUID]
    let remotePanels: Set<UUID>
    let projections: [UUID: UUID]
    let pinnedPanelIds: Set<UUID> = []
    let panelPrompts: [UUID: Prompt] = [:]
    let surfaceListeningPorts: [UUID: [Int]] = [:]
    private static let customSidebarAgentLimit = 24
    func panelIdFromSurfaceId(_ tab: TabID) -> UUID? { panelIds[tab.uuid] }
    func isRemoteTmuxControlContainer(_ panelId: UUID) -> Bool { remotePanels.contains(panelId) }
    func activeRemoteTmuxControlSurfaceProjection(containerPanelID: UUID) -> Projection? {
        projections[containerPanelID].map { Projection(surfaceID: $0) }
    }
    func reportedPanelGitBranch(panelId: UUID) -> Git? { nil }
    func reportedPanelDirectory(panelId: UUID) -> String? { nil }
    func hasUnreadNotification(panelId: UUID) -> Bool { false }
    METHODS
    func result() -> [String: Any] {
        let agents = customSidebarAgentSnapshots()
        let tabs = customSidebarSurfaceSnapshots(focusedPanelId: nil)
        return [
            "agents": agents.map { ["id": $0.sessionId, "panel": $0.panelId?.uuidString ?? "", "focus": $0.surfaceId?.uuidString ?? ""] },
            "tabs": tabs.map { ["panel": $0.panelId.uuidString, "focus": $0.surfaceId?.uuidString ?? ""] }
        ]
    }
}
let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
let panel = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
let visualTab = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
let remoteSurface = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
let unknownPanel = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
let unknownTab = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
TerminalController.shared.agentChatTranscriptService = Service(records: [
    Record(sessionID: "bound-stale-workspace", surfaceID: panel.uuidString, workspaceID: unknownPanel.uuidString),
    Record(sessionID: "closed-panel", surfaceID: unknownPanel.uuidString, workspaceID: workspaceId.uuidString),
    Record(sessionID: "unbound-local", surfaceID: nil, workspaceID: workspaceId.uuidString),
    Record(sessionID: "unbound-other", surfaceID: nil, workspaceID: unknownPanel.uuidString)
])
var results: [String: Any] = [:]
for scenario in ["local", "remote", "remote-unprojected"] {
    let workspace = Workspace(
        id: workspaceId,
        bonsplitController: Bonsplit(tabs: [Tab(id: TabID(uuid: visualTab)), Tab(id: TabID(uuid: unknownTab))]),
        panelIds: [visualTab: panel],
        remotePanels: scenario == "local" ? [] : [panel],
        projections: scenario == "remote" ? [panel: remoteSurface] : [:]
    )
    results[scenario] = workspace.result()
}
TerminalController.shared.agentChatTranscriptService = nil
results["no-service"] = Workspace(id: workspaceId, bonsplitController: Bonsplit(tabs: []), panelIds: [:], remotePanels: [], projections: [:]).result()
let data = try JSONSerialization.data(withJSONObject: results)
print(String(decoding: data, as: UTF8.self))
""".replace("METHODS", methods)
        result = subprocess.run(
            ["swift", "-swift-version", "6", "-"],
            input=snapshots + harness, cwd=ROOT, text=True, capture_output=True, timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        panel = "00000000-0000-0000-0000-000000000002"
        expected_targets = {"local": panel, "remote": "00000000-0000-0000-0000-000000000004", "remote-unprojected": ""}
        for scenario, expected_focus in expected_targets.items():
            with self.subTest(scenario=scenario):
                agents = payload[scenario]["agents"]
                tabs = payload[scenario]["tabs"]
                self.assertEqual([agent["id"] for agent in agents], ["bound-stale-workspace", "unbound-local"])
                self.assertEqual(len(tabs), 1)
                self.assertEqual(agents[0]["panel"], panel)
                self.assertEqual(agents[0]["focus"], expected_focus)
                self.assertEqual(agents[0]["focus"], tabs[0]["focus"])
                self.assertEqual(agents[1]["focus"], "")
                self.assertEqual(agents[1]["panel"], "")
        self.assertEqual(payload["no-service"]["agents"], [])


if __name__ == "__main__":
    unittest.main()
