const std = @import("std");

const ai = @import("bulb_ai");
const tui = @import("bulb_tui");
const bash_executor = @import("../bash_executor.zig");
const keybindings = @import("../keybindings.zig");
const messages = @import("../messages.zig");
const model_registry = @import("../model_registry.zig");
const session_manager = @import("../session_manager.zig");
const source_info = @import("../source_info.zig");
const system_prompt = @import("../system_prompt.zig");
const theme_mod = @import("../theme.zig");
const tools = @import("../tools/root.zig");

pub const AgentMessage = messages.CodingAgentMessage;
pub const AgentToolResult = tools.tool_registry.ToolExecution;
pub const AgentToolUpdateCallback = tools.bash.BashUpdateCallback;
pub const AppKeybinding = keybindings.KeybindingDefinition;
pub const AutocompleteItem = tui.AutocompleteItem;
pub const AutocompleteProvider = tui.AutocompleteProvider;
pub const BuildSystemPromptOptions = system_prompt.BuildSystemPromptOptions;
pub const Component = tui.Component;
pub const EditorComponent = tui.EditorComponent;
pub const EditorTheme = tui.EditorTheme;
pub const KeyId = tui.KeyId;
pub const KeybindingsManager = keybindings.KeybindingsManager;
pub const ModelRegistry = model_registry.ModelRegistry;
pub const ReadonlySessionManager = session_manager.SessionManager;
pub const SessionManager = session_manager.SessionManager;
pub const SessionEntry = session_manager.FileEntry;
pub const BranchSummaryEntry = session_manager.FileEntry;
pub const CompactionEntry = session_manager.FileEntry;
pub const SourceInfo = source_info.SourceInfo;
pub const Theme = theme_mod.Theme;
pub const ToolDefinition = tools.tool_registry.ToolDefinition;
pub const ToolExecutionMode = tools.tool_registry.ToolExecutionMode;

pub const ExtensionEventName = enum {
    resources_discover,
    session_start,
    session_before_switch,
    session_before_fork,
    session_before_compact,
    session_compact,
    session_shutdown,
    session_before_tree,
    session_tree,
    context,
    before_provider_request,
    after_provider_response,
    before_agent_start,
    agent_start,
    agent_end,
    turn_start,
    turn_end,
    message_start,
    message_update,
    message_end,
    tool_execution_start,
    tool_execution_update,
    tool_execution_end,
    model_select,
    thinking_level_select,
    user_bash,
    input,
    tool_call,
    tool_result,

    pub fn text(self: ExtensionEventName) []const u8 {
        return switch (self) {
            .resources_discover => "resources_discover",
            .session_start => "session_start",
            .session_before_switch => "session_before_switch",
            .session_before_fork => "session_before_fork",
            .session_before_compact => "session_before_compact",
            .session_compact => "session_compact",
            .session_shutdown => "session_shutdown",
            .session_before_tree => "session_before_tree",
            .session_tree => "session_tree",
            .context => "context",
            .before_provider_request => "before_provider_request",
            .after_provider_response => "after_provider_response",
            .before_agent_start => "before_agent_start",
            .agent_start => "agent_start",
            .agent_end => "agent_end",
            .turn_start => "turn_start",
            .turn_end => "turn_end",
            .message_start => "message_start",
            .message_update => "message_update",
            .message_end => "message_end",
            .tool_execution_start => "tool_execution_start",
            .tool_execution_update => "tool_execution_update",
            .tool_execution_end => "tool_execution_end",
            .model_select => "model_select",
            .thinking_level_select => "thinking_level_select",
            .user_bash => "user_bash",
            .input => "input",
            .tool_call => "tool_call",
            .tool_result => "tool_result",
        };
    }

    pub fn parse(name: []const u8) ?ExtensionEventName {
        inline for (all_event_names) |event_name| {
            if (std.mem.eql(u8, name, event_name.text())) return event_name;
        }
        return null;
    }
};

pub const all_event_names = [_]ExtensionEventName{
    .resources_discover,
    .session_start,
    .session_before_switch,
    .session_before_fork,
    .session_before_compact,
    .session_compact,
    .session_shutdown,
    .session_before_tree,
    .session_tree,
    .context,
    .before_provider_request,
    .after_provider_response,
    .before_agent_start,
    .agent_start,
    .agent_end,
    .turn_start,
    .turn_end,
    .message_start,
    .message_update,
    .message_end,
    .tool_execution_start,
    .tool_execution_update,
    .tool_execution_end,
    .model_select,
    .thinking_level_select,
    .user_bash,
    .input,
    .tool_call,
    .tool_result,
};

pub const WidgetPlacement = enum {
    above_editor,
    below_editor,

    pub fn text(self: WidgetPlacement) []const u8 {
        return switch (self) {
            .above_editor => "aboveEditor",
            .below_editor => "belowEditor",
        };
    }

    pub fn parse(name: []const u8) ?WidgetPlacement {
        if (std.mem.eql(u8, name, "aboveEditor")) return .above_editor;
        if (std.mem.eql(u8, name, "belowEditor")) return .below_editor;
        return null;
    }
};

pub const ExtensionMode = enum {
    tui,
    rpc,
    json,
    print,

    pub fn text(self: ExtensionMode) []const u8 {
        return @tagName(self);
    }

    pub fn parse(name: []const u8) ?ExtensionMode {
        inline for (.{ .tui, .rpc, .json, .print }) |mode| {
            if (std.mem.eql(u8, name, @tagName(mode))) return mode;
        }
        return null;
    }
};

pub const InputSource = enum {
    interactive,
    rpc,
    extension,

    pub fn text(self: InputSource) []const u8 {
        return @tagName(self);
    }

    pub fn parse(name: []const u8) ?InputSource {
        inline for (.{ .interactive, .rpc, .extension }) |source| {
            if (std.mem.eql(u8, name, @tagName(source))) return source;
        }
        return null;
    }
};

pub const StreamingBehavior = enum {
    steer,
    follow_up,

    pub fn text(self: StreamingBehavior) []const u8 {
        return switch (self) {
            .steer => "steer",
            .follow_up => "followUp",
        };
    }
};

pub const ModelSelectSource = enum {
    set,
    cycle,
    restore,

    pub fn text(self: ModelSelectSource) []const u8 {
        return @tagName(self);
    }
};

pub const SessionStartReason = enum {
    startup,
    reload,
    new,
    @"resume",
    fork,

    pub fn text(self: SessionStartReason) []const u8 {
        return @tagName(self);
    }
};

pub const SessionReplacementReason = enum {
    new,
    @"resume",

    pub fn text(self: SessionReplacementReason) []const u8 {
        return @tagName(self);
    }
};

pub const SessionShutdownReason = enum {
    quit,
    reload,
    new,
    @"resume",
    fork,

    pub fn text(self: SessionShutdownReason) []const u8 {
        return @tagName(self);
    }
};

pub const ForkPosition = enum {
    before,
    at,

    pub fn text(self: ForkPosition) []const u8 {
        return @tagName(self);
    }
};

pub const ResourcesDiscoverReason = enum {
    startup,
    reload,

    pub fn text(self: ResourcesDiscoverReason) []const u8 {
        return @tagName(self);
    }
};

pub const SlashCommandSource = enum {
    extension,
    prompt,
    skill,

    pub fn text(self: SlashCommandSource) []const u8 {
        return @tagName(self);
    }
};

pub const FlagValue = union(enum) {
    boolean: bool,
    string: []const u8,
};

pub const ExtensionUIDialogOptions = struct {
    signal: ?*const ai.AbortSignal = null,
    timeout_ms: ?u64 = null,
};

pub const ExtensionWidgetOptions = struct {
    placement: WidgetPlacement = .above_editor,
};

pub const TerminalInputResult = struct {
    consume: bool = false,
    data: ?[]const u8 = null,
};

pub const TerminalInputHandler = struct {
    ptr: ?*anyopaque = null,
    handle_fn: *const fn (?*anyopaque, []const u8) anyerror!?TerminalInputResult,

    pub fn handle(self: TerminalInputHandler, data: []const u8) !?TerminalInputResult {
        return self.handle_fn(self.ptr, data);
    }
};

pub const WorkingIndicatorOptions = struct {
    frames: ?[]const []const u8 = null,
    interval_ms: ?u64 = null,
};

pub const AutocompleteProviderFactory = struct {
    ptr: ?*anyopaque = null,
    wrap_fn: *const fn (?*anyopaque, AutocompleteProvider) anyerror!AutocompleteProvider,

    pub fn wrap(self: AutocompleteProviderFactory, current: AutocompleteProvider) !AutocompleteProvider {
        return self.wrap_fn(self.ptr, current);
    }
};

pub const EditorFactory = struct {
    ptr: ?*anyopaque = null,
    create_fn: *const fn (?*anyopaque, *tui.TUI, EditorTheme, *KeybindingsManager) anyerror!EditorComponent,

    pub fn create(self: EditorFactory, terminal_ui: *tui.TUI, editor_theme: EditorTheme, manager: *KeybindingsManager) !EditorComponent {
        return self.create_fn(self.ptr, terminal_ui, editor_theme, manager);
    }
};

pub const DisposableComponent = struct {
    component: Component,
    ptr: ?*anyopaque = null,
    dispose_fn: ?*const fn (?*anyopaque) void = null,

    pub fn dispose(self: DisposableComponent) void {
        if (self.dispose_fn) |dispose_fn| dispose_fn(self.ptr);
    }
};

pub const ComponentFactory = struct {
    ptr: ?*anyopaque = null,
    create_fn: *const fn (?*anyopaque, *tui.TUI, Theme) anyerror!DisposableComponent,

    pub fn create(self: ComponentFactory, terminal_ui: *tui.TUI, active_theme: Theme) !DisposableComponent {
        return self.create_fn(self.ptr, terminal_ui, active_theme);
    }
};

pub const FooterComponentFactory = struct {
    ptr: ?*anyopaque = null,
    create_fn: *const fn (?*anyopaque, *tui.TUI, Theme, *const ReadonlyFooterDataProvider) anyerror!DisposableComponent,

    pub fn create(
        self: FooterComponentFactory,
        terminal_ui: *tui.TUI,
        active_theme: Theme,
        footer_data: *const ReadonlyFooterDataProvider,
    ) !DisposableComponent {
        return self.create_fn(self.ptr, terminal_ui, active_theme, footer_data);
    }
};

pub const CustomComponentFactory = struct {
    ptr: ?*anyopaque = null,
    create_fn: *const fn (?*anyopaque, *tui.TUI, Theme, *KeybindingsManager, DoneCallback) anyerror!DisposableComponent,

    pub fn create(
        self: CustomComponentFactory,
        terminal_ui: *tui.TUI,
        active_theme: Theme,
        manager: *KeybindingsManager,
        done: DoneCallback,
    ) !DisposableComponent {
        return self.create_fn(self.ptr, terminal_ui, active_theme, manager, done);
    }
};

pub const DoneCallback = struct {
    ptr: ?*anyopaque = null,
    done_fn: *const fn (?*anyopaque, std.json.Value) void,

    pub fn done(self: DoneCallback, value: std.json.Value) void {
        self.done_fn(self.ptr, value);
    }
};

pub const ReadonlyFooterDataProvider = struct {
    ptr: ?*anyopaque = null,
    get_git_branch_fn: ?*const fn (?*anyopaque) ?[]const u8 = null,
    get_status_fn: ?*const fn (?*anyopaque, []const u8) ?[]const u8 = null,

    pub fn getGitBranch(self: ReadonlyFooterDataProvider) ?[]const u8 {
        const get_fn = self.get_git_branch_fn orelse return null;
        return get_fn(self.ptr);
    }

    pub fn getStatus(self: ReadonlyFooterDataProvider, key: []const u8) ?[]const u8 {
        const get_fn = self.get_status_fn orelse return null;
        return get_fn(self.ptr, key);
    }
};

pub const NotificationType = enum { info, warning, @"error" };

pub const ThemeEntry = struct {
    name: []const u8,
    path: ?[]const u8 = null,
};

pub const ThemeSwitchResult = struct {
    success: bool,
    @"error": ?[]const u8 = null,
};

pub const ExtensionUIContext = struct {
    ptr: ?*anyopaque = null,
    select_fn: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8, []const []const u8, ExtensionUIDialogOptions) anyerror!?[]u8 = null,
    confirm_fn: ?*const fn (?*anyopaque, []const u8, []const u8, ExtensionUIDialogOptions) anyerror!bool = null,
    input_fn: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8, ?[]const u8, ExtensionUIDialogOptions) anyerror!?[]u8 = null,
    notify_fn: ?*const fn (?*anyopaque, []const u8, NotificationType) void = null,
    on_terminal_input_fn: ?*const fn (?*anyopaque, TerminalInputHandler) anyerror!Unsubscribe = null,
    set_status_fn: ?*const fn (?*anyopaque, []const u8, ?[]const u8) void = null,
    set_working_message_fn: ?*const fn (?*anyopaque, ?[]const u8) void = null,
    set_working_visible_fn: ?*const fn (?*anyopaque, bool) void = null,
    set_working_indicator_fn: ?*const fn (?*anyopaque, ?WorkingIndicatorOptions) void = null,
    set_hidden_thinking_label_fn: ?*const fn (?*anyopaque, ?[]const u8) void = null,
    set_widget_lines_fn: ?*const fn (?*anyopaque, []const u8, ?[]const []const u8, ExtensionWidgetOptions) void = null,
    set_widget_component_fn: ?*const fn (?*anyopaque, []const u8, ?ComponentFactory, ExtensionWidgetOptions) void = null,
    set_footer_fn: ?*const fn (?*anyopaque, ?FooterComponentFactory) void = null,
    set_header_fn: ?*const fn (?*anyopaque, ?ComponentFactory) void = null,
    set_title_fn: ?*const fn (?*anyopaque, []const u8) void = null,
    custom_fn: ?*const fn (?*anyopaque, std.mem.Allocator, CustomComponentFactory, CustomOptions) anyerror!std.json.Value = null,
    paste_to_editor_fn: ?*const fn (?*anyopaque, []const u8) void = null,
    set_editor_text_fn: ?*const fn (?*anyopaque, []const u8) void = null,
    get_editor_text_fn: ?*const fn (?*anyopaque) []const u8 = null,
    editor_fn: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8, ?[]const u8) anyerror!?[]u8 = null,
    add_autocomplete_provider_fn: ?*const fn (?*anyopaque, AutocompleteProviderFactory) void = null,
    set_editor_component_fn: ?*const fn (?*anyopaque, ?EditorFactory) void = null,
    get_editor_component_fn: ?*const fn (?*anyopaque) ?EditorFactory = null,
    theme: ?*const Theme = null,
    get_all_themes_fn: ?*const fn (?*anyopaque, std.mem.Allocator) anyerror![]ThemeEntry = null,
    get_theme_fn: ?*const fn (?*anyopaque, []const u8) ?*const Theme = null,
    set_theme_fn: ?*const fn (?*anyopaque, ThemeInput) ThemeSwitchResult = null,
    get_tools_expanded_fn: ?*const fn (?*anyopaque) bool = null,
    set_tools_expanded_fn: ?*const fn (?*anyopaque, bool) void = null,
};

pub const Unsubscribe = struct {
    ptr: ?*anyopaque = null,
    unsubscribe_fn: *const fn (?*anyopaque) void,

    pub fn unsubscribe(self: Unsubscribe) void {
        self.unsubscribe_fn(self.ptr);
    }
};

pub const CustomOptions = struct {
    overlay: bool = false,
    overlay_options_json: ?[]const u8 = null,
    on_handle_fn: ?*const fn (?*anyopaque, tui.OverlayHandle) void = null,
};

pub const ThemeInput = union(enum) {
    name: []const u8,
    theme: Theme,
};

pub const ContextUsage = struct {
    tokens: ?u64 = null,
    context_window: u64,
    percent: ?f64 = null,
};

pub const CompactOptions = struct {
    custom_instructions: ?[]const u8 = null,
    on_complete: ?CompactionCompleteCallback = null,
    on_error: ?CompactionErrorCallback = null,
};

pub const CompactionCompleteCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, CompactionResult) void,

    pub fn call(self: CompactionCompleteCallback, result: CompactionResult) void {
        self.call_fn(self.ptr, result);
    }
};

pub const CompactionErrorCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const u8) void,

    pub fn call(self: CompactionErrorCallback, message: []const u8) void {
        self.call_fn(self.ptr, message);
    }
};

pub const CompactionPreparation = struct {
    entries: []const SessionEntry = &.{},
    tokens: ?u64 = null,
};

pub const CompactionResult = struct {
    summary: []const u8,
    tokens_before: ?u64 = null,
    tokens_after: ?u64 = null,
    details_json: ?[]const u8 = null,
};

pub const ExtensionContextActions = struct {
    ptr: ?*anyopaque = null,
    get_model_fn: ?*const fn (?*anyopaque) ?*const ai.Model = null,
    is_idle_fn: ?*const fn (?*anyopaque) bool = null,
    get_signal_fn: ?*const fn (?*anyopaque) ?*const ai.AbortSignal = null,
    abort_fn: ?*const fn (?*anyopaque) void = null,
    has_pending_messages_fn: ?*const fn (?*anyopaque) bool = null,
    shutdown_fn: ?*const fn (?*anyopaque) void = null,
    get_context_usage_fn: ?*const fn (?*anyopaque) ?ContextUsage = null,
    compact_fn: ?*const fn (?*anyopaque, ?CompactOptions) void = null,
    get_system_prompt_fn: ?*const fn (?*anyopaque) []const u8 = null,
};

pub const ExtensionContext = struct {
    ui: *ExtensionUIContext,
    mode: ExtensionMode,
    has_ui: bool,
    cwd: []const u8,
    session_manager: *const ReadonlySessionManager,
    model_registry: *ModelRegistry,
    model: ?*const ai.Model = null,
    signal: ?*const ai.AbortSignal = null,
    actions: ExtensionContextActions = .{},

    pub fn isIdle(self: ExtensionContext) bool {
        const is_idle_fn = self.actions.is_idle_fn orelse return true;
        return is_idle_fn(self.actions.ptr);
    }

    pub fn abort(self: ExtensionContext) void {
        if (self.actions.abort_fn) |abort_fn| abort_fn(self.actions.ptr);
    }

    pub fn hasPendingMessages(self: ExtensionContext) bool {
        const has_fn = self.actions.has_pending_messages_fn orelse return false;
        return has_fn(self.actions.ptr);
    }

    pub fn shutdown(self: ExtensionContext) void {
        if (self.actions.shutdown_fn) |shutdown_fn| shutdown_fn(self.actions.ptr);
    }

    pub fn getContextUsage(self: ExtensionContext) ?ContextUsage {
        const get_fn = self.actions.get_context_usage_fn orelse return null;
        return get_fn(self.actions.ptr);
    }

    pub fn compact(self: ExtensionContext, options: ?CompactOptions) void {
        if (self.actions.compact_fn) |compact_fn| compact_fn(self.actions.ptr, options);
    }

    pub fn getSystemPrompt(self: ExtensionContext) []const u8 {
        const get_fn = self.actions.get_system_prompt_fn orelse return "";
        return get_fn(self.actions.ptr);
    }
};

pub const NewSessionOptions = struct {
    parent_session: ?[]const u8 = null,
    setup: ?SessionSetupCallback = null,
    with_session: ?WithSessionCallback = null,
};

pub const ForkOptions = struct {
    position: ForkPosition = .at,
    with_session: ?WithSessionCallback = null,
};

pub const NavigateTreeOptions = struct {
    summarize: bool = false,
    custom_instructions: ?[]const u8 = null,
    replace_instructions: bool = false,
    label: ?[]const u8 = null,
};

pub const SwitchSessionOptions = struct {
    with_session: ?WithSessionCallback = null,
};

pub const SessionChangeResult = struct {
    cancelled: bool = false,
};

pub const SessionSetupCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, *SessionManager) anyerror!void,

    pub fn call(self: SessionSetupCallback, manager: *SessionManager) !void {
        return self.call_fn(self.ptr, manager);
    }
};

pub const WithSessionCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, *ReplacedSessionContext) anyerror!void,

    pub fn call(self: WithSessionCallback, ctx: *ReplacedSessionContext) !void {
        return self.call_fn(self.ptr, ctx);
    }
};

pub const ExtensionCommandContextActions = struct {
    ptr: ?*anyopaque = null,
    wait_for_idle_fn: ?*const fn (?*anyopaque) anyerror!void = null,
    new_session_fn: ?*const fn (?*anyopaque, ?NewSessionOptions) anyerror!SessionChangeResult = null,
    fork_fn: ?*const fn (?*anyopaque, []const u8, ?ForkOptions) anyerror!SessionChangeResult = null,
    navigate_tree_fn: ?*const fn (?*anyopaque, []const u8, ?NavigateTreeOptions) anyerror!SessionChangeResult = null,
    switch_session_fn: ?*const fn (?*anyopaque, []const u8, ?SwitchSessionOptions) anyerror!SessionChangeResult = null,
    reload_fn: ?*const fn (?*anyopaque) anyerror!void = null,
};

pub const ExtensionCommandContext = struct {
    base: ExtensionContext,
    command_actions: ExtensionCommandContextActions = .{},
};

pub const ReplacedSessionContext = struct {
    command: ExtensionCommandContext,
    send_message_fn: ?SendMessageHandler = null,
    send_user_message_fn: ?SendUserMessageHandler = null,
};

pub const ToolRenderResultOptions = tools.render_utils.ToolRenderResultOptions;

pub const ToolRenderContext = struct {
    args: std.json.Value,
    tool_call_id: []const u8,
    invalidate_fn: ?*const fn (?*anyopaque) void = null,
    invalidate_ptr: ?*anyopaque = null,
    last_component: ?Component = null,
    state_json: ?std.json.Value = null,
    cwd: []const u8,
    execution_started: bool = false,
    args_complete: bool = false,
    is_partial: bool = false,
    expanded: bool = false,
    show_images: bool = false,
    is_error: bool = false,

    pub fn invalidate(self: ToolRenderContext) void {
        if (self.invalidate_fn) |invalidate_fn| invalidate_fn(self.invalidate_ptr);
    }
};

pub fn defineTool(tool: ToolDefinition) ToolDefinition {
    return tool;
}

pub const ResourcesDiscoverEvent = struct {
    type: ExtensionEventName = .resources_discover,
    cwd: []const u8,
    reason: ResourcesDiscoverReason,
};

pub const ResourcesDiscoverResult = struct {
    skill_paths: []const []const u8 = &.{},
    prompt_paths: []const []const u8 = &.{},
    theme_paths: []const []const u8 = &.{},
};

pub const SessionStartEvent = struct {
    type: ExtensionEventName = .session_start,
    reason: SessionStartReason,
    previous_session_file: ?[]const u8 = null,
};

pub const SessionBeforeSwitchEvent = struct {
    type: ExtensionEventName = .session_before_switch,
    reason: SessionReplacementReason,
    target_session_file: ?[]const u8 = null,
};

pub const SessionBeforeForkEvent = struct {
    type: ExtensionEventName = .session_before_fork,
    entry_id: []const u8,
    position: ForkPosition,
};

pub const SessionBeforeCompactEvent = struct {
    type: ExtensionEventName = .session_before_compact,
    preparation: CompactionPreparation,
    branch_entries: []const SessionEntry,
    custom_instructions: ?[]const u8 = null,
    signal: *const ai.AbortSignal,
};

pub const SessionCompactEvent = struct {
    type: ExtensionEventName = .session_compact,
    compaction_entry: CompactionEntry,
    from_extension: bool,
};

pub const SessionShutdownEvent = struct {
    type: ExtensionEventName = .session_shutdown,
    reason: SessionShutdownReason,
    target_session_file: ?[]const u8 = null,
};

pub const TreePreparation = struct {
    target_id: []const u8,
    old_leaf_id: ?[]const u8 = null,
    common_ancestor_id: ?[]const u8 = null,
    entries_to_summarize: []const SessionEntry = &.{},
    user_wants_summary: bool = false,
    custom_instructions: ?[]const u8 = null,
    replace_instructions: bool = false,
    label: ?[]const u8 = null,
};

pub const SessionBeforeTreeEvent = struct {
    type: ExtensionEventName = .session_before_tree,
    preparation: TreePreparation,
    signal: *const ai.AbortSignal,
};

pub const SessionTreeEvent = struct {
    type: ExtensionEventName = .session_tree,
    new_leaf_id: ?[]const u8 = null,
    old_leaf_id: ?[]const u8 = null,
    summary_entry: ?BranchSummaryEntry = null,
    from_extension: bool = false,
};

pub const SessionEvent = union(enum) {
    start: SessionStartEvent,
    before_switch: SessionBeforeSwitchEvent,
    before_fork: SessionBeforeForkEvent,
    before_compact: SessionBeforeCompactEvent,
    compact: SessionCompactEvent,
    shutdown: SessionShutdownEvent,
    before_tree: SessionBeforeTreeEvent,
    tree: SessionTreeEvent,
};

pub const ContextEvent = struct {
    type: ExtensionEventName = .context,
    messages: []AgentMessage,
};

pub const BeforeProviderRequestEvent = struct {
    type: ExtensionEventName = .before_provider_request,
    payload: std.json.Value,
};

pub const AfterProviderResponseEvent = struct {
    type: ExtensionEventName = .after_provider_response,
    status: u16,
    headers: []const ai.Header = &.{},
};

pub const BeforeAgentStartEvent = struct {
    type: ExtensionEventName = .before_agent_start,
    prompt: []const u8,
    images: []const ai.ImageContent = &.{},
    system_prompt: []const u8,
    system_prompt_options: BuildSystemPromptOptions,
};

pub const AgentStartEvent = struct {
    type: ExtensionEventName = .agent_start,
};

pub const AgentEndEvent = struct {
    type: ExtensionEventName = .agent_end,
    messages: []AgentMessage,
};

pub const TurnStartEvent = struct {
    type: ExtensionEventName = .turn_start,
    turn_index: usize,
    timestamp_ms: i64,
};

pub const TurnEndEvent = struct {
    type: ExtensionEventName = .turn_end,
    turn_index: usize,
    message: AgentMessage,
    tool_results: []ai.ToolResultMessage,
};

pub const MessageStartEvent = struct {
    type: ExtensionEventName = .message_start,
    message: AgentMessage,
};

pub const MessageUpdateEvent = struct {
    type: ExtensionEventName = .message_update,
    message: AgentMessage,
    assistant_message_event: ai.StreamEvent,
};

pub const MessageEndEvent = struct {
    type: ExtensionEventName = .message_end,
    message: AgentMessage,
};

pub const ToolExecutionStartEvent = struct {
    type: ExtensionEventName = .tool_execution_start,
    tool_call_id: []const u8,
    tool_name: []const u8,
    args: std.json.Value,
};

pub const ToolExecutionUpdateEvent = struct {
    type: ExtensionEventName = .tool_execution_update,
    tool_call_id: []const u8,
    tool_name: []const u8,
    args: std.json.Value,
    partial_result: std.json.Value,
};

pub const ToolExecutionEndEvent = struct {
    type: ExtensionEventName = .tool_execution_end,
    tool_call_id: []const u8,
    tool_name: []const u8,
    result: std.json.Value,
    is_error: bool,
};

pub const ModelSelectEvent = struct {
    type: ExtensionEventName = .model_select,
    model: ai.Model,
    previous_model: ?ai.Model = null,
    source: ModelSelectSource,
};

pub const ThinkingLevelSelectEvent = struct {
    type: ExtensionEventName = .thinking_level_select,
    level: ai.ThinkingLevel,
    previous_level: ai.ThinkingLevel,
};

pub const UserBashEvent = struct {
    type: ExtensionEventName = .user_bash,
    command: []const u8,
    exclude_from_context: bool = false,
    cwd: []const u8,
};

pub const InputEvent = struct {
    type: ExtensionEventName = .input,
    text: []const u8,
    images: []const ai.ImageContent = &.{},
    source: InputSource,
    streaming_behavior: ?StreamingBehavior = null,
};

pub const InputEventResult = union(enum) {
    @"continue": void,
    transform: TransformInput,
    handled: void,
};

pub const TransformInput = struct {
    text: []const u8,
    images: []const ai.ImageContent = &.{},
};

pub const ToolCallEventBase = struct {
    type: ExtensionEventName = .tool_call,
    tool_call_id: []const u8,
};

pub const BashToolCallEvent = struct {
    base: ToolCallEventBase,
    tool_name: tools.tool_registry.ToolName = .bash,
    input: tools.bash.BashToolInput,
};

pub const ReadToolCallEvent = struct {
    base: ToolCallEventBase,
    tool_name: tools.tool_registry.ToolName = .read,
    input: tools.read.ReadToolInput,
};

pub const EditToolCallEvent = struct {
    base: ToolCallEventBase,
    tool_name: tools.tool_registry.ToolName = .edit,
    input: tools.edit.EditToolInput,
};

pub const WriteToolCallEvent = struct {
    base: ToolCallEventBase,
    tool_name: tools.tool_registry.ToolName = .write,
    input: tools.write.WriteToolInput,
};

pub const GrepToolCallEvent = struct {
    base: ToolCallEventBase,
    tool_name: tools.tool_registry.ToolName = .grep,
    input: tools.grep.GrepToolInput,
};

pub const FindToolCallEvent = struct {
    base: ToolCallEventBase,
    tool_name: tools.tool_registry.ToolName = .find,
    input: tools.find.FindToolInput,
};

pub const LsToolCallEvent = struct {
    base: ToolCallEventBase,
    tool_name: tools.tool_registry.ToolName = .ls,
    input: tools.ls.LsToolInput,
};

pub const CustomToolCallEvent = struct {
    base: ToolCallEventBase,
    tool_name: []const u8,
    input: std.json.Value,
};

pub const ToolCallEvent = union(enum) {
    bash: BashToolCallEvent,
    read: ReadToolCallEvent,
    edit: EditToolCallEvent,
    write: WriteToolCallEvent,
    grep: GrepToolCallEvent,
    find: FindToolCallEvent,
    ls: LsToolCallEvent,
    custom: CustomToolCallEvent,

    pub fn toolName(self: ToolCallEvent) []const u8 {
        return switch (self) {
            .bash => |event| event.tool_name.text(),
            .read => |event| event.tool_name.text(),
            .edit => |event| event.tool_name.text(),
            .write => |event| event.tool_name.text(),
            .grep => |event| event.tool_name.text(),
            .find => |event| event.tool_name.text(),
            .ls => |event| event.tool_name.text(),
            .custom => |event| event.tool_name,
        };
    }

    pub fn toolCallId(self: ToolCallEvent) []const u8 {
        return switch (self) {
            inline else => |event| event.base.tool_call_id,
        };
    }
};

pub const ToolResultEventBase = struct {
    type: ExtensionEventName = .tool_result,
    tool_call_id: []const u8,
    input: std.json.Value,
    content: []const ai.UserContent,
    is_error: bool = false,
};

pub const BashToolResultEvent = struct {
    base: ToolResultEventBase,
    tool_name: tools.tool_registry.ToolName = .bash,
    details: ?tools.bash.BashToolDetails = null,
};

pub const ReadToolResultEvent = struct {
    base: ToolResultEventBase,
    tool_name: tools.tool_registry.ToolName = .read,
    details: ?tools.read.ReadToolDetails = null,
};

pub const EditToolResultEvent = struct {
    base: ToolResultEventBase,
    tool_name: tools.tool_registry.ToolName = .edit,
    details: ?tools.edit.EditToolDetails = null,
};

pub const WriteToolResultEvent = struct {
    base: ToolResultEventBase,
    tool_name: tools.tool_registry.ToolName = .write,
};

pub const GrepToolResultEvent = struct {
    base: ToolResultEventBase,
    tool_name: tools.tool_registry.ToolName = .grep,
    details: ?tools.grep.GrepToolDetails = null,
};

pub const FindToolResultEvent = struct {
    base: ToolResultEventBase,
    tool_name: tools.tool_registry.ToolName = .find,
    details: ?tools.find.FindToolDetails = null,
};

pub const LsToolResultEvent = struct {
    base: ToolResultEventBase,
    tool_name: tools.tool_registry.ToolName = .ls,
    details: ?tools.ls.LsToolDetails = null,
};

pub const CustomToolResultEvent = struct {
    base: ToolResultEventBase,
    tool_name: []const u8,
    details: ?std.json.Value = null,
};

pub const ToolResultEvent = union(enum) {
    bash: BashToolResultEvent,
    read: ReadToolResultEvent,
    edit: EditToolResultEvent,
    write: WriteToolResultEvent,
    grep: GrepToolResultEvent,
    find: FindToolResultEvent,
    ls: LsToolResultEvent,
    custom: CustomToolResultEvent,

    pub fn toolName(self: ToolResultEvent) []const u8 {
        return switch (self) {
            .bash => |event| event.tool_name.text(),
            .read => |event| event.tool_name.text(),
            .edit => |event| event.tool_name.text(),
            .write => |event| event.tool_name.text(),
            .grep => |event| event.tool_name.text(),
            .find => |event| event.tool_name.text(),
            .ls => |event| event.tool_name.text(),
            .custom => |event| event.tool_name,
        };
    }
};

pub fn isBashToolResult(event: ToolResultEvent) bool {
    return event == .bash;
}

pub fn isReadToolResult(event: ToolResultEvent) bool {
    return event == .read;
}

pub fn isEditToolResult(event: ToolResultEvent) bool {
    return event == .edit;
}

pub fn isWriteToolResult(event: ToolResultEvent) bool {
    return event == .write;
}

pub fn isGrepToolResult(event: ToolResultEvent) bool {
    return event == .grep;
}

pub fn isFindToolResult(event: ToolResultEvent) bool {
    return event == .find;
}

pub fn isLsToolResult(event: ToolResultEvent) bool {
    return event == .ls;
}

pub fn isToolCallEventType(tool_name: []const u8, event: ToolCallEvent) bool {
    return std.mem.eql(u8, tool_name, event.toolName());
}

pub const ExtensionEvent = union(enum) {
    resources_discover: ResourcesDiscoverEvent,
    session: SessionEvent,
    context: ContextEvent,
    before_provider_request: BeforeProviderRequestEvent,
    after_provider_response: AfterProviderResponseEvent,
    before_agent_start: BeforeAgentStartEvent,
    agent_start: AgentStartEvent,
    agent_end: AgentEndEvent,
    turn_start: TurnStartEvent,
    turn_end: TurnEndEvent,
    message_start: MessageStartEvent,
    message_update: MessageUpdateEvent,
    message_end: MessageEndEvent,
    tool_execution_start: ToolExecutionStartEvent,
    tool_execution_update: ToolExecutionUpdateEvent,
    tool_execution_end: ToolExecutionEndEvent,
    model_select: ModelSelectEvent,
    thinking_level_select: ThinkingLevelSelectEvent,
    user_bash: UserBashEvent,
    input: InputEvent,
    tool_call: ToolCallEvent,
    tool_result: ToolResultEvent,

    pub fn name(self: ExtensionEvent) ExtensionEventName {
        return switch (self) {
            .resources_discover => .resources_discover,
            .session => |event| switch (event) {
                .start => .session_start,
                .before_switch => .session_before_switch,
                .before_fork => .session_before_fork,
                .before_compact => .session_before_compact,
                .compact => .session_compact,
                .shutdown => .session_shutdown,
                .before_tree => .session_before_tree,
                .tree => .session_tree,
            },
            .context => .context,
            .before_provider_request => .before_provider_request,
            .after_provider_response => .after_provider_response,
            .before_agent_start => .before_agent_start,
            .agent_start => .agent_start,
            .agent_end => .agent_end,
            .turn_start => .turn_start,
            .turn_end => .turn_end,
            .message_start => .message_start,
            .message_update => .message_update,
            .message_end => .message_end,
            .tool_execution_start => .tool_execution_start,
            .tool_execution_update => .tool_execution_update,
            .tool_execution_end => .tool_execution_end,
            .model_select => .model_select,
            .thinking_level_select => .thinking_level_select,
            .user_bash => .user_bash,
            .input => .input,
            .tool_call => .tool_call,
            .tool_result => .tool_result,
        };
    }
};

pub const ContextEventResult = struct {
    messages: ?[]AgentMessage = null,
};

pub const BeforeProviderRequestEventResult = std.json.Value;

pub const ToolCallEventResult = struct {
    block: bool = false,
    reason: ?[]const u8 = null,
};

pub const UserBashEventResult = struct {
    operations: ?tools.bash.BashOperations = null,
    result: ?bash_executor.BashResult = null,
};

pub const ToolResultEventResult = struct {
    content: ?[]const ai.UserContent = null,
    details: ?std.json.Value = null,
    is_error: ?bool = null,
};

pub const MessageEndEventResult = struct {
    message: ?AgentMessage = null,
};

pub const BeforeAgentStartEventResult = struct {
    message: ?messages.CustomMessage = null,
    system_prompt: ?[]const u8 = null,
};

pub const SessionBeforeSwitchResult = struct {
    cancel: bool = false,
};

pub const SessionBeforeForkResult = struct {
    cancel: bool = false,
    skip_conversation_restore: bool = false,
};

pub const SessionBeforeCompactResult = struct {
    cancel: bool = false,
    compaction: ?CompactionResult = null,
};

pub const SessionBeforeTreeResult = struct {
    cancel: bool = false,
    summary: ?SessionBeforeTreeSummary = null,
    custom_instructions: ?[]const u8 = null,
    replace_instructions: ?bool = null,
    label: ?[]const u8 = null,
};

pub const SessionBeforeTreeSummary = struct {
    summary: []const u8,
    details: ?std.json.Value = null,
};

pub const MessageRenderOptions = struct {
    expanded: bool,
};

pub const MessageRenderer = struct {
    ptr: ?*anyopaque = null,
    render_fn: *const fn (?*anyopaque, messages.CustomMessage, MessageRenderOptions, Theme) anyerror!?Component,

    pub fn render(
        self: MessageRenderer,
        message: messages.CustomMessage,
        options: MessageRenderOptions,
        active_theme: Theme,
    ) !?Component {
        return self.render_fn(self.ptr, message, options, active_theme);
    }
};

pub const ArgumentCompletions = struct {
    ptr: ?*anyopaque = null,
    complete_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]AutocompleteItem,

    pub fn complete(self: ArgumentCompletions, allocator: std.mem.Allocator, argument_prefix: []const u8) !?[]AutocompleteItem {
        return self.complete_fn(self.ptr, allocator, argument_prefix);
    }
};

pub const CommandHandler = struct {
    ptr: ?*anyopaque = null,
    handler_fn: *const fn (?*anyopaque, []const u8, *ExtensionCommandContext) anyerror!void,

    pub fn call(self: CommandHandler, args: []const u8, ctx: *ExtensionCommandContext) !void {
        return self.handler_fn(self.ptr, args, ctx);
    }
};

pub const RegisteredCommand = struct {
    name: []const u8,
    source_info: SourceInfo,
    description: ?[]const u8 = null,
    get_argument_completions: ?ArgumentCompletions = null,
    handler: CommandHandler,
};

pub const ResolvedCommand = struct {
    command: RegisteredCommand,
    invocation_name: []const u8,
};

pub const SlashCommandInfo = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    source: SlashCommandSource,
    source_info: SourceInfo,
};

pub const ExtensionHandler = struct {
    ptr: ?*anyopaque = null,
    event_name: ExtensionEventName,
    handler_fn: *const fn (?*anyopaque, ExtensionEvent, *ExtensionContext) anyerror!?std.json.Value,

    pub fn call(self: ExtensionHandler, event: ExtensionEvent, ctx: *ExtensionContext) !?std.json.Value {
        return self.handler_fn(self.ptr, event, ctx);
    }
};

pub const RegisterCommandOptions = struct {
    description: ?[]const u8 = null,
    get_argument_completions: ?ArgumentCompletions = null,
    handler: CommandHandler,
};

pub const RegisterShortcutOptions = struct {
    description: ?[]const u8 = null,
    handler: ShortcutHandler,
};

pub const ShortcutHandler = struct {
    ptr: ?*anyopaque = null,
    handler_fn: *const fn (?*anyopaque, *ExtensionContext) anyerror!void,

    pub fn call(self: ShortcutHandler, ctx: *ExtensionContext) !void {
        return self.handler_fn(self.ptr, ctx);
    }
};

pub const ExtensionFlagType = enum {
    boolean,
    string,
};

pub const RegisterFlagOptions = struct {
    description: ?[]const u8 = null,
    type: ExtensionFlagType,
    default: ?FlagValue = null,
};

pub const ExtensionAPI = struct {
    ptr: ?*anyopaque = null,
    on_fn: ?*const fn (?*anyopaque, ExtensionEventName, ExtensionHandler) anyerror!void = null,
    register_tool_fn: ?*const fn (?*anyopaque, ToolDefinition) anyerror!void = null,
    register_command_fn: ?*const fn (?*anyopaque, []const u8, RegisterCommandOptions) anyerror!void = null,
    register_shortcut_fn: ?*const fn (?*anyopaque, KeyId, RegisterShortcutOptions) anyerror!void = null,
    register_flag_fn: ?*const fn (?*anyopaque, []const u8, RegisterFlagOptions) anyerror!void = null,
    get_flag_fn: ?*const fn (?*anyopaque, []const u8) ?FlagValue = null,
    register_message_renderer_fn: ?*const fn (?*anyopaque, []const u8, MessageRenderer) anyerror!void = null,
    send_message_fn: ?SendMessageHandler = null,
    send_user_message_fn: ?SendUserMessageHandler = null,
    append_entry_fn: ?AppendEntryHandler = null,
    set_session_name_fn: ?SetSessionNameHandler = null,
    get_session_name_fn: ?GetSessionNameHandler = null,
    set_label_fn: ?SetLabelHandler = null,
    exec_fn: ?ExecHandler = null,
    get_active_tools_fn: ?GetActiveToolsHandler = null,
    get_all_tools_fn: ?GetAllToolsHandler = null,
    set_active_tools_fn: ?SetActiveToolsHandler = null,
    get_commands_fn: ?GetCommandsHandler = null,
    set_model_fn: ?SetModelHandler = null,
    get_thinking_level_fn: ?GetThinkingLevelHandler = null,
    set_thinking_level_fn: ?SetThinkingLevelHandler = null,
    register_provider_fn: ?RegisterProviderHandler = null,
    unregister_provider_fn: ?UnregisterProviderHandler = null,
    events: ?*EventBus = null,
};

pub const ProviderConfig = struct {
    name: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    api: ?ai.Api = null,
    stream_simple: ?ai.api_registry.SimpleStream = null,
    headers: []const ai.Header = &.{},
    auth_header: ?bool = null,
    models: []const ProviderModelConfig = &.{},
    oauth: ?ai.oauth.OAuthProviderInterface = null,
};

pub const ProviderModelConfig = struct {
    id: []const u8,
    name: []const u8,
    api: ?ai.Api = null,
    base_url: ?[]const u8 = null,
    reasoning: bool,
    thinking_level_map: ?ai.ThinkingLevelMap = null,
    input: []const []const u8,
    cost: ai.ModelCost,
    context_window: u64,
    max_tokens: u64,
    headers: []const ai.Header = &.{},
    compat: ?ai.ModelCompat = null,
};

pub const ExtensionFactory = struct {
    ptr: ?*anyopaque = null,
    init_fn: *const fn (?*anyopaque, *const ExtensionAPI) anyerror!void,

    pub fn init(self: ExtensionFactory, api: *const ExtensionAPI) !void {
        return self.init_fn(self.ptr, api);
    }
};

pub const RegisteredTool = struct {
    definition: ToolDefinition,
    source_info: SourceInfo,
};

pub const ExtensionFlag = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    type: ExtensionFlagType,
    default: ?FlagValue = null,
    extension_path: []const u8,
};

pub const ExtensionShortcut = struct {
    shortcut: KeyId,
    description: ?[]const u8 = null,
    handler: ShortcutHandler,
    extension_path: []const u8,
};

pub const SendMessageOptions = struct {
    trigger_turn: bool = false,
    deliver_as: ?DeliverAs = null,
};

pub const SendUserMessageOptions = struct {
    deliver_as: ?DeliverAs = null,
};

pub const DeliverAs = enum {
    steer,
    follow_up,
    next_turn,

    pub fn text(self: DeliverAs) []const u8 {
        return switch (self) {
            .steer => "steer",
            .follow_up => "followUp",
            .next_turn => "nextTurn",
        };
    }
};

pub const SendMessageHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, messages.CustomMessage, ?SendMessageOptions) anyerror!void,

    pub fn call(self: SendMessageHandler, message: messages.CustomMessage, options: ?SendMessageOptions) !void {
        return self.call_fn(self.ptr, message, options);
    }
};

pub const SendUserMessageContent = union(enum) {
    text: []const u8,
    parts: []const ai.UserContent,
};

pub const SendUserMessageHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, SendUserMessageContent, ?SendUserMessageOptions) anyerror!void,

    pub fn call(self: SendUserMessageHandler, content: SendUserMessageContent, options: ?SendUserMessageOptions) !void {
        return self.call_fn(self.ptr, content, options);
    }
};

pub const AppendEntryHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const u8, ?std.json.Value) anyerror!void,

    pub fn call(self: AppendEntryHandler, custom_type: []const u8, data: ?std.json.Value) !void {
        return self.call_fn(self.ptr, custom_type, data);
    }
};

pub const SetSessionNameHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const u8) anyerror!void,

    pub fn call(self: SetSessionNameHandler, name: []const u8) !void {
        return self.call_fn(self.ptr, name);
    }
};

pub const GetSessionNameHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque) ?[]const u8,

    pub fn call(self: GetSessionNameHandler) ?[]const u8 {
        return self.call_fn(self.ptr);
    }
};

pub const SetLabelHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const u8, ?[]const u8) anyerror!void,

    pub fn call(self: SetLabelHandler, entry_id: []const u8, label: ?[]const u8) !void {
        return self.call_fn(self.ptr, entry_id, label);
    }
};

pub const ExecOptions = struct {
    cwd: ?[]const u8 = null,
    env: []const ai.Header = &.{},
    timeout_ms: ?u64 = null,
    signal: ?*const ai.AbortSignal = null,
};

pub const ExecResult = struct {
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    exit_code: ?i32 = null,
    signal: ?[]const u8 = null,
};

pub const ExecHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8, []const []const u8, ?ExecOptions) anyerror!ExecResult,

    pub fn call(
        self: ExecHandler,
        allocator: std.mem.Allocator,
        command: []const u8,
        args: []const []const u8,
        options: ?ExecOptions,
    ) !ExecResult {
        return self.call_fn(self.ptr, allocator, command, args, options);
    }
};

pub const GetActiveToolsHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, std.mem.Allocator) anyerror![]const []const u8,

    pub fn call(self: GetActiveToolsHandler, allocator: std.mem.Allocator) ![]const []const u8 {
        return self.call_fn(self.ptr, allocator);
    }
};

pub const ToolInfo = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
    prompt_guidelines: []const []const u8 = &.{},
    source_info: SourceInfo,

    pub fn fromDefinition(definition: ToolDefinition, info: SourceInfo) ToolInfo {
        return .{
            .name = definition.name,
            .description = definition.description,
            .parameters_json = definition.parameters_json,
            .prompt_guidelines = definition.prompt_guidelines,
            .source_info = info,
        };
    }
};

pub const GetAllToolsHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, std.mem.Allocator) anyerror![]ToolInfo,

    pub fn call(self: GetAllToolsHandler, allocator: std.mem.Allocator) ![]ToolInfo {
        return self.call_fn(self.ptr, allocator);
    }
};

pub const GetCommandsHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, std.mem.Allocator) anyerror![]SlashCommandInfo,

    pub fn call(self: GetCommandsHandler, allocator: std.mem.Allocator) ![]SlashCommandInfo {
        return self.call_fn(self.ptr, allocator);
    }
};

pub const SetActiveToolsHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const []const u8) anyerror!void,

    pub fn call(self: SetActiveToolsHandler, tool_names: []const []const u8) !void {
        return self.call_fn(self.ptr, tool_names);
    }
};

pub const RefreshToolsHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque) anyerror!void,

    pub fn call(self: RefreshToolsHandler) !void {
        return self.call_fn(self.ptr);
    }
};

pub const SetModelHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, ai.Model) anyerror!bool,

    pub fn call(self: SetModelHandler, model: ai.Model) !bool {
        return self.call_fn(self.ptr, model);
    }
};

pub const GetThinkingLevelHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque) ai.ThinkingLevel,

    pub fn call(self: GetThinkingLevelHandler) ai.ThinkingLevel {
        return self.call_fn(self.ptr);
    }
};

pub const SetThinkingLevelHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, ai.ThinkingLevel) anyerror!void,

    pub fn call(self: SetThinkingLevelHandler, level: ai.ThinkingLevel) !void {
        return self.call_fn(self.ptr, level);
    }
};

pub const RegisterProviderHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const u8, ProviderConfig) anyerror!void,

    pub fn call(self: RegisterProviderHandler, name: []const u8, provider_config: ProviderConfig) !void {
        return self.call_fn(self.ptr, name, provider_config);
    }
};

pub const UnregisterProviderHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const u8) anyerror!void,

    pub fn call(self: UnregisterProviderHandler, name: []const u8) !void {
        return self.call_fn(self.ptr, name);
    }
};

pub const PendingProviderRegistration = struct {
    name: []const u8,
    config: ProviderConfig,
    extension_path: []const u8,
};

pub const ExtensionRuntimeState = struct {
    flag_values: []const FlagEntry = &.{},
    pending_provider_registrations: []const PendingProviderRegistration = &.{},
    ptr: ?*anyopaque = null,
    assert_active_fn: ?*const fn (?*anyopaque) anyerror!void = null,
    invalidate_fn: ?*const fn (?*anyopaque, ?[]const u8) void = null,
    register_provider: ?RegisterProviderHandler = null,
    unregister_provider: ?UnregisterProviderHandler = null,

    pub fn assertActive(self: ExtensionRuntimeState) !void {
        if (self.assert_active_fn) |assert_fn| return assert_fn(self.ptr);
    }

    pub fn invalidate(self: ExtensionRuntimeState, message: ?[]const u8) void {
        if (self.invalidate_fn) |invalidate_fn| invalidate_fn(self.ptr, message);
    }
};

pub const ExtensionActions = struct {
    send_message: ?SendMessageHandler = null,
    send_user_message: ?SendUserMessageHandler = null,
    append_entry: ?AppendEntryHandler = null,
    set_session_name: ?SetSessionNameHandler = null,
    get_session_name: ?GetSessionNameHandler = null,
    set_label: ?SetLabelHandler = null,
    get_active_tools: ?GetActiveToolsHandler = null,
    get_all_tools: ?GetAllToolsHandler = null,
    set_active_tools: ?SetActiveToolsHandler = null,
    refresh_tools: ?RefreshToolsHandler = null,
    get_commands: ?GetCommandsHandler = null,
    set_model: ?SetModelHandler = null,
    get_thinking_level: ?GetThinkingLevelHandler = null,
    set_thinking_level: ?SetThinkingLevelHandler = null,
};

pub const ExtensionRuntime = struct {
    state: ExtensionRuntimeState = .{},
    actions: ExtensionActions = .{},
};

pub const FlagEntry = struct {
    name: []const u8,
    value: FlagValue,
};

pub const EventBusSubscriber = struct {
    ptr: ?*anyopaque = null,
    handler_fn: *const fn (?*anyopaque, []const u8, std.json.Value) anyerror!void,
};

pub const EventBus = struct {
    ptr: ?*anyopaque = null,
    emit_fn: ?*const fn (?*anyopaque, []const u8, std.json.Value) anyerror!void = null,
    on_fn: ?*const fn (?*anyopaque, []const u8, EventBusSubscriber) anyerror!Unsubscribe = null,
};

pub const Extension = struct {
    path: []const u8,
    resolved_path: []const u8,
    source_info: SourceInfo,
    handlers: []const ExtensionHandler = &.{},
    tools: []const RegisteredTool = &.{},
    message_renderers: []const MessageRendererRegistration = &.{},
    commands: []const RegisteredCommand = &.{},
    flags: []const ExtensionFlag = &.{},
    shortcuts: []const ExtensionShortcut = &.{},
};

pub const MessageRendererRegistration = struct {
    custom_type: []const u8,
    renderer: MessageRenderer,
};

pub const LoadExtensionsResult = struct {
    extensions: []const Extension = &.{},
    errors: []const LoadExtensionError = &.{},
    runtime: ExtensionRuntime = .{},
};

pub const LoadExtensionError = struct {
    path: []const u8,
    @"error": []const u8,
};

pub const ExtensionError = struct {
    extension_path: []const u8,
    event: []const u8,
    @"error": []const u8,
    stack: ?[]const u8 = null,
};

test "extension event names preserve Pi JSON strings" {
    try std.testing.expectEqualStrings("resources_discover", ExtensionEventName.resources_discover.text());
    try std.testing.expectEqualStrings("before_provider_request", ExtensionEventName.before_provider_request.text());
    try std.testing.expectEqualStrings("tool_result", ExtensionEventName.tool_result.text());
    try std.testing.expectEqual(ExtensionEventName.session_before_tree, ExtensionEventName.parse("session_before_tree").?);
    try std.testing.expectEqual(@as(?ExtensionEventName, null), ExtensionEventName.parse("unknown_event"));
    try std.testing.expectEqual(@as(usize, 29), all_event_names.len);
}

test "extension string enums keep Pi casing" {
    try std.testing.expectEqualStrings("aboveEditor", WidgetPlacement.above_editor.text());
    try std.testing.expectEqual(WidgetPlacement.below_editor, WidgetPlacement.parse("belowEditor").?);
    try std.testing.expectEqual(ExtensionMode.rpc, ExtensionMode.parse("rpc").?);
    try std.testing.expectEqual(InputSource.interactive, InputSource.parse("interactive").?);
    try std.testing.expectEqualStrings("followUp", StreamingBehavior.follow_up.text());
    try std.testing.expectEqualStrings("nextTurn", DeliverAs.next_turn.text());
}

test "tool event guards identify built-ins and custom names" {
    const input = std.json.Value{ .object = .empty };
    const call_event = ToolCallEvent{ .bash = .{
        .base = .{ .tool_call_id = "call-1" },
        .input = .{ .command = "pwd" },
    } };
    try std.testing.expect(isToolCallEventType("bash", call_event));
    try std.testing.expect(!isToolCallEventType("read", call_event));
    try std.testing.expectEqualStrings("call-1", call_event.toolCallId());

    const custom_event = ToolCallEvent{ .custom = .{
        .base = .{ .tool_call_id = "call-2" },
        .tool_name = "deploy",
        .input = input,
    } };
    try std.testing.expect(isToolCallEventType("deploy", custom_event));

    const result_event = ToolResultEvent{ .grep = .{
        .base = .{
            .tool_call_id = "call-3",
            .input = input,
            .content = &.{},
        },
    } };
    try std.testing.expect(isGrepToolResult(result_event));
    try std.testing.expect(!isReadToolResult(result_event));
    try std.testing.expectEqualStrings("grep", result_event.toolName());
}

test "provider config mirrors extension registration shape" {
    const model = ProviderModelConfig{
        .id = "model-a",
        .name = "Model A",
        .api = ai.types.api.openai_responses,
        .reasoning = true,
        .input = &.{ "text", "image" },
        .cost = .{ .input = 1, .output = 2, .cache_read = 0.5, .cache_write = 0.25 },
        .context_window = 128_000,
        .max_tokens = 16_384,
        .compat = .{ .supports_store = false },
    };
    const provider = ProviderConfig{
        .name = "Custom",
        .base_url = "https://proxy.example.test",
        .api_key = "$CUSTOM_KEY",
        .api = ai.types.api.openai_responses,
        .headers = &.{.{ .name = "x-test", .value = "1" }},
        .auth_header = true,
        .models = &.{model},
    };

    try std.testing.expectEqualStrings("Custom", provider.name.?);
    try std.testing.expectEqualStrings("model-a", provider.models[0].id);
    try std.testing.expect(provider.auth_header.?);
    try std.testing.expectEqualStrings("x-test", provider.headers[0].name);
}

test "tool info can be derived from registered tool definitions" {
    const definition = tools.tool_registry.createToolDefinition(.read, "/tmp", .{});
    const info = ToolInfo.fromDefinition(definition, source_info.createSyntheticSourceInfo("<builtin:read>", .{ .source = "builtin" }));

    try std.testing.expectEqualStrings("read", info.name);
    try std.testing.expect(std.mem.indexOf(u8, info.description, "Read") != null);
    try std.testing.expect(std.mem.indexOf(u8, info.parameters_json, "\"path\"") != null);
    try std.testing.expectEqualStrings("builtin", info.source_info.source);
}
