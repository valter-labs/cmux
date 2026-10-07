public import Foundation

/// One keyed status row shown under a workspace in the sidebar
/// (e.g. an agent status line), as reported over the control socket.
public struct SidebarStatusEntry: Equatable, Sendable {
    /// Stable key identifying the row (last write per key wins).
    public let key: String
    /// The displayed status text.
    public let value: String
    /// Optional SF Symbol name shown before the text.
    public let icon: String?
    /// Optional hex color for the row.
    public let color: String?
    /// Optional URL the row opens when clicked.
    public let url: URL?
    /// Sort priority (higher sorts first).
    public let priority: Int
    /// How `value` is rendered.
    public let format: SidebarMetadataFormat
    /// When the entry was reported.
    public let timestamp: Date
    /// Optional explanatory tooltip shown alongside the text (for example
    /// that an agent-usage cost is an estimate).
    public let helpText: String?
    /// What the agent is running on, when the reporter said so. `nil` on every
    /// entry that is not an agent row, and on agent rows from a reporter that
    /// does not report it.
    public let workState: SidebarAgentWorkState?
    /// Whether this entry's presentation is restored with its workspace session.
    ///
    /// Retains key/value, icon, color, HTTP(S) URL, priority, format, help text and
    /// publication timestamp. Defaults to `false` because runtime agent status may
    /// be stale after restart. Persistence never restores `workState`, agent PIDs
    /// or execution state.
    public let persist: Bool

    /// Creates a status row (defaults mirror the legacy initializer).
    ///
    /// - Parameter persist: Whether to restore this entry after restart; defaults
    ///   to `false` to preserve the lifetime of existing runtime status reporters.
    public init(
        key: String,
        value: String,
        icon: String? = nil,
        color: String? = nil,
        url: URL? = nil,
        priority: Int = 0,
        format: SidebarMetadataFormat = .plain,
        timestamp: Date = Date(),
        helpText: String? = nil,
        workState: SidebarAgentWorkState? = nil,
        persist: Bool = false
    ) {
        self.key = key
        self.value = value
        self.icon = icon
        self.color = color
        self.url = url
        self.priority = priority
        self.format = format
        self.timestamp = timestamp
        self.helpText = helpText
        self.workState = workState
        self.persist = persist
    }
}
