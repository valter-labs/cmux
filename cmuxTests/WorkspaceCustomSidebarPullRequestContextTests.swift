import XCTest
import CmuxSidebar
import CmuxWorkspaces
import CmuxSwiftRender

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceCustomSidebarPullRequestContextTests: XCTestCase {
    @MainActor
    func testAutosaveTracksPersistentStatusChangesWithoutChangingEntryCount() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let key = "history"
        let publication = Date(timeIntervalSince1970: 0)
        workspace.statusEntries[key] = SidebarStatusEntry(key: key, value: "Earlier", timestamp: publication)
        let transientFingerprint = manager.sessionAutosaveFingerprint()

        workspace.statusEntries[key] = SidebarStatusEntry(key: key, value: "Earlier", timestamp: publication, persist: true)
        let persistentFingerprint = manager.sessionAutosaveFingerprint()
        XCTAssertNotEqual(transientFingerprint, persistentFingerprint)

        workspace.statusEntries[key] = SidebarStatusEntry(key: key, value: "Later", timestamp: publication, persist: true)
        let updatedFingerprint = manager.sessionAutosaveFingerprint()
        XCTAssertNotEqual(persistentFingerprint, updatedFingerprint)

        workspace.statusEntries[key] = SidebarStatusEntry(key: key, value: "Later", timestamp: publication)
        XCTAssertNotEqual(updatedFingerprint, manager.sessionAutosaveFingerprint())
    }

    func testCapabilitiesAdvertiseCustomSidebarStatusSupport() throws {
        let capabilities = TerminalController.shared.v2CapabilitiesWithBrowserDesignMode(params: [:])
        let customSidebar = try XCTUnwrap(capabilities["custom_sidebar"] as? [String: Bool])
        XCTAssertEqual(customSidebar["workspace_status_entries"], true)
        XCTAssertEqual(customSidebar["persistent_status_entries"], true)
    }

    @MainActor
    func testSessionRestoreKeepsOnlyExplicitlyPersistentStatusEntries() throws {
        let workspace = Workspace()
        let key = "historical-data"
        let value = "Última conversa: 2026-10-07T09:00:00Z"
        workspace.statusEntries[key] = SidebarStatusEntry(key: key, value: value)
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Running")
        workspace.statusEntries["transient"] = SidebarStatusEntry(key: "transient", value: "Unpersisted")
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var entries = try XCTUnwrap(json["statusEntries"] as? [[String: Any]])
        let historicalIndex = try XCTUnwrap(entries.firstIndex { $0["key"] as? String == key })
        entries[historicalIndex]["persist"] = true
        let transientIndex = try XCTUnwrap(entries.firstIndex { $0["key"] as? String == "transient" })
        entries[transientIndex]["persist"] = false
        json["statusEntries"] = entries
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        let restored = Workspace()
        restored.restoreSessionSnapshot(decoded)

        XCTAssertEqual(restored.statusEntries[key]?.value, value)
        XCTAssertNil(restored.statusEntries["claude_code"])
        XCTAssertNil(restored.statusEntries["transient"])
        XCTAssertNil(restored.statusEntries[key]?.workState)
        XCTAssertEqual(
            restored.customSidebarWorkspaceSnapshot(index: 0, selectedId: nil, unreadCount: 0).statusEntries,
            [key: value]
        )
    }

    @MainActor
    func testCustomSidebarStatusTextsProjectAndSurviveSessionEncoding() throws {
        let workspace = Workspace()
        let key = "cmux-safe-ops.last-turn.v1"
        let value = "Última conversa: 2026-10-07T09:00:00Z"
        let publicationTime = Date(timeIntervalSince1970: 1_800_000_000)
        workspace.statusEntries[key] = SidebarStatusEntry(
            key: key,
            value: value,
            icon: "clock",
            color: "#123456",
            timestamp: publicationTime,
            persist: true
        )
        workspace.statusEntries["deploy"] = SidebarStatusEntry(key: "deploy", value: "Ready")
        let expected = [key: value, "deploy": "Ready"]
        let builder = CustomSidebarDataContextBuilder()
        let projected = workspace.customSidebarWorkspaceSnapshot(index: 0, selectedId: workspace.id, unreadCount: 0)

        XCTAssertEqual(projected.statusEntries, expected)
        XCTAssertEqual(
            builder.workspaceValue(projected).member("statusEntries"),
            .object(expected.mapValues { .string($0) })
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
        let encodedEntry = try XCTUnwrap(decoded.statusEntries.first { $0.key == key })
        XCTAssertEqual(encodedEntry.value, value)
        XCTAssertEqual(encodedEntry.timestamp, publicationTime.timeIntervalSince1970)
        XCTAssertEqual(encodedEntry.persist, true)

        let restored = Workspace()
        restored.restoreSessionSnapshot(decoded)
        XCTAssertEqual(restored.statusEntries[key]?.value, value)
        XCTAssertEqual(restored.statusEntries[key]?.persist, true)
        XCTAssertNil(restored.statusEntries["deploy"])
        XCTAssertNil(restored.statusEntries[key]?.workState)
        XCTAssertEqual(
            restored.customSidebarWorkspaceSnapshot(index: 0, selectedId: nil, unreadCount: 0).statusEntries,
            [key: value]
        )

        workspace.statusEntries[key] = SidebarStatusEntry(key: key, value: "Última conversa: 2026-10-07T10:00:00Z")
        let updated = workspace.customSidebarWorkspaceSnapshot(index: 0, selectedId: workspace.id, unreadCount: 0)
        XCTAssertEqual(updated.statusEntries[key], "Última conversa: 2026-10-07T10:00:00Z")
        XCTAssertEqual(updated.statusEntries["deploy"], "Ready")
        XCTAssertEqual(projected.statusEntries, expected)
    }

    func testStatusPersistenceChangeReplacesUnchangedText() {
        let entry = SidebarStatusEntry(key: "history", value: "Same text")
        XCTAssertTrue(TerminalController.shouldReplaceStatusEntry(
            current: entry,
            key: entry.key,
            value: entry.value,
            icon: nil,
            color: nil,
            url: nil,
            priority: 0,
            format: .plain,
            workState: nil,
            persist: true
        ))
    }

    @MainActor
    func testCustomSidebarSurfacePersistsAndRestoresAsPane() throws {
        let sidebarName = "__cmux_restore_sidebar_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try withTemporaryCustomSidebarsDirectory { directory in
            let fileURL = directory.appendingPathComponent("\(sidebarName).swift")
            try #"Text("Restored")"#.write(to: fileURL, atomically: true, encoding: .utf8)
            CmuxEventBus.shared.resetForTesting()
            defer { CmuxEventBus.shared.resetForTesting() }

            let workspace = Workspace()
            let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
            CmuxEventBus.shared.resetForTesting()
            let panel = try XCTUnwrap(
                workspace.newCustomSidebarSurface(inPane: paneId, name: sidebarName, focus: true)
            )
            let surfaceEvent = try XCTUnwrap(
                CmuxEventBus.shared.retainedSnapshot().first { $0["name"] as? String == "surface.created" }
            )
            let surfacePayload = try XCTUnwrap(surfaceEvent["payload"] as? [String: Any])
            XCTAssertEqual(surfacePayload["kind"] as? String, "custom_sidebar")

            let snapshot = workspace.sessionSnapshot(includeScrollback: false)
            let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panel.id })
            XCTAssertEqual(panelSnapshot.type, .customSidebar)
            XCTAssertEqual(panelSnapshot.customSidebar?.name, sidebarName)

            let restored = Workspace()
            restored.restoreSessionSnapshot(snapshot)

            let restoredPanel = try XCTUnwrap(
                restored.panels.values.compactMap { $0 as? CustomSidebarPanel }.first { $0.name == sidebarName }
            )
            XCTAssertEqual(restoredPanel.panelType, .customSidebar)
            XCTAssertEqual(
                restored.surfaceIdFromPanelId(restoredPanel.id).flatMap { restored.bonsplitController.tab($0)?.kind },
                SurfaceKind.customSidebar.rawValue
            )
        }
    }

    @MainActor
    func testSplitCustomSidebarPublishesNewPaneLifecycleEvents() throws {
        let sidebarName = "__cmux_split_sidebar_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try withTemporaryCustomSidebarsDirectory { directory in
            let fileURL = directory.appendingPathComponent("\(sidebarName).swift")
            try #"Text("Split")"#.write(to: fileURL, atomically: true, encoding: .utf8)
            CmuxEventBus.shared.resetForTesting()
            defer { CmuxEventBus.shared.resetForTesting() }

            let workspace = Workspace()
            let sourcePaneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
            CmuxEventBus.shared.resetForTesting()

            let panel = try XCTUnwrap(
                workspace.splitPaneWithCustomSidebar(
                    targetPane: sourcePaneId,
                    orientation: .horizontal,
                    insertFirst: false,
                    name: sidebarName
                )
            )
            let customPaneId = try XCTUnwrap(workspace.paneId(forPanelId: panel.id))

            XCTAssertNotEqual(customPaneId.id, sourcePaneId.id)
            let events = CmuxEventBus.shared.retainedSnapshot()
            let paneEvent = try XCTUnwrap(events.first { $0["name"] as? String == "pane.created" })
            XCTAssertEqual(paneEvent["pane_id"] as? String, customPaneId.id.uuidString)
            let panePayload = try XCTUnwrap(paneEvent["payload"] as? [String: Any])
            XCTAssertEqual(panePayload["pane_id"] as? String, customPaneId.id.uuidString)
            XCTAssertEqual(panePayload["source_pane_id"] as? String, sourcePaneId.id.uuidString)
            XCTAssertEqual(panePayload["surface_id"] as? String, panel.id.uuidString)

            let surfaceEvent = try XCTUnwrap(events.first { $0["name"] as? String == "surface.created" })
            XCTAssertEqual(surfaceEvent["surface_id"] as? String, panel.id.uuidString)
            XCTAssertEqual(surfaceEvent["pane_id"] as? String, customPaneId.id.uuidString)
            let surfacePayload = try XCTUnwrap(surfaceEvent["payload"] as? [String: Any])
            XCTAssertEqual(surfacePayload["pane_id"] as? String, customPaneId.id.uuidString)
            XCTAssertEqual(surfacePayload["kind"] as? String, "custom_sidebar")
        }
    }

    func testV2CustomSidebarOpenReturnsErrorWhenValidationFails() throws {
        let missingName = "__cmux_missing_sidebar_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try withTemporaryCustomSidebarsDirectory { _ in

            switch TerminalController.shared.v2CustomSidebarOpen(params: ["name": missingName]) {
            case .err(let code, _, let data):
                XCTAssertEqual(code, "validation_failed")
                let payload = data as? [String: Any]
                XCTAssertEqual(payload?["error_count"] as? Int, 1)
            case .ok(let payload):
                XCTFail("Expected validation error, got \(payload)")
            }
        }
    }

    @MainActor
    func testV2CustomSidebarOpenRejectsMalformedWorkspaceTarget() throws {
        let sidebarName = "__cmux_target_sidebar_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try withTemporaryCustomSidebarsDirectory { directory in
            let fileURL = directory.appendingPathComponent("\(sidebarName).swift")
            try #"Text("Target")"#.write(to: fileURL, atomically: true, encoding: .utf8)

            switch TerminalController.shared.v2CustomSidebarOpen(
                params: ["name": sidebarName, "workspace_id": "not-a-workspace"]
            ) {
            case .err(let code, let message, _):
                XCTAssertEqual(code, "invalid_params")
                XCTAssertEqual(
                    message,
                    String(
                        localized: "socket.sidebar.custom.openInvalidWorkspaceId",
                        defaultValue: "Missing or invalid workspace_id"
                    )
                )
            case .ok(let payload):
                XCTFail("Expected invalid_params, got \(payload)")
            }
        }
    }

    @MainActor
    func testV2CustomSidebarOpenFallsBackWhenFocusedPanelCannotSplit() throws {
        let sidebarName = "__cmux_fallback_sidebar_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try withTemporaryCustomSidebarsDirectory { directory in
            let fileURL = directory.appendingPathComponent("\(sidebarName).swift")
            try #"Text("Fallback")"#.write(to: fileURL, atomically: true, encoding: .utf8)

            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            defer { AppDelegate.shared = previousAppDelegate }

            let tabManager = TabManager()
            let workspace = tabManager.addWorkspace(select: true, eagerLoadTerminal: false)
            let windowId = UUID()
            appDelegate.registerMainWindowContextForTesting(
                windowId: windowId,
                tabManager: tabManager,
                fileExplorerState: FileExplorerState()
            )
            defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

            let staleFocusedPanelId = try XCTUnwrap(workspace.focusedPanelId)
            workspace.panels.removeValue(forKey: staleFocusedPanelId)

            switch TerminalController.shared.v2CustomSidebarOpen(
                params: ["name": sidebarName, "workspace_id": workspace.id.uuidString, "focus": true]
            ) {
            case .ok(let payload):
                let dictionary = try XCTUnwrap(payload as? [String: Any])
                XCTAssertEqual(dictionary["opened_name"] as? String, sidebarName)
                XCTAssertEqual(dictionary["type"] as? String, PanelType.customSidebar.rawValue)
            case .err(let code, let message, _):
                XCTFail("Expected fallback open to succeed, got \(code): \(message)")
            }

            XCTAssertNotNil(
                workspace.panels.values.compactMap { $0 as? CustomSidebarPanel }.first { $0.name == sidebarName }
            )
        }
    }

    @MainActor
    func testValuesIncludePanelPullRequestWhenFocusedPanelMirrorIsNil() throws {
        let workspace = Workspace(
            title: "Tests",
            workingDirectory: FileManager.default.currentDirectoryPath,
            portOrdinal: 0
        )
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 5314,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/5314")!,
            status: .open
        )
        // The focused-panel `pullRequest` mirror only refreshes while its panel
        // is focused, so live sessions routinely hold panel pull requests with a
        // nil mirror. The interpreter context must project from the per-panel
        // state, not the mirror.
        workspace.pullRequest = nil

        let values = workspace.customSidebarPullRequestValues()
        XCTAssertEqual(values.count, 1)
        guard case .object(let fields)? = values.first else {
            XCTFail("Expected object pull-request value, got \(String(describing: values.first))")
            return
        }
        XCTAssertEqual(fields["number"], .int(5314))
        XCTAssertEqual(fields["status"], .string("open"))
        XCTAssertEqual(fields["url"], .string("https://github.com/manaflow-ai/cmux/pull/5314"))
        XCTAssertEqual(fields["stale"], .bool(false))
    }

    @MainActor
    func testValuesEmptyWhenWorkspaceHasNoPullRequests() {
        let workspace = Workspace(
            title: "Tests",
            workingDirectory: FileManager.default.currentDirectoryPath,
            portOrdinal: 0
        )

        XCTAssertEqual(workspace.customSidebarPullRequestValues(), [])
    }

    private func withTemporaryCustomSidebarsDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebars-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try CmuxExtensionSidebarSelection.withCustomSidebarsDirectoryForTesting(directory) {
            try body(directory)
        }
    }
}
