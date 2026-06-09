const std = @import("std");
const agent_session_runtime = @import("agent_session_runtime.zig");
const config = @import("config.zig");
const extension_types = @import("extensions/types.zig");
const git = @import("git.zig");
const messages_mod = @import("messages.zig");
const paths = @import("paths.zig");
const resource_loader = @import("resource_loader.zig");
const session_events = @import("session_events.zig");
const session_manager_mod = @import("session_manager.zig");
const source_info = @import("source_info.zig");
const theme_mod = @import("theme.zig");
const render_utils = @import("tools/render_utils.zig");
const tui = @import("bulb_tui");

pub const anthropic_subscription_auth_warning =
    "Anthropic subscription auth is active. Third-party harness usage draws from extra usage and is billed per token, not your Claude plan limits. Manage extra usage at https://claude.ai/settings/usage.";

pub const AnthropicWarningModel = struct {
    provider: []const u8,
};

pub const AnthropicWarningSettings = struct {
    anthropic_extra_usage: ?bool = null,

    fn isAnthropicExtraUsageEnabled(self: AnthropicWarningSettings) bool {
        return self.anthropic_extra_usage orelse true;
    }
};

pub const AnthropicWarningAuthType = enum {
    api_key,
    oauth,
};

pub const AnthropicWarningModelRegistry = struct {
    ptr: ?*anyopaque = null,
    get_stored_auth_type_fn: *const fn (?*anyopaque, []const u8) ?AnthropicWarningAuthType,
    get_api_key_for_provider_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]u8,

    fn getStoredAuthType(self: AnthropicWarningModelRegistry, provider: []const u8) ?AnthropicWarningAuthType {
        return self.get_stored_auth_type_fn(self.ptr, provider);
    }

    fn getApiKeyForProviderAlloc(
        self: AnthropicWarningModelRegistry,
        allocator: std.mem.Allocator,
        provider: []const u8,
    ) !?[]u8 {
        return self.get_api_key_for_provider_fn(self.ptr, allocator, provider);
    }
};

pub const AnthropicWarningUi = struct {
    ptr: ?*anyopaque = null,
    show_warning_fn: *const fn (?*anyopaque, []const u8) anyerror!void,

    fn showWarning(self: AnthropicWarningUi, message: []const u8) !void {
        try self.show_warning_fn(self.ptr, message);
    }
};

pub const AnthropicSubscriptionWarningState = struct {
    shown: bool = false,
};

pub const AnthropicWarningContext = struct {
    state: *AnthropicSubscriptionWarningState,
    settings: AnthropicWarningSettings = .{},
    model_registry: AnthropicWarningModelRegistry,
    ui: AnthropicWarningUi,
};

pub fn isAnthropicSubscriptionAuthKey(api_key: ?[]const u8) bool {
    const key = api_key orelse return false;
    return std.mem.startsWith(u8, key, "sk-ant-oat");
}

pub fn maybeWarnAboutAnthropicSubscriptionAuth(
    allocator: std.mem.Allocator,
    context: AnthropicWarningContext,
    model: ?AnthropicWarningModel,
) !void {
    if (!context.settings.isAnthropicExtraUsageEnabled()) return;
    if (context.state.shown) return;

    const selected_model = model orelse return;
    if (!std.mem.eql(u8, selected_model.provider, "anthropic")) return;

    if (context.model_registry.getStoredAuthType("anthropic")) |credential_type| {
        if (credential_type == .oauth) {
            context.state.shown = true;
            try context.ui.showWarning(anthropic_subscription_auth_warning);
            return;
        }
    }

    const api_key = context.model_registry.getApiKeyForProviderAlloc(allocator, selected_model.provider) catch return;
    defer if (api_key) |value| allocator.free(value);
    if (!isAnthropicSubscriptionAuthKey(api_key)) return;

    context.state.shown = true;
    try context.ui.showWarning(anthropic_subscription_auth_warning);
}

pub const SuspendPlatform = enum {
    windows,
    posix,
};

pub const SuspendSignal = enum {
    sigint,
    sigcont,
    sigtstp,
};

pub const SuspendTimerHandle = struct {
    id: usize,
};

pub const SuspendTimerCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque) anyerror!void,

    fn call(self: SuspendTimerCallback) !void {
        try self.call_fn(self.ptr);
    }
};

pub const SuspendSignalCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque) anyerror!void,

    fn call(self: SuspendSignalCallback) !void {
        try self.call_fn(self.ptr);
    }
};

pub const SuspendUi = struct {
    ptr: ?*anyopaque = null,
    start_fn: *const fn (?*anyopaque) anyerror!void,
    stop_fn: *const fn (?*anyopaque) anyerror!void,
    request_render_fn: *const fn (?*anyopaque, bool) anyerror!void,
    show_status_fn: *const fn (?*anyopaque, []const u8) anyerror!void,

    fn start(self: SuspendUi) !void {
        try self.start_fn(self.ptr);
    }

    fn stop(self: SuspendUi) !void {
        try self.stop_fn(self.ptr);
    }

    fn requestRender(self: SuspendUi, force: bool) !void {
        try self.request_render_fn(self.ptr, force);
    }

    fn showStatus(self: SuspendUi, message: []const u8) !void {
        try self.show_status_fn(self.ptr, message);
    }
};

pub const SuspendProcess = struct {
    ptr: ?*anyopaque = null,
    platform_fn: *const fn (?*anyopaque) SuspendPlatform,
    set_interval_fn: *const fn (?*anyopaque, SuspendTimerCallback, u64) anyerror!SuspendTimerHandle,
    clear_interval_fn: *const fn (?*anyopaque, SuspendTimerHandle) anyerror!void,
    on_signal_fn: *const fn (?*anyopaque, SuspendSignal, SuspendSignalCallback) anyerror!void,
    once_signal_fn: *const fn (?*anyopaque, SuspendSignal, SuspendSignalCallback) anyerror!void,
    remove_listener_fn: *const fn (?*anyopaque, SuspendSignal, SuspendSignalCallback) anyerror!void,
    kill_process_group_fn: *const fn (?*anyopaque, SuspendSignal) anyerror!void,

    fn platform(self: SuspendProcess) SuspendPlatform {
        return self.platform_fn(self.ptr);
    }

    fn setInterval(self: SuspendProcess, callback: SuspendTimerCallback, interval_ms: u64) !SuspendTimerHandle {
        return self.set_interval_fn(self.ptr, callback, interval_ms);
    }

    fn clearInterval(self: SuspendProcess, handle: SuspendTimerHandle) !void {
        try self.clear_interval_fn(self.ptr, handle);
    }

    fn onSignal(self: SuspendProcess, signal: SuspendSignal, callback: SuspendSignalCallback) !void {
        try self.on_signal_fn(self.ptr, signal, callback);
    }

    fn onceSignal(self: SuspendProcess, signal: SuspendSignal, callback: SuspendSignalCallback) !void {
        try self.once_signal_fn(self.ptr, signal, callback);
    }

    fn removeListener(self: SuspendProcess, signal: SuspendSignal, callback: SuspendSignalCallback) !void {
        try self.remove_listener_fn(self.ptr, signal, callback);
    }

    fn killProcessGroup(self: SuspendProcess, signal: SuspendSignal) !void {
        try self.kill_process_group_fn(self.ptr, signal);
    }
};

pub const SuspendContext = struct {
    ui: SuspendUi,
    process: SuspendProcess,
};

const suspend_keep_alive_interval_ms: u64 = 1 << 30;

const SuspendResumeState = struct {
    allocator: std.mem.Allocator,
    ui: SuspendUi,
    process: SuspendProcess,
    keep_alive: SuspendTimerHandle,
    sigint_callback: SuspendSignalCallback,

    fn cleanup(self: *SuspendResumeState) !void {
        try self.process.clearInterval(self.keep_alive);
        try self.process.removeListener(.sigint, self.sigint_callback);
    }
};

pub fn handleCtrlZ(allocator: std.mem.Allocator, context: SuspendContext) !void {
    if (context.process.platform() == .windows) {
        try context.ui.showStatus("Suspend to background is not supported on Windows");
        return;
    }

    const keep_alive = try context.process.setInterval(.{ .call_fn = suspendKeepAliveTick }, suspend_keep_alive_interval_ms);
    var keep_alive_registered = true;
    errdefer if (keep_alive_registered) context.process.clearInterval(keep_alive) catch {};

    const ignore_sigint = SuspendSignalCallback{ .call_fn = ignoreSuspendSigint };
    try context.process.onSignal(.sigint, ignore_sigint);
    var sigint_registered = true;
    errdefer if (sigint_registered) context.process.removeListener(.sigint, ignore_sigint) catch {};

    const resume_state = try allocator.create(SuspendResumeState);
    var resume_state_owned_by_function = true;
    errdefer if (resume_state_owned_by_function) allocator.destroy(resume_state);
    resume_state.* = .{
        .allocator = allocator,
        .ui = context.ui,
        .process = context.process,
        .keep_alive = keep_alive,
        .sigint_callback = ignore_sigint,
    };

    try context.process.onceSignal(.sigcont, .{
        .ptr = resume_state,
        .call_fn = resumeAfterSuspend,
    });

    try context.ui.stop();
    context.process.killProcessGroup(.sigtstp) catch |err| {
        try resume_state.cleanup();
        keep_alive_registered = false;
        sigint_registered = false;
        resume_state_owned_by_function = false;
        allocator.destroy(resume_state);
        return err;
    };

    keep_alive_registered = false;
    sigint_registered = false;
    resume_state_owned_by_function = false;
}

fn suspendKeepAliveTick(_: ?*anyopaque) !void {}

fn ignoreSuspendSigint(_: ?*anyopaque) !void {}

fn resumeAfterSuspend(ptr: ?*anyopaque) !void {
    const state: *SuspendResumeState = @ptrCast(@alignCast(ptr.?));
    const allocator = state.allocator;
    defer allocator.destroy(state);

    try state.cleanup();
    try state.ui.start();
    try state.ui.requestRender(true);
}

pub const InteractiveStatusUi = struct {
    ptr: ?*anyopaque = null,
    request_render_fn: *const fn (?*anyopaque) anyerror!void,

    fn requestRender(self: InteractiveStatusUi) !void {
        try self.request_render_fn(self.ptr);
    }
};

pub const InteractiveStatusController = struct {
    allocator: std.mem.Allocator,
    chat_container: *tui.Container,
    ui: InteractiveStatusUi,
    last_status_spacer: ?*tui.Spacer = null,
    last_status_text: ?*tui.Text = null,
    owned_spacers: std.ArrayList(*tui.Spacer) = .empty,
    owned_texts: std.ArrayList(*tui.Text) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        chat_container: *tui.Container,
        ui: InteractiveStatusUi,
    ) InteractiveStatusController {
        return .{
            .allocator = allocator,
            .chat_container = chat_container,
            .ui = ui,
        };
    }

    pub fn deinit(self: *InteractiveStatusController) void {
        for (self.owned_texts.items) |text| {
            text.deinit();
            self.allocator.destroy(text);
        }
        for (self.owned_spacers.items) |spacer| self.allocator.destroy(spacer);
        self.owned_texts.deinit(self.allocator);
        self.owned_spacers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn showStatus(self: *InteractiveStatusController, message: []const u8) !void {
        if (self.isLastStatusPair()) {
            try self.last_status_text.?.setText(message);
            try self.ui.requestRender();
            return;
        }

        const spacer = try self.allocator.create(tui.Spacer);
        errdefer self.allocator.destroy(spacer);
        spacer.* = tui.Spacer.init(1);
        try self.owned_spacers.append(self.allocator, spacer);

        const text = try self.allocator.create(tui.Text);
        errdefer self.allocator.destroy(text);
        text.* = try tui.Text.init(self.allocator, message, 1, 0, null);
        errdefer text.deinit();
        try self.owned_texts.append(self.allocator, text);

        try self.chat_container.addChild(tui.Component.from(tui.Spacer, spacer));
        try self.chat_container.addChild(tui.Component.from(tui.Text, text));
        self.last_status_spacer = spacer;
        self.last_status_text = text;
        try self.ui.requestRender();
    }

    fn isLastStatusPair(self: *const InteractiveStatusController) bool {
        const spacer = self.last_status_spacer orelse return false;
        const text = self.last_status_text orelse return false;
        const children = self.chat_container.children.items;
        if (children.len < 2) return false;

        const second_last = children[children.len - 2];
        const last = children[children.len - 1];
        return second_last.ptr == @as(*anyopaque, @ptrCast(spacer)) and
            last.ptr == @as(*anyopaque, @ptrCast(text));
    }
};

pub const ToolExpansionTarget = struct {
    ptr: ?*anyopaque = null,
    set_expanded_fn: ?*const fn (?*anyopaque, bool) anyerror!void = null,

    fn setExpanded(self: ToolExpansionTarget, expanded: bool) !void {
        if (self.set_expanded_fn) |set_expanded| try set_expanded(self.ptr, expanded);
    }
};

pub const ToolExpansionUi = struct {
    ptr: ?*anyopaque = null,
    request_render_fn: *const fn (?*anyopaque) anyerror!void,

    fn requestRender(self: ToolExpansionUi) !void {
        try self.request_render_fn(self.ptr);
    }
};

pub const ToolExpansionContext = struct {
    tool_output_expanded: *bool,
    custom_header: ?ToolExpansionTarget = null,
    built_in_header: ?ToolExpansionTarget = null,
    chat_children: []const ToolExpansionTarget = &.{},
    ui: ToolExpansionUi,
};

pub fn setToolsExpanded(context: ToolExpansionContext, expanded: bool) !void {
    context.tool_output_expanded.* = expanded;
    const active_header = context.custom_header orelse context.built_in_header;
    if (active_header) |header| try header.setExpanded(expanded);
    for (context.chat_children) |child| try child.setExpanded(expanded);
    try context.ui.requestRender();
}

pub const AutocompleteRebuildCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque) anyerror!void,

    fn call(self: AutocompleteRebuildCallback) !void {
        try self.call_fn(self.ptr);
    }
};

pub fn addAutocompleteProviderWrapper(
    allocator: std.mem.Allocator,
    wrappers: *std.ArrayList(extension_types.AutocompleteProviderFactory),
    wrapper: extension_types.AutocompleteProviderFactory,
    rebuild: AutocompleteRebuildCallback,
) !void {
    try wrappers.append(allocator, wrapper);
    try rebuild.call();
}

pub const BaseAutocompleteProviderFactory = struct {
    ptr: ?*anyopaque = null,
    create_fn: *const fn (?*anyopaque) anyerror!tui.AutocompleteProvider,

    fn create(self: BaseAutocompleteProviderFactory) !tui.AutocompleteProvider {
        return self.create_fn(self.ptr);
    }
};

pub const AutocompleteEditorTarget = struct {
    ptr: ?*anyopaque = null,
    set_autocomplete_provider_fn: *const fn (?*anyopaque, tui.AutocompleteProvider) anyerror!void,

    fn setAutocompleteProvider(self: AutocompleteEditorTarget, provider: tui.AutocompleteProvider) !void {
        try self.set_autocomplete_provider_fn(self.ptr, provider);
    }

    fn eql(self: AutocompleteEditorTarget, other: AutocompleteEditorTarget) bool {
        return self.ptr == other.ptr and self.set_autocomplete_provider_fn == other.set_autocomplete_provider_fn;
    }
};

pub const AutocompleteSetupContext = struct {
    autocomplete_provider: *?tui.AutocompleteProvider,
    create_base_provider: BaseAutocompleteProviderFactory,
    default_editor: AutocompleteEditorTarget,
    editor: AutocompleteEditorTarget,
    wrappers: []const extension_types.AutocompleteProviderFactory = &.{},
};

pub fn setupAutocompleteProvider(context: AutocompleteSetupContext) !void {
    var provider = try context.create_base_provider.create();
    for (context.wrappers) |wrap_provider| {
        provider = try wrap_provider.wrap(provider);
    }

    context.autocomplete_provider.* = provider;
    try context.default_editor.setAutocompleteProvider(provider);
    if (!context.editor.eql(context.default_editor)) {
        try context.editor.setAutocompleteProvider(provider);
    }
}

pub const ExtensionThemeSettings = struct {
    ptr: ?*anyopaque = null,
    get_theme_fn: *const fn (?*anyopaque) ?[]const u8,
    set_theme_fn: *const fn (?*anyopaque, []const u8) anyerror!void,

    fn getTheme(self: ExtensionThemeSettings) ?[]const u8 {
        return self.get_theme_fn(self.ptr);
    }

    fn setTheme(self: ExtensionThemeSettings, theme_name: []const u8) !void {
        try self.set_theme_fn(self.ptr, theme_name);
    }
};

pub const ExtensionThemeUi = struct {
    ptr: ?*anyopaque = null,
    request_render_fn: *const fn (?*anyopaque) anyerror!void,

    fn requestRender(self: ExtensionThemeUi) !void {
        try self.request_render_fn(self.ptr);
    }
};

pub const ExtensionThemeContext = struct {
    settings: ExtensionThemeSettings,
    ui: ExtensionThemeUi,
    registered_themes: []const theme_mod.Theme = &.{},
};

pub fn setExtensionTheme(context: ExtensionThemeContext, theme_name: []const u8) !theme_mod.ThemeSetResult {
    const result = theme_mod.setThemeName(context.registered_themes, theme_name);
    if (!result.success) return result;

    const current_theme = context.settings.getTheme();
    if (current_theme == null or !std.mem.eql(u8, current_theme.?, theme_name)) {
        try context.settings.setTheme(theme_name);
    }
    try context.ui.requestRender();
    return result;
}

pub const ExtensionCustomEditorText = struct {
    ptr: ?*anyopaque = null,
    get_text_fn: *const fn (?*anyopaque, std.mem.Allocator) anyerror![]u8,
    set_text_fn: *const fn (?*anyopaque, []const u8) anyerror!void,

    fn getTextAlloc(self: ExtensionCustomEditorText, allocator: std.mem.Allocator) ![]u8 {
        return self.get_text_fn(self.ptr, allocator);
    }

    fn setText(self: ExtensionCustomEditorText, text: []const u8) !void {
        try self.set_text_fn(self.ptr, text);
    }
};

pub const ExtensionCustomDispose = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque) anyerror!void,

    fn call(self: ExtensionCustomDispose) !void {
        try self.call_fn(self.ptr);
    }
};

pub const ExtensionCustomOverlayHandleCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, tui.OverlayHandle) anyerror!void,

    fn call(self: ExtensionCustomOverlayHandleCallback, handle: tui.OverlayHandle) !void {
        try self.call_fn(self.ptr, handle);
    }
};

pub const ExtensionCustomContext = struct {
    ui: *tui.TUI,
    editor_container: *tui.Container,
    editor: tui.Component,
    editor_text: ExtensionCustomEditorText,
};

pub const ExtensionCustomSpec = struct {
    component: tui.Component,
    dispose: ?ExtensionCustomDispose = null,
};

pub const ExtensionCustomOptions = struct {
    overlay: bool = false,
    overlay_options: tui.OverlayOptions = .{},
    on_handle: ?ExtensionCustomOverlayHandleCallback = null,
};

pub const ExtensionCustomHandle = struct {
    allocator: std.mem.Allocator,
    context: ExtensionCustomContext,
    component: tui.Component,
    dispose: ?ExtensionCustomDispose,
    saved_text: []u8,
    overlay: bool,
    overlay_handle: ?tui.OverlayHandle = null,
    closed: bool = false,

    pub fn deinit(self: *ExtensionCustomHandle) void {
        self.allocator.free(self.saved_text);
        self.saved_text = &.{};
    }

    pub fn close(self: *ExtensionCustomHandle) !void {
        if (self.closed) return;
        self.closed = true;
        if (self.overlay) {
            if (self.overlay_handle) |handle| handle.hide();
        } else {
            try self.restoreEditor();
        }
        if (self.dispose) |dispose| dispose.call() catch {};
    }

    fn restoreEditor(self: *ExtensionCustomHandle) !void {
        self.context.editor_container.clear();
        try self.context.editor_container.addChild(self.context.editor);
        try self.context.editor_text.setText(self.saved_text);
        self.context.ui.setFocus(self.context.editor);
        try self.context.ui.requestRender(false);
    }
};

pub fn showExtensionCustom(
    allocator: std.mem.Allocator,
    context: ExtensionCustomContext,
    spec: ExtensionCustomSpec,
    options: ExtensionCustomOptions,
) !ExtensionCustomHandle {
    const saved_text = try context.editor_text.getTextAlloc(allocator);
    errdefer allocator.free(saved_text);

    var overlay_handle: ?tui.OverlayHandle = null;
    if (options.overlay) {
        const handle = try context.ui.showOverlay(spec.component, options.overlay_options);
        overlay_handle = handle;
        if (options.on_handle) |callback| try callback.call(handle);
    } else {
        context.editor_container.clear();
        try context.editor_container.addChild(spec.component);
        context.ui.setFocus(spec.component);
        try context.ui.requestRender(false);
    }

    return .{
        .allocator = allocator,
        .context = context,
        .component = spec.component,
        .dispose = spec.dispose,
        .saved_text = saved_text,
        .overlay = options.overlay,
        .overlay_handle = overlay_handle,
    };
}

pub const LoadedResourceSourceInfo = source_info.SourceInfo;

pub const LoadedResource = struct {
    path: []const u8,
    source_info: ?LoadedResourceSourceInfo = null,
};

pub const LoadedContextFile = struct {
    path: []const u8,
    content: []const u8 = "",
};

pub const LoadedSkillResource = struct {
    file_path: []const u8,
    name: []const u8,
    source_info: ?LoadedResourceSourceInfo = null,
};

pub const LoadedPromptResource = struct {
    file_path: []const u8,
    name: []const u8,
    source_info: ?LoadedResourceSourceInfo = null,
};

pub const LoadedThemeResource = struct {
    name: ?[]const u8 = null,
    source_path: ?[]const u8 = null,
    source_info: ?LoadedResourceSourceInfo = null,
};

pub const LoadedExtensionError = struct {
    path: []const u8,
    error_message: []const u8,
};

pub const LoadedResourcesSnapshot = struct {
    context_files: []const LoadedContextFile = &.{},
    skills: []const LoadedSkillResource = &.{},
    skill_diagnostics: []const resource_loader.ResourceDiagnostic = &.{},
    prompts: []const LoadedPromptResource = &.{},
    prompt_diagnostics: []const resource_loader.ResourceDiagnostic = &.{},
    extensions: []const LoadedResource = &.{},
    extension_errors: []const LoadedExtensionError = &.{},
    command_diagnostics: []const resource_loader.ResourceDiagnostic = &.{},
    shortcut_diagnostics: []const resource_loader.ResourceDiagnostic = &.{},
    built_in_command_conflict_diagnostics: []const resource_loader.ResourceDiagnostic = &.{},
    themes: []const LoadedThemeResource = &.{},
    theme_diagnostics: []const resource_loader.ResourceDiagnostic = &.{},
};

pub const LoadedResourcesOptions = struct {
    quiet_startup: bool,
    verbose: bool = false,
    tool_output_expanded: bool = false,
    cwd: []const u8 = ".",
    home_dir: ?[]const u8 = null,
    force: bool = false,
    show_diagnostics_when_quiet: bool = false,
    theme: render_utils.RenderTheme = .{},
    scope_groups_override: ?[]const u8 = null,
};

pub const LoadedResourcesController = struct {
    allocator: std.mem.Allocator,
    chat_container: *tui.Container,
    owned_spacers: std.ArrayList(*tui.Spacer) = .empty,
    owned_texts: std.ArrayList(*tui.Text) = .empty,

    pub fn init(allocator: std.mem.Allocator, chat_container: *tui.Container) LoadedResourcesController {
        return .{
            .allocator = allocator,
            .chat_container = chat_container,
        };
    }

    pub fn deinit(self: *LoadedResourcesController) void {
        for (self.owned_texts.items) |text| {
            text.deinit();
            self.allocator.destroy(text);
        }
        for (self.owned_spacers.items) |spacer| self.allocator.destroy(spacer);
        self.owned_texts.deinit(self.allocator);
        self.owned_spacers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn showLoadedResources(
        self: *LoadedResourcesController,
        resources: LoadedResourcesSnapshot,
        options: LoadedResourcesOptions,
    ) !void {
        const show_listing = options.force or options.verbose or !options.quiet_startup;
        const show_diagnostics = show_listing or options.show_diagnostics_when_quiet;
        if (!show_listing and !show_diagnostics) return;

        var source_infos: std.ArrayList(SourceInfoEntry) = .empty;
        defer source_infos.deinit(self.allocator);
        try collectLoadedSourceInfos(self.allocator, &source_infos, resources);

        if (show_listing) {
            if (resources.context_files.len > 0) {
                try self.addSpacer(1);
                const context_list = try self.formatContextListAlloc(resources.context_files, options);
                defer self.allocator.free(context_list);
                const context_compact = try self.formatContextCompactListAlloc(resources.context_files, options);
                defer self.allocator.free(context_compact);
                try self.addLoadedSection("Context", context_compact, context_list, options);
            }

            if (resources.skills.len > 0) {
                const items = try loadedResourcesFromSkillsAlloc(self.allocator, resources.skills);
                defer self.allocator.free(items);
                const skill_list = try self.formatScopeGroupsForKindAlloc(items, .display_path, options, null);
                defer self.allocator.free(skill_list);
                const names = try stringListFromSkillsAlloc(self.allocator, resources.skills);
                defer self.allocator.free(names);
                const skill_compact = try formatCompactListAlloc(self.allocator, options.theme, names, .{});
                defer self.allocator.free(skill_compact);
                try self.addLoadedSection("Skills", skill_compact, skill_list, options);
            }

            if (resources.prompts.len > 0) {
                const items = try loadedResourcesFromPromptsAlloc(self.allocator, resources.prompts);
                defer self.allocator.free(items);
                const prompt_list = try self.formatPromptScopeGroupsAlloc(items, resources.prompts, options);
                defer self.allocator.free(prompt_list);
                const names = try commandNamesFromPromptsAlloc(self.allocator, resources.prompts);
                defer freeOwnedStrings(self.allocator, names);
                const prompt_compact = try formatCompactListAlloc(self.allocator, options.theme, names, .{});
                defer self.allocator.free(prompt_compact);
                try self.addLoadedSection("Prompts", prompt_compact, prompt_list, options);
            }

            if (resources.extensions.len > 0) {
                const extension_list = try self.formatScopeGroupsForKindAlloc(resources.extensions, .extension_path, options, null);
                defer self.allocator.free(extension_list);
                const compact_labels = try getCompactExtensionLabelsAlloc(self.allocator, resources.extensions, options);
                defer freeOwnedStrings(self.allocator, compact_labels);
                const extension_compact = try formatCompactListAlloc(self.allocator, options.theme, compact_labels, .{});
                defer self.allocator.free(extension_compact);
                try self.addLoadedSection("Extensions", extension_compact, extension_list, options);
            }

            const custom_themes = try loadedResourcesFromThemesAlloc(self.allocator, resources.themes);
            defer self.allocator.free(custom_themes);
            if (custom_themes.len > 0) {
                const theme_list = try self.formatScopeGroupsForKindAlloc(custom_themes, .display_path, options, null);
                defer self.allocator.free(theme_list);
                const theme_names = try compactNamesFromThemesAlloc(self.allocator, resources.themes, options);
                defer freeOwnedStrings(self.allocator, theme_names);
                const theme_compact = try formatCompactListAlloc(self.allocator, options.theme, theme_names, .{});
                defer self.allocator.free(theme_compact);
                try self.addLoadedSection("Themes", theme_compact, theme_list, options);
            }
        }

        if (show_diagnostics) {
            if (resources.skill_diagnostics.len > 0) {
                const warning_lines = try formatDiagnosticsAlloc(self.allocator, resources.skill_diagnostics, source_infos.items, options);
                defer self.allocator.free(warning_lines);
                try self.addDiagnosticSection("Skill conflicts", warning_lines, options);
            }

            if (resources.prompt_diagnostics.len > 0) {
                const warning_lines = try formatDiagnosticsAlloc(self.allocator, resources.prompt_diagnostics, source_infos.items, options);
                defer self.allocator.free(warning_lines);
                try self.addDiagnosticSection("Prompt conflicts", warning_lines, options);
            }

            var extension_diagnostics: std.ArrayList(DisplayDiagnostic) = .empty;
            defer extension_diagnostics.deinit(self.allocator);
            for (resources.extension_errors) |extension_error| {
                try extension_diagnostics.append(self.allocator, .{
                    .type = .@"error",
                    .message = extension_error.error_message,
                    .path = extension_error.path,
                });
            }
            try appendResourceDiagnostics(self.allocator, &extension_diagnostics, resources.command_diagnostics);
            try appendResourceDiagnostics(self.allocator, &extension_diagnostics, resources.built_in_command_conflict_diagnostics);
            try appendResourceDiagnostics(self.allocator, &extension_diagnostics, resources.shortcut_diagnostics);
            if (extension_diagnostics.items.len > 0) {
                const warning_lines = try formatDisplayDiagnosticsAlloc(self.allocator, extension_diagnostics.items, source_infos.items, options);
                defer self.allocator.free(warning_lines);
                try self.addDiagnosticSection("Extension issues", warning_lines, options);
            }

            if (resources.theme_diagnostics.len > 0) {
                const warning_lines = try formatDiagnosticsAlloc(self.allocator, resources.theme_diagnostics, source_infos.items, options);
                defer self.allocator.free(warning_lines);
                try self.addDiagnosticSection("Theme conflicts", warning_lines, options);
            }
        }
    }

    fn addLoadedSection(
        self: *LoadedResourcesController,
        name: []const u8,
        collapsed_body: []const u8,
        expanded_body: []const u8,
        options: LoadedResourcesOptions,
    ) !void {
        const header = try sectionHeaderAlloc(self.allocator, options.theme, name, .accent);
        defer self.allocator.free(header);
        const body = if (options.verbose or options.tool_output_expanded) expanded_body else collapsed_body;
        const text = try std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ header, body });
        defer self.allocator.free(text);
        try self.addText(text);
        try self.addSpacer(1);
    }

    fn addDiagnosticSection(
        self: *LoadedResourcesController,
        name: []const u8,
        body: []const u8,
        options: LoadedResourcesOptions,
    ) !void {
        const header = try sectionHeaderAlloc(self.allocator, options.theme, name, .warning);
        defer self.allocator.free(header);
        const text = try std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ header, body });
        defer self.allocator.free(text);
        try self.addText(text);
        try self.addSpacer(1);
    }

    fn addText(self: *LoadedResourcesController, value: []const u8) !void {
        const text = try self.allocator.create(tui.Text);
        errdefer self.allocator.destroy(text);
        text.* = try tui.Text.init(self.allocator, value, 0, 0, null);
        errdefer text.deinit();
        try self.owned_texts.append(self.allocator, text);
        try self.chat_container.addChild(tui.Component.from(tui.Text, text));
    }

    fn addSpacer(self: *LoadedResourcesController, lines: usize) !void {
        const spacer = try self.allocator.create(tui.Spacer);
        errdefer self.allocator.destroy(spacer);
        spacer.* = tui.Spacer.init(lines);
        try self.owned_spacers.append(self.allocator, spacer);
        try self.chat_container.addChild(tui.Component.from(tui.Spacer, spacer));
    }

    fn formatContextListAlloc(
        self: *LoadedResourcesController,
        files: []const LoadedContextFile,
        options: LoadedResourcesOptions,
    ) ![]u8 {
        var lines: std.ArrayList([]u8) = .empty;
        defer freeOwnedStringList(self.allocator, &lines);
        for (files) |file| {
            const display = try formatDisplayPathAlloc(self.allocator, file.path, options.home_dir);
            defer self.allocator.free(display);
            const raw = try std.fmt.allocPrint(self.allocator, "  {s}", .{display});
            defer self.allocator.free(raw);
            try lines.append(self.allocator, try options.theme.fgAlloc(self.allocator, .dim, raw));
        }
        return joinLinesAlloc(self.allocator, lines.items);
    }

    fn formatContextCompactListAlloc(
        self: *LoadedResourcesController,
        files: []const LoadedContextFile,
        options: LoadedResourcesOptions,
    ) ![]u8 {
        var labels: std.ArrayList([]u8) = .empty;
        defer freeOwnedStringList(self.allocator, &labels);
        for (files) |file| {
            try labels.append(self.allocator, try formatContextPathAlloc(self.allocator, file.path, options));
        }
        return formatCompactListAlloc(self.allocator, options.theme, labels.items, .{ .sort = false });
    }

    const ScopeFormatKind = enum {
        display_path,
        extension_path,
    };

    fn formatScopeGroupsForKindAlloc(
        self: *LoadedResourcesController,
        items: []const LoadedResource,
        kind: ScopeFormatKind,
        options: LoadedResourcesOptions,
        package_prompt_names: ?[]const LoadedPromptResource,
    ) ![]u8 {
        if (options.scope_groups_override) |override| return self.allocator.dupe(u8, override);

        var groups = try buildScopeGroups(self.allocator, items);
        defer groups.deinit();
        return formatScopeGroupsAlloc(self.allocator, groups.items.items, options, kind, package_prompt_names);
    }

    fn formatPromptScopeGroupsAlloc(
        self: *LoadedResourcesController,
        items: []const LoadedResource,
        prompts: []const LoadedPromptResource,
        options: LoadedResourcesOptions,
    ) ![]u8 {
        if (options.scope_groups_override) |override| return self.allocator.dupe(u8, override);

        var groups = try buildScopeGroups(self.allocator, items);
        defer groups.deinit();
        return formatScopeGroupsAlloc(self.allocator, groups.items.items, options, .display_path, prompts);
    }
};

const FormatCompactListOptions = struct {
    sort: bool = true,
};

fn formatCompactListAlloc(
    allocator: std.mem.Allocator,
    theme: render_utils.RenderTheme,
    items: []const []const u8,
    options: FormatCompactListOptions,
) ![]u8 {
    var labels: std.ArrayList([]u8) = .empty;
    defer freeOwnedStringList(allocator, &labels);

    for (items) |item| {
        const trimmed = std.mem.trim(u8, item, " \t\r\n");
        if (trimmed.len == 0) continue;
        try labels.append(allocator, try allocator.dupe(u8, trimmed));
    }

    if (options.sort) {
        std.mem.sort([]u8, labels.items, {}, stringLessThan);
    }

    const joined = try joinWithSeparatorAlloc(allocator, labels.items, ", ");
    defer allocator.free(joined);
    const raw = try std.fmt.allocPrint(allocator, "  {s}", .{joined});
    defer allocator.free(raw);
    return theme.fgAlloc(allocator, .dim, raw);
}

fn sectionHeaderAlloc(
    allocator: std.mem.Allocator,
    theme: render_utils.RenderTheme,
    name: []const u8,
    color: render_utils.ThemeColor,
) ![]u8 {
    const raw = try std.fmt.allocPrint(allocator, "[{s}]", .{name});
    defer allocator.free(raw);
    return theme.fgAlloc(allocator, color, raw);
}

fn formatDisplayPathAlloc(allocator: std.mem.Allocator, input_path: []const u8, maybe_home_dir: ?[]const u8) ![]u8 {
    if (maybe_home_dir) |home_dir| {
        if (home_dir.len > 0 and std.mem.startsWith(u8, input_path, home_dir)) {
            return std.fmt.allocPrint(allocator, "~{s}", .{input_path[home_dir.len..]});
        }
        return allocator.dupe(u8, input_path);
    }
    return allocator.dupe(u8, input_path);
}

fn formatExtensionDisplayPathAlloc(allocator: std.mem.Allocator, input_path: []const u8, options: LoadedResourcesOptions) ![]u8 {
    var result = try formatDisplayPathAlloc(allocator, input_path, options.home_dir);
    if (stripSuffix(result, "/index.ts")) |stripped| {
        const copy = try allocator.dupe(u8, stripped);
        allocator.free(result);
        result = copy;
    } else if (stripSuffix(result, "/index.js")) |stripped| {
        const copy = try allocator.dupe(u8, stripped);
        allocator.free(result);
        result = copy;
    }
    return result;
}

fn formatContextPathAlloc(allocator: std.mem.Allocator, input_path: []const u8, options: LoadedResourcesOptions) ![]u8 {
    const cwd = try paths.resolvePathAlloc(allocator, options.cwd, ".", .{});
    defer allocator.free(cwd);
    const absolute_path = try paths.resolvePathAlloc(allocator, input_path, cwd, .{});
    defer allocator.free(absolute_path);

    if (try paths.getCwdRelativePathAlloc(allocator, absolute_path, cwd)) |relative| {
        defer allocator.free(relative);
        return slashPathAlloc(allocator, relative);
    }
    return formatDisplayPathAlloc(allocator, absolute_path, options.home_dir);
}

fn getShortPathAlloc(
    allocator: std.mem.Allocator,
    full_path: []const u8,
    maybe_info: ?LoadedResourceSourceInfo,
    options: LoadedResourcesOptions,
) ![]u8 {
    if (maybe_info) |info| {
        if (info.base_dir) |base_dir| {
            if (isPackageSource(maybe_info)) {
                const resolved_base = try paths.resolvePathAlloc(allocator, base_dir, ".", .{});
                defer allocator.free(resolved_base);
                const resolved_full = try paths.resolvePathAlloc(allocator, full_path, ".", .{});
                defer allocator.free(resolved_full);
                const relative = try std.fs.path.relative(allocator, ".", null, resolved_base, resolved_full);
                errdefer allocator.free(relative);
                if (relative.len > 0 and
                    !std.mem.eql(u8, relative, ".") and
                    !std.mem.startsWith(u8, relative, "..") and
                    !std.mem.startsWith(u8, relative, ".." ++ std.fs.path.sep_str) and
                    !std.fs.path.isAbsolute(relative))
                {
                    const slashed = try slashPathAlloc(allocator, relative);
                    allocator.free(relative);
                    return slashed;
                }
                allocator.free(relative);
            }
        }

        if (std.mem.startsWith(u8, info.source, "npm:")) {
            if (npmPackageRemainder(full_path)) |remainder| return allocator.dupe(u8, remainder);
        }

        if (std.mem.startsWith(u8, info.source, "git:")) {
            if (gitPackageRemainder(full_path)) |remainder| return allocator.dupe(u8, remainder);
        }
    }

    return formatDisplayPathAlloc(allocator, full_path, options.home_dir);
}

fn getCompactPathLabelAlloc(
    allocator: std.mem.Allocator,
    resource_path: []const u8,
    maybe_info: ?LoadedResourceSourceInfo,
    options: LoadedResourcesOptions,
) ![]u8 {
    const short_path = try getShortPathAlloc(allocator, resource_path, maybe_info, options);
    defer allocator.free(short_path);
    const normalized = try slashPathAlloc(allocator, short_path);
    defer allocator.free(normalized);

    var it = std.mem.splitScalar(u8, normalized, '/');
    var last: ?[]const u8 = null;
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, "~")) continue;
        last = segment;
    }
    return allocator.dupe(u8, last orelse short_path);
}

fn getCompactPackageSourceLabelAlloc(
    allocator: std.mem.Allocator,
    maybe_info: ?LoadedResourceSourceInfo,
) ![]u8 {
    const info = maybe_info orelse return allocator.dupe(u8, "");
    if (std.mem.startsWith(u8, info.source, "npm:")) {
        const label = info.source["npm:".len..];
        return allocator.dupe(u8, if (label.len == 0) info.source else label);
    }

    if (try git.parseGitUrlAlloc(allocator, info.source)) |parsed_value| {
        var parsed = parsed_value;
        defer parsed.deinit();
        return allocator.dupe(u8, if (parsed.path.len == 0) info.source else parsed.path);
    }

    return allocator.dupe(u8, info.source);
}

fn getCompactExtensionLabelAlloc(
    allocator: std.mem.Allocator,
    resource_path: []const u8,
    maybe_info: ?LoadedResourceSourceInfo,
    options: LoadedResourcesOptions,
) ![]u8 {
    if (!isPackageSource(maybe_info)) {
        return getCompactPathLabelAlloc(allocator, resource_path, maybe_info, options);
    }

    const source_label = try getCompactPackageSourceLabelAlloc(allocator, maybe_info);
    defer allocator.free(source_label);
    if (source_label.len == 0) {
        return getCompactPathLabelAlloc(allocator, resource_path, maybe_info, options);
    }

    const short_path = try getShortPathAlloc(allocator, resource_path, maybe_info, options);
    defer allocator.free(short_path);
    var package_path = try slashPathAlloc(allocator, short_path);
    defer allocator.free(package_path);
    if (std.mem.startsWith(u8, package_path, "extensions/")) {
        const copy = try allocator.dupe(u8, package_path["extensions/".len..]);
        allocator.free(package_path);
        package_path = copy;
    }

    const base = posixBasename(package_path);
    const stem = pathStem(base);
    if (std.mem.eql(u8, stem, "index")) {
        const dir = posixDirname(package_path);
        if (dir.len == 0 or std.mem.eql(u8, dir, ".")) return allocator.dupe(u8, source_label);
        return std.fmt.allocPrint(allocator, "{s}:{s}", .{ source_label, dir });
    }

    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ source_label, package_path });
}

const CompactDisplayPathSegments = struct {
    path: []const u8,
    source_info: ?LoadedResourceSourceInfo,
    normalized: []u8,
    segments: [][]const u8,
    active_len: usize,

    fn deinit(self: *CompactDisplayPathSegments, allocator: std.mem.Allocator) void {
        allocator.free(self.segments);
        allocator.free(self.normalized);
        self.* = undefined;
    }
};

fn getCompactDisplayPathSegmentsAlloc(
    allocator: std.mem.Allocator,
    resource: LoadedResource,
    options: LoadedResourcesOptions,
) !CompactDisplayPathSegments {
    const display = try formatDisplayPathAlloc(allocator, resource.path, options.home_dir);
    defer allocator.free(display);
    const normalized = try slashPathAlloc(allocator, display);
    errdefer allocator.free(normalized);

    var segments: std.ArrayList([]const u8) = .empty;
    errdefer segments.deinit(allocator);
    var it = std.mem.splitScalar(u8, normalized, '/');
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, "~")) continue;
        try segments.append(allocator, segment);
    }

    const active_len = segments.items.len;
    return .{
        .path = resource.path,
        .source_info = resource.source_info,
        .normalized = normalized,
        .segments = try segments.toOwnedSlice(allocator),
        .active_len = active_len,
    };
}

fn getCompactNonPackageExtensionLabelAlloc(
    allocator: std.mem.Allocator,
    resource_path: []const u8,
    index: usize,
    all_paths: []const CompactDisplayPathSegments,
    options: LoadedResourcesOptions,
) ![]u8 {
    if (index >= all_paths.len or all_paths[index].segments.len == 0) {
        return getCompactPathLabelAlloc(allocator, resource_path, null, options);
    }

    const segments = all_paths[index].segments[0..all_paths[index].active_len];
    var segment_count: usize = 1;
    while (segment_count <= segments.len) : (segment_count += 1) {
        const candidate = try joinWithSeparatorAlloc(allocator, segments[segments.len - segment_count ..], "/");
        errdefer allocator.free(candidate);
        var unique = true;
        for (all_paths, 0..) |item, item_index| {
            if (item_index == index) continue;
            const other_segments = item.segments;
            const other_active_segments = other_segments[0..item.active_len];
            if (other_active_segments.len < segment_count) continue;
            const other = try joinWithSeparatorAlloc(allocator, other_active_segments[other_active_segments.len - segment_count ..], "/");
            defer allocator.free(other);
            if (std.mem.eql(u8, candidate, other)) {
                unique = false;
                break;
            }
        }
        if (unique) return candidate;
        allocator.free(candidate);
    }

    return joinWithSeparatorAlloc(allocator, segments, "/");
}

fn getCompactExtensionLabelsAlloc(
    allocator: std.mem.Allocator,
    extensions: []const LoadedResource,
    options: LoadedResourcesOptions,
) ![][]u8 {
    var non_package: std.ArrayList(CompactDisplayPathSegments) = .empty;
    defer {
        for (non_package.items) |*item| item.deinit(allocator);
        non_package.deinit(allocator);
    }

    for (extensions) |extension| {
        if (isPackageSource(extension.source_info)) continue;
        var segments = try getCompactDisplayPathSegmentsAlloc(allocator, extension, options);
        errdefer segments.deinit(allocator);
        if (segments.active_len > 1) {
            const last = segments.segments[segments.active_len - 1];
            if (std.mem.eql(u8, last, "index.ts") or std.mem.eql(u8, last, "index.js")) {
                segments.active_len -= 1;
            }
        }
        try non_package.append(allocator, segments);
    }

    var labels: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedStringList(allocator, &labels);
    for (extensions) |extension| {
        if (isPackageSource(extension.source_info)) {
            try labels.append(allocator, try getCompactExtensionLabelAlloc(allocator, extension.path, extension.source_info, options));
            continue;
        }

        const non_package_index = findCompactPathIndex(non_package.items, extension.path);
        if (non_package_index) |index| {
            try labels.append(
                allocator,
                try getCompactNonPackageExtensionLabelAlloc(allocator, extension.path, index, non_package.items, options),
            );
        } else {
            try labels.append(allocator, try getCompactPathLabelAlloc(allocator, extension.path, extension.source_info, options));
        }
    }
    return labels.toOwnedSlice(allocator);
}

fn findCompactPathIndex(items: []const CompactDisplayPathSegments, path: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.path, path)) return index;
    }
    return null;
}

const SourceInfoEntry = struct {
    path: []const u8,
    source_info: LoadedResourceSourceInfo,
};

fn collectLoadedSourceInfos(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(SourceInfoEntry),
    resources: LoadedResourcesSnapshot,
) !void {
    for (resources.extensions) |extension| {
        if (extension.source_info) |info| try entries.append(allocator, .{ .path = extension.path, .source_info = info });
    }
    for (resources.skills) |skill| {
        if (skill.source_info) |info| try entries.append(allocator, .{ .path = skill.file_path, .source_info = info });
    }
    for (resources.prompts) |prompt| {
        if (prompt.source_info) |info| try entries.append(allocator, .{ .path = prompt.file_path, .source_info = info });
    }
    for (resources.themes) |loaded_theme| {
        if (loaded_theme.source_path) |source_path| {
            if (loaded_theme.source_info) |info| try entries.append(allocator, .{ .path = source_path, .source_info = info });
        }
    }
}

const Scope = enum {
    user,
    project,
    path,

    fn label(self: Scope) []const u8 {
        return switch (self) {
            .user => "user",
            .project => "project",
            .path => "path",
        };
    }
};

const ScopePackageGroup = struct {
    source: []const u8,
    items: std.ArrayList(LoadedResource) = .empty,

    fn deinit(self: *ScopePackageGroup, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.* = undefined;
    }
};

const ScopeGroup = struct {
    scope: Scope,
    paths: std.ArrayList(LoadedResource) = .empty,
    packages: std.ArrayList(ScopePackageGroup) = .empty,

    fn deinit(self: *ScopeGroup, allocator: std.mem.Allocator) void {
        self.paths.deinit(allocator);
        for (self.packages.items) |*package| package.deinit(allocator);
        self.packages.deinit(allocator);
        self.* = undefined;
    }
};

const ScopeGroups = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(ScopeGroup),

    fn deinit(self: *ScopeGroups) void {
        for (self.items.items) |*group| group.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }
};

fn buildScopeGroups(allocator: std.mem.Allocator, items: []const LoadedResource) !ScopeGroups {
    var project = ScopeGroup{ .scope = .project };
    errdefer project.deinit(allocator);
    var user = ScopeGroup{ .scope = .user };
    errdefer user.deinit(allocator);
    var path = ScopeGroup{ .scope = .path };
    errdefer path.deinit(allocator);

    for (items) |item| {
        const group = switch (getScopeGroup(item.source_info)) {
            .project => &project,
            .user => &user,
            .path => &path,
        };
        if (isPackageSource(item.source_info)) {
            const source = if (item.source_info) |info| info.source else "local";
            try appendPackageItem(allocator, group, source, item);
        } else {
            try group.paths.append(allocator, item);
        }
    }

    var groups: std.ArrayList(ScopeGroup) = .empty;
    errdefer {
        for (groups.items) |*group| group.deinit(allocator);
        groups.deinit(allocator);
    }
    if (project.paths.items.len > 0 or project.packages.items.len > 0) {
        try groups.append(allocator, project);
        project = ScopeGroup{ .scope = .project };
    }
    if (user.paths.items.len > 0 or user.packages.items.len > 0) {
        try groups.append(allocator, user);
        user = ScopeGroup{ .scope = .user };
    }
    if (path.paths.items.len > 0 or path.packages.items.len > 0) {
        try groups.append(allocator, path);
        path = ScopeGroup{ .scope = .path };
    }

    return .{ .allocator = allocator, .items = groups };
}

fn appendPackageItem(
    allocator: std.mem.Allocator,
    group: *ScopeGroup,
    source: []const u8,
    item: LoadedResource,
) !void {
    for (group.packages.items) |*package| {
        if (std.mem.eql(u8, package.source, source)) {
            try package.items.append(allocator, item);
            return;
        }
    }
    var package = ScopePackageGroup{ .source = source };
    errdefer package.deinit(allocator);
    try package.items.append(allocator, item);
    try group.packages.append(allocator, package);
}

fn getScopeGroup(maybe_info: ?LoadedResourceSourceInfo) Scope {
    const info = maybe_info orelse return .project;
    if (std.mem.eql(u8, info.source, "cli") or info.scope == .temporary) return .path;
    if (info.scope == .user) return .user;
    if (info.scope == .project) return .project;
    return .path;
}

fn isPackageSource(maybe_info: ?LoadedResourceSourceInfo) bool {
    const info = maybe_info orelse return false;
    return std.mem.startsWith(u8, info.source, "npm:") or std.mem.startsWith(u8, info.source, "git:");
}

fn formatScopeGroupsAlloc(
    allocator: std.mem.Allocator,
    groups: []ScopeGroup,
    options: LoadedResourcesOptions,
    kind: LoadedResourcesController.ScopeFormatKind,
    prompt_names: ?[]const LoadedPromptResource,
) ![]u8 {
    var lines: std.ArrayList([]u8) = .empty;
    defer freeOwnedStringList(allocator, &lines);

    for (groups) |*group| {
        std.mem.sort(LoadedResource, group.paths.items, {}, loadedResourceLessThan);
        std.mem.sort(ScopePackageGroup, group.packages.items, {}, packageGroupLessThan);

        const styled_scope = try options.theme.fgAlloc(allocator, .accent, group.scope.label());
        defer allocator.free(styled_scope);
        try lines.append(allocator, try std.fmt.allocPrint(allocator, "  {s}", .{styled_scope}));

        for (group.paths.items) |item| {
            const label = try formatScopeItemPathAlloc(allocator, item, options, kind, prompt_names, false);
            defer allocator.free(label);
            const raw = try std.fmt.allocPrint(allocator, "    {s}", .{label});
            defer allocator.free(raw);
            try lines.append(allocator, try options.theme.fgAlloc(allocator, .dim, raw));
        }

        for (group.packages.items) |*package| {
            std.mem.sort(LoadedResource, package.items.items, {}, loadedResourceLessThan);
            const styled_source = try options.theme.fgAlloc(allocator, .accent, package.source);
            defer allocator.free(styled_source);
            try lines.append(allocator, try std.fmt.allocPrint(allocator, "    {s}", .{styled_source}));
            for (package.items.items) |item| {
                const label = try formatScopeItemPathAlloc(allocator, item, options, kind, prompt_names, true);
                defer allocator.free(label);
                const raw = try std.fmt.allocPrint(allocator, "      {s}", .{label});
                defer allocator.free(raw);
                try lines.append(allocator, try options.theme.fgAlloc(allocator, .dim, raw));
            }
        }
    }

    return joinLinesAlloc(allocator, lines.items);
}

fn formatScopeItemPathAlloc(
    allocator: std.mem.Allocator,
    item: LoadedResource,
    options: LoadedResourcesOptions,
    kind: LoadedResourcesController.ScopeFormatKind,
    prompt_names: ?[]const LoadedPromptResource,
    package_path: bool,
) ![]u8 {
    if (prompt_names) |prompts| {
        if (findPromptByPath(prompts, item.path)) |prompt| {
            return std.fmt.allocPrint(allocator, "/{s}", .{prompt.name});
        }
    }

    return switch (kind) {
        .display_path => if (package_path)
            getShortPathAlloc(allocator, item.path, item.source_info, options)
        else
            formatDisplayPathAlloc(allocator, item.path, options.home_dir),
        .extension_path => if (package_path) blk: {
            const short_path = try getShortPathAlloc(allocator, item.path, item.source_info, options);
            defer allocator.free(short_path);
            break :blk formatExtensionDisplayPathAlloc(allocator, short_path, options);
        } else formatExtensionDisplayPathAlloc(allocator, item.path, options),
    };
}

fn findPromptByPath(prompts: []const LoadedPromptResource, path: []const u8) ?LoadedPromptResource {
    for (prompts) |prompt| {
        if (std.mem.eql(u8, prompt.file_path, path)) return prompt;
    }
    return null;
}

const DisplayDiagnosticType = enum {
    warning,
    @"error",
    collision,
};

const DisplayDiagnostic = struct {
    type: DisplayDiagnosticType,
    message: []const u8,
    path: []const u8 = "",
    collision: ?resource_loader.ResourceCollision = null,
};

fn appendResourceDiagnostics(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(DisplayDiagnostic),
    source: []const resource_loader.ResourceDiagnostic,
) !void {
    for (source) |diagnostic| {
        try diagnostics.append(allocator, displayDiagnosticFromResourceDiagnostic(diagnostic));
    }
}

fn displayDiagnosticFromResourceDiagnostic(diagnostic: resource_loader.ResourceDiagnostic) DisplayDiagnostic {
    return .{
        .type = switch (diagnostic.type) {
            .warning => .warning,
            .collision => .collision,
        },
        .message = diagnostic.message,
        .path = diagnostic.path,
        .collision = diagnostic.collision,
    };
}

fn formatDiagnosticsAlloc(
    allocator: std.mem.Allocator,
    diagnostics: []const resource_loader.ResourceDiagnostic,
    source_infos: []const SourceInfoEntry,
    options: LoadedResourcesOptions,
) ![]u8 {
    var display: std.ArrayList(DisplayDiagnostic) = .empty;
    defer display.deinit(allocator);
    try appendResourceDiagnostics(allocator, &display, diagnostics);
    return formatDisplayDiagnosticsAlloc(allocator, display.items, source_infos, options);
}

fn formatDisplayDiagnosticsAlloc(
    allocator: std.mem.Allocator,
    diagnostics: []const DisplayDiagnostic,
    source_infos: []const SourceInfoEntry,
    options: LoadedResourcesOptions,
) ![]u8 {
    var lines: std.ArrayList([]u8) = .empty;
    defer freeOwnedStringList(allocator, &lines);

    for (diagnostics) |diagnostic| {
        if (diagnostic.type == .collision and diagnostic.collision != null) {
            const collision = diagnostic.collision.?;
            const raw_header = try std.fmt.allocPrint(allocator, "  \"{s}\" collision:", .{collision.name});
            defer allocator.free(raw_header);
            try lines.append(allocator, try options.theme.fgAlloc(allocator, .warning, raw_header));

            const winner = try formatPathWithSourceAlloc(
                allocator,
                collision.winner_path,
                findSourceInfoForPath(collision.winner_path, source_infos),
                options,
            );
            defer allocator.free(winner);
            const raw_winner = try std.fmt.allocPrint(allocator, "    ✓ {s}", .{winner});
            defer allocator.free(raw_winner);
            try lines.append(allocator, try options.theme.fgAlloc(allocator, .dim, raw_winner));

            const loser = try formatPathWithSourceAlloc(
                allocator,
                collision.loser_path,
                findSourceInfoForPath(collision.loser_path, source_infos),
                options,
            );
            defer allocator.free(loser);
            const raw_loser = try std.fmt.allocPrint(allocator, "    ✗ {s} (skipped)", .{loser});
            defer allocator.free(raw_loser);
            try lines.append(allocator, try options.theme.fgAlloc(allocator, .dim, raw_loser));
            continue;
        }

        const color: render_utils.ThemeColor = if (diagnostic.type == .@"error") .@"error" else .warning;
        if (diagnostic.path.len > 0) {
            const formatted_path = try formatPathWithSourceAlloc(
                allocator,
                diagnostic.path,
                findSourceInfoForPath(diagnostic.path, source_infos),
                options,
            );
            defer allocator.free(formatted_path);
            const raw_path = try std.fmt.allocPrint(allocator, "  {s}", .{formatted_path});
            defer allocator.free(raw_path);
            try lines.append(allocator, try options.theme.fgAlloc(allocator, color, raw_path));
            const raw_message = try std.fmt.allocPrint(allocator, "    {s}", .{diagnostic.message});
            defer allocator.free(raw_message);
            try lines.append(allocator, try options.theme.fgAlloc(allocator, color, raw_message));
        } else {
            const raw_message = try std.fmt.allocPrint(allocator, "  {s}", .{diagnostic.message});
            defer allocator.free(raw_message);
            try lines.append(allocator, try options.theme.fgAlloc(allocator, color, raw_message));
        }
    }

    return joinLinesAlloc(allocator, lines.items);
}

fn findSourceInfoForPath(path: []const u8, source_infos: []const SourceInfoEntry) ?LoadedResourceSourceInfo {
    for (source_infos) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry.source_info;
    }

    var current = path;
    while (std.mem.lastIndexOfScalar(u8, current, '/')) |slash| {
        current = current[0..slash];
        for (source_infos) |entry| {
            if (std.mem.eql(u8, entry.path, current)) return entry.source_info;
        }
    }
    return null;
}

fn formatPathWithSourceAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    maybe_info: ?LoadedResourceSourceInfo,
    options: LoadedResourcesOptions,
) ![]u8 {
    const info = maybe_info orelse return formatDisplayPathAlloc(allocator, path, options.home_dir);
    const short_path = try getShortPathAlloc(allocator, path, info, options);
    defer allocator.free(short_path);
    const display = getDisplaySourceInfo(info);
    if (display.scope_label) |scope_label| {
        return std.fmt.allocPrint(allocator, "{s} ({s}) {s}", .{ display.label, scope_label, short_path });
    }
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ display.label, short_path });
}

const DisplaySourceInfo = struct {
    label: []const u8,
    scope_label: ?[]const u8 = null,
};

fn getDisplaySourceInfo(info: LoadedResourceSourceInfo) DisplaySourceInfo {
    if (std.mem.eql(u8, info.source, "local")) {
        return switch (info.scope) {
            .user => .{ .label = "user" },
            .project => .{ .label = "project" },
            .temporary => .{ .label = "path", .scope_label = "temp" },
        };
    }

    if (std.mem.eql(u8, info.source, "cli")) {
        return .{
            .label = "path",
            .scope_label = if (info.scope == .temporary) "temp" else null,
        };
    }

    return .{
        .label = info.source,
        .scope_label = switch (info.scope) {
            .user => "user",
            .project => "project",
            .temporary => "temp",
        },
    };
}

fn loadedResourcesFromSkillsAlloc(allocator: std.mem.Allocator, skills: []const LoadedSkillResource) ![]LoadedResource {
    var items = try allocator.alloc(LoadedResource, skills.len);
    for (skills, 0..) |skill, index| {
        items[index] = .{ .path = skill.file_path, .source_info = skill.source_info };
    }
    return items;
}

fn loadedResourcesFromPromptsAlloc(allocator: std.mem.Allocator, prompts: []const LoadedPromptResource) ![]LoadedResource {
    var items = try allocator.alloc(LoadedResource, prompts.len);
    for (prompts, 0..) |prompt, index| {
        items[index] = .{ .path = prompt.file_path, .source_info = prompt.source_info };
    }
    return items;
}

fn loadedResourcesFromThemesAlloc(allocator: std.mem.Allocator, themes: []const LoadedThemeResource) ![]LoadedResource {
    var count: usize = 0;
    for (themes) |loaded_theme| {
        if (loaded_theme.source_path != null) count += 1;
    }
    var items = try allocator.alloc(LoadedResource, count);
    var index: usize = 0;
    for (themes) |loaded_theme| {
        if (loaded_theme.source_path) |source_path| {
            items[index] = .{ .path = source_path, .source_info = loaded_theme.source_info };
            index += 1;
        }
    }
    return items;
}

fn stringListFromSkillsAlloc(allocator: std.mem.Allocator, skills: []const LoadedSkillResource) ![][]const u8 {
    var items = try allocator.alloc([]const u8, skills.len);
    for (skills, 0..) |skill, index| items[index] = skill.name;
    return items;
}

fn commandNamesFromPromptsAlloc(allocator: std.mem.Allocator, prompts: []const LoadedPromptResource) ![][]u8 {
    var items = try allocator.alloc([]u8, prompts.len);
    errdefer {
        for (items[0..]) |item| if (item.len > 0) allocator.free(item);
        allocator.free(items);
    }
    for (prompts, 0..) |prompt, index| {
        items[index] = try std.fmt.allocPrint(allocator, "/{s}", .{prompt.name});
    }
    return items;
}

fn compactNamesFromThemesAlloc(
    allocator: std.mem.Allocator,
    themes: []const LoadedThemeResource,
    options: LoadedResourcesOptions,
) ![][]u8 {
    var labels: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedStringList(allocator, &labels);
    for (themes) |loaded_theme| {
        const source_path = loaded_theme.source_path orelse continue;
        if (loaded_theme.name) |name| {
            try labels.append(allocator, try allocator.dupe(u8, name));
        } else {
            try labels.append(allocator, try getCompactPathLabelAlloc(allocator, source_path, loaded_theme.source_info, options));
        }
    }
    return labels.toOwnedSlice(allocator);
}

fn npmPackageRemainder(path: []const u8) ?[]const u8 {
    const normalized_start = std.mem.indexOf(u8, path, "node_modules/") orelse return null;
    var rest = path[normalized_start + "node_modules/".len ..];
    if (rest.len == 0) return null;
    if (rest[0] == '@') {
        const first_slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        const second_slash = std.mem.indexOfScalarPos(u8, rest, first_slash + 1, '/') orelse return null;
        return rest[second_slash + 1 ..];
    }
    const first_slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    rest = rest[first_slash + 1 ..];
    return if (rest.len > 0) rest else null;
}

fn gitPackageRemainder(path: []const u8) ?[]const u8 {
    const git_index = std.mem.indexOf(u8, path, "git/") orelse return null;
    var rest = path[git_index + "git/".len ..];
    var slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    rest = rest[slash + 1 ..];
    slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    rest = rest[slash + 1 ..];
    return if (rest.len > 0) rest else null;
}

fn stripSuffix(value: []const u8, suffix: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, value, suffix)) return null;
    return value[0 .. value.len - suffix.len];
}

fn slashPathAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const output = try allocator.dupe(u8, value);
    for (output) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    return output;
}

fn posixBasename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn posixDirname(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    if (slash == 0) return "/";
    return path[0..slash];
}

fn pathStem(base: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    if (dot == 0) return base;
    return base[0..dot];
}

fn joinLinesAlloc(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    return joinWithSeparatorAlloc(allocator, lines, "\n");
}

fn joinWithSeparatorAlloc(allocator: std.mem.Allocator, items: []const []const u8, separator: []const u8) ![]u8 {
    var total: usize = 0;
    for (items, 0..) |item, index| {
        if (index > 0) total += separator.len;
        total += item.len;
    }

    var output = try allocator.alloc(u8, total);
    var offset: usize = 0;
    for (items, 0..) |item, index| {
        if (index > 0) {
            @memcpy(output[offset .. offset + separator.len], separator);
            offset += separator.len;
        }
        @memcpy(output[offset .. offset + item.len], item);
        offset += item.len;
    }
    return output;
}

fn freeOwnedStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

fn freeOwnedStrings(allocator: std.mem.Allocator, items: []const []u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn loadedResourceLessThan(_: void, lhs: LoadedResource, rhs: LoadedResource) bool {
    return std.mem.order(u8, lhs.path, rhs.path) == .lt;
}

fn packageGroupLessThan(_: void, lhs: ScopePackageGroup, rhs: ScopePackageGroup) bool {
    return std.mem.order(u8, lhs.source, rhs.source) == .lt;
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    const min_len = @min(lhs.len, rhs.len);
    var index: usize = 0;
    while (index < min_len) : (index += 1) {
        const left = std.ascii.toLower(lhs[index]);
        const right = std.ascii.toLower(rhs[index]);
        if (left < right) return true;
        if (left > right) return false;
    }
    if (lhs.len != rhs.len) return lhs.len < rhs.len;
    return std.mem.order(u8, lhs, rhs) == .lt;
}

pub const InteractiveEventUi = struct {
    ptr: ?*anyopaque = null,
    clear_chat_fn: *const fn (?*anyopaque) anyerror!void,
    rebuild_chat_from_messages_fn: *const fn (?*anyopaque) anyerror!void,
    add_message_to_chat_fn: *const fn (?*anyopaque, messages_mod.CodingAgentMessage) anyerror!void,
    flush_compaction_queue_fn: *const fn (?*anyopaque, bool) anyerror!void,
    request_render_fn: ?*const fn (?*anyopaque) anyerror!void = null,
    invalidate_footer_fn: ?*const fn (?*anyopaque) anyerror!void = null,
    show_error_fn: ?*const fn (?*anyopaque, []const u8) anyerror!void = null,
    show_status_fn: ?*const fn (?*anyopaque, []const u8) anyerror!void = null,
    clear_status_fn: ?*const fn (?*anyopaque) anyerror!void = null,
    set_terminal_progress_fn: ?*const fn (?*anyopaque, bool) anyerror!void = null,

    fn clearChat(self: InteractiveEventUi) !void {
        try self.clear_chat_fn(self.ptr);
    }

    fn rebuildChatFromMessages(self: InteractiveEventUi) !void {
        try self.rebuild_chat_from_messages_fn(self.ptr);
    }

    fn addMessageToChat(self: InteractiveEventUi, message: messages_mod.CodingAgentMessage) !void {
        try self.add_message_to_chat_fn(self.ptr, message);
    }

    fn flushCompactionQueue(self: InteractiveEventUi, will_retry: bool) !void {
        try self.flush_compaction_queue_fn(self.ptr, will_retry);
    }

    fn requestRender(self: InteractiveEventUi) !void {
        if (self.request_render_fn) |request_fn| try request_fn(self.ptr);
    }

    fn invalidateFooter(self: InteractiveEventUi) !void {
        if (self.invalidate_footer_fn) |invalidate_fn| try invalidate_fn(self.ptr);
    }

    fn showError(self: InteractiveEventUi, message: []const u8) !void {
        if (self.show_error_fn) |show_fn| try show_fn(self.ptr, message);
    }

    fn showStatus(self: InteractiveEventUi, message: []const u8) !void {
        if (self.show_status_fn) |show_fn| try show_fn(self.ptr, message);
    }

    fn clearStatus(self: InteractiveEventUi) !void {
        if (self.clear_status_fn) |clear_fn| try clear_fn(self.ptr);
    }

    fn setTerminalProgress(self: InteractiveEventUi, enabled: bool) !void {
        if (self.set_terminal_progress_fn) |set_fn| try set_fn(self.ptr, enabled);
    }
};

pub const InteractiveEventContext = struct {
    ui: InteractiveEventUi,
    show_terminal_progress: bool = false,
};

pub fn handleInteractiveModeEvent(
    io: std.Io,
    context: InteractiveEventContext,
    event: session_events.SessionEvent,
) !void {
    switch (event) {
        .compaction_end => |compaction_end| try handleCompactionEndEvent(io, context, compaction_end),
        else => {},
    }
}

pub fn handleCompactionEndEvent(
    io: std.Io,
    context: InteractiveEventContext,
    event: session_events.CompactionEndSessionEvent,
) !void {
    if (context.show_terminal_progress) {
        try context.ui.setTerminalProgress(false);
    }
    try context.ui.clearStatus();

    if (event.aborted) {
        if (event.reason == .manual) {
            try context.ui.showError("Compaction cancelled");
        } else {
            try context.ui.showStatus("Auto-compaction cancelled");
        }
    } else if (event.result) |result| {
        try context.ui.clearChat();
        try context.ui.rebuildChatFromMessages();
        try context.ui.addMessageToChat(.{ .compaction_summary = .{
            .summary = result.summary,
            .tokens_before = result.tokens_before,
            .timestamp_ms = std.Io.Clock.real.now(io).toMilliseconds(),
        } });
        try context.ui.invalidateFooter();
    } else if (event.error_message) |message| {
        if (event.reason == .manual) {
            try context.ui.showError(message);
        } else {
            try context.ui.showStatus(message);
        }
    }

    try context.ui.flushCompactionQueue(event.will_retry);
    try context.ui.requestRender();
}

pub const CloneSessionManagerView = struct {
    ptr: ?*anyopaque = null,
    get_leaf_id_fn: *const fn (?*anyopaque) ?[]const u8,

    fn getLeafId(self: CloneSessionManagerView) ?[]const u8 {
        return self.get_leaf_id_fn(self.ptr);
    }
};

pub const CloneRuntimeHost = struct {
    ptr: ?*anyopaque = null,
    fork_fn: *const fn (?*anyopaque, []const u8, extension_types.ForkOptions) anyerror!agent_session_runtime.SessionChangeResult,

    fn fork(
        self: CloneRuntimeHost,
        entry_id: []const u8,
        options: extension_types.ForkOptions,
    ) !agent_session_runtime.SessionChangeResult {
        return self.fork_fn(self.ptr, entry_id, options);
    }
};

pub const CloneCommandEditor = struct {
    ptr: ?*anyopaque = null,
    set_text_fn: *const fn (?*anyopaque, []const u8) anyerror!void,

    fn setText(self: CloneCommandEditor, text: []const u8) !void {
        try self.set_text_fn(self.ptr, text);
    }
};

pub const CloneCommandUi = struct {
    ptr: ?*anyopaque = null,
    show_status_fn: *const fn (?*anyopaque, []const u8) anyerror!void,
    show_error_fn: *const fn (?*anyopaque, []const u8) anyerror!void,
    render_current_session_state_fn: *const fn (?*anyopaque) anyerror!void,
    request_render_fn: *const fn (?*anyopaque) anyerror!void,

    fn showStatus(self: CloneCommandUi, message: []const u8) !void {
        try self.show_status_fn(self.ptr, message);
    }

    fn showError(self: CloneCommandUi, message: []const u8) !void {
        try self.show_error_fn(self.ptr, message);
    }

    fn renderCurrentSessionState(self: CloneCommandUi) !void {
        try self.render_current_session_state_fn(self.ptr);
    }

    fn requestRender(self: CloneCommandUi) !void {
        try self.request_render_fn(self.ptr);
    }
};

pub const CloneCommandContext = struct {
    session_manager: CloneSessionManagerView,
    runtime_host: CloneRuntimeHost,
    editor: CloneCommandEditor,
    ui: CloneCommandUi,
};

pub fn handleCloneCommand(
    allocator: std.mem.Allocator,
    context: CloneCommandContext,
) !void {
    const leaf_id = context.session_manager.getLeafId() orelse {
        try context.ui.showStatus("Nothing to clone yet");
        return;
    };

    var result = context.runtime_host.fork(leaf_id, .{ .position = .at }) catch |err| {
        try context.ui.showError(@errorName(err));
        return;
    };
    defer result.deinit(allocator);

    if (result.cancelled) {
        try context.ui.requestRender();
        return;
    }

    try context.ui.renderCurrentSessionState();
    try context.editor.setText("");
    try context.ui.showStatus("Cloned to new session");
}

pub const StartupInputCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const u8) anyerror!void,

    fn call(self: StartupInputCallback, text: []const u8) !void {
        try self.call_fn(self.ptr, text);
    }
};

pub const StartupFlushCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque) anyerror!void,

    fn call(self: StartupFlushCallback) !void {
        try self.call_fn(self.ptr);
    }
};

pub const StartupSubmitEditor = struct {
    ptr: ?*anyopaque = null,
    add_to_history_fn: ?*const fn (?*anyopaque, []const u8) anyerror!void = null,
    set_text_fn: ?*const fn (?*anyopaque, []const u8) anyerror!void = null,

    fn addToHistory(self: StartupSubmitEditor, text: []const u8) !void {
        if (self.add_to_history_fn) |add_fn| try add_fn(self.ptr, text);
    }

    fn setText(self: StartupSubmitEditor, text: []const u8) !void {
        if (self.set_text_fn) |set_fn| try set_fn(self.ptr, text);
    }
};

pub const StartupSubmitSessionState = struct {
    is_compacting: bool = false,
    is_streaming: bool = false,
    is_bash_running: bool = false,
};

pub const StartupSubmitContext = struct {
    editor: StartupSubmitEditor,
    session: StartupSubmitSessionState = .{},
    flush_pending_bash_components: StartupFlushCallback,
};

pub const StartupUserInputResult = union(enum) {
    queued: []u8,
    waiting,
};

pub const StartupInputController = struct {
    allocator: std.mem.Allocator,
    pending_user_inputs: std.ArrayList([]u8) = .empty,
    on_input_callback: ?StartupInputCallback = null,

    pub fn init(allocator: std.mem.Allocator) StartupInputController {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StartupInputController) void {
        freeMessageList(self.allocator, &self.pending_user_inputs);
        self.* = undefined;
    }

    pub fn queueInput(self: *StartupInputController, text: []const u8) !void {
        const copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(copy);
        try self.pending_user_inputs.append(self.allocator, copy);
    }

    pub fn submitEditorText(
        self: *StartupInputController,
        context: StartupSubmitContext,
        submitted_text: []const u8,
    ) !void {
        const text = std.mem.trim(u8, submitted_text, " \t\n\r");
        if (text.len == 0) return;

        if (context.session.is_compacting or context.session.is_streaming or context.session.is_bash_running) {
            return error.UnsupportedStartupInputState;
        }

        try context.flush_pending_bash_components.call();
        if (self.on_input_callback) |callback| {
            try callback.call(text);
        } else {
            try self.queueInput(text);
        }
        try context.editor.addToHistory(text);
    }

    pub fn getUserInput(
        self: *StartupInputController,
        callback: StartupInputCallback,
    ) !StartupUserInputResult {
        if (self.pending_user_inputs.items.len > 0) {
            return .{ .queued = self.pending_user_inputs.orderedRemove(0) };
        }

        self.on_input_callback = callback;
        return .waiting;
    }
};

pub const ImportRuntimeHost = struct {
    ptr: ?*anyopaque = null,
    import_from_jsonl_fn: *const fn (?*anyopaque, []const u8, ?[]const u8) anyerror!agent_session_runtime.SessionChangeResult,

    pub fn importFromJsonl(
        self: ImportRuntimeHost,
        input_path: []const u8,
        cwd_override: ?[]const u8,
    ) !agent_session_runtime.SessionChangeResult {
        return self.import_from_jsonl_fn(self.ptr, input_path, cwd_override);
    }
};

pub const ImportCommandUi = struct {
    ptr: ?*anyopaque = null,
    show_error_fn: *const fn (?*anyopaque, []const u8) anyerror!void,
    show_status_fn: *const fn (?*anyopaque, []const u8) anyerror!void,
    show_confirm_fn: *const fn (?*anyopaque, []const u8, []const u8) anyerror!bool,
    clear_status_fn: ?*const fn (?*anyopaque) anyerror!void = null,
    render_current_session_state_fn: ?*const fn (?*anyopaque) anyerror!void = null,
    prompt_missing_session_cwd_fn: ?*const fn (?*anyopaque) anyerror!?[]const u8 = null,
    handle_fatal_runtime_error_fn: ?*const fn (?*anyopaque, []const u8, anyerror) anyerror!void = null,

    fn showError(self: ImportCommandUi, message: []const u8) !void {
        try self.show_error_fn(self.ptr, message);
    }

    fn showStatus(self: ImportCommandUi, message: []const u8) !void {
        try self.show_status_fn(self.ptr, message);
    }

    fn showConfirm(self: ImportCommandUi, title: []const u8, message: []const u8) !bool {
        return self.show_confirm_fn(self.ptr, title, message);
    }

    fn clearStatus(self: ImportCommandUi) !void {
        if (self.clear_status_fn) |clear_fn| try clear_fn(self.ptr);
    }

    fn renderCurrentSessionState(self: ImportCommandUi) !void {
        if (self.render_current_session_state_fn) |render_fn| try render_fn(self.ptr);
    }

    fn promptForMissingSessionCwd(self: ImportCommandUi) !?[]const u8 {
        const prompt_fn = self.prompt_missing_session_cwd_fn orelse return null;
        return prompt_fn(self.ptr);
    }

    fn handleFatalRuntimeError(
        self: ImportCommandUi,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        err: anyerror,
    ) !void {
        if (self.handle_fatal_runtime_error_fn) |fatal_fn| {
            try fatal_fn(self.ptr, prefix, err);
            return;
        }

        const message = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ prefix, @errorName(err) });
        defer allocator.free(message);
        try self.showError(message);
    }
};

pub const ImportCommandContext = struct {
    runtime_host: ImportRuntimeHost,
    ui: ImportCommandUi,
};

pub fn getPathCommandArgument(text: []const u8, command: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, text, command)) return null;
    if (!std.mem.startsWith(u8, text, command)) return null;
    if (text.len <= command.len or text[command.len] != ' ') return null;

    const args_string = trimLeftAsciiWhitespace(text[command.len + 1 ..]);
    if (args_string.len == 0) return null;

    const first_char = args_string[0];
    if (first_char == '"' or first_char == '\'') {
        const closing_quote_index = std.mem.indexOfScalarPos(u8, args_string, 1, first_char) orelse return null;
        return args_string[1..closing_quote_index];
    }

    const first_whitespace_index = firstAsciiWhitespaceIndex(args_string) orelse return args_string;
    return args_string[0..first_whitespace_index];
}

pub fn handleImportCommand(
    allocator: std.mem.Allocator,
    context: ImportCommandContext,
    text: []const u8,
) !void {
    const input_path = getPathCommandArgument(text, "/import") orelse {
        try context.ui.showError("Usage: /import <path.jsonl>");
        return;
    };

    const confirm_message = try std.fmt.allocPrint(
        allocator,
        "Replace current session with {s}?",
        .{input_path},
    );
    defer allocator.free(confirm_message);

    const confirmed = try context.ui.showConfirm("Import session", confirm_message);
    if (!confirmed) {
        try context.ui.showStatus("Import cancelled");
        return;
    }

    try context.ui.clearStatus();
    const result = context.runtime_host.importFromJsonl(input_path, null) catch |err| {
        try handleImportCommandError(allocator, context, input_path, err);
        return;
    };
    try finishImportCommand(allocator, context, input_path, result);
}

fn handleImportCommandError(
    allocator: std.mem.Allocator,
    context: ImportCommandContext,
    input_path: []const u8,
    err: anyerror,
) !void {
    switch (err) {
        error.MissingSessionCwd => {
            const selected_cwd = try context.ui.promptForMissingSessionCwd() orelse {
                try context.ui.showStatus("Import cancelled");
                return;
            };
            const retry_result = context.runtime_host.importFromJsonl(input_path, selected_cwd) catch |retry_err| {
                try showImportRuntimeError(allocator, context, input_path, retry_err);
                return;
            };
            try finishImportCommand(allocator, context, input_path, retry_result);
        },
        else => try showImportRuntimeError(allocator, context, input_path, err),
    }
}

fn showImportRuntimeError(
    allocator: std.mem.Allocator,
    context: ImportCommandContext,
    input_path: []const u8,
    err: anyerror,
) !void {
    if (err == error.SessionImportFileNotFound) {
        const error_detail = try (agent_session_runtime.SessionImportFileNotFoundError{
            .file_path = input_path,
        }).messageAlloc(allocator);
        defer allocator.free(error_detail);
        const message = try std.fmt.allocPrint(allocator, "Failed to import session: {s}", .{error_detail});
        defer allocator.free(message);
        try context.ui.showError(message);
        return;
    }
    try context.ui.handleFatalRuntimeError(allocator, "Failed to import session", err);
}

fn finishImportCommand(
    allocator: std.mem.Allocator,
    context: ImportCommandContext,
    input_path: []const u8,
    result: agent_session_runtime.SessionChangeResult,
) !void {
    var owned_result = result;
    defer owned_result.deinit(allocator);

    if (owned_result.cancelled) {
        try context.ui.showStatus("Import cancelled");
        return;
    }

    try context.ui.renderCurrentSessionState();
    const status = try std.fmt.allocPrint(allocator, "Session imported from: {s}", .{input_path});
    defer allocator.free(status);
    try context.ui.showStatus(status);
}

fn firstAsciiWhitespaceIndex(value: []const u8) ?usize {
    for (value, 0..) |byte, index| {
        switch (byte) {
            ' ', '\t', '\n', '\r', 0x0b, 0x0c => return index,
            else => {},
        }
    }
    return null;
}

fn trimLeftAsciiWhitespace(value: []const u8) []const u8 {
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        switch (value[index]) {
            ' ', '\t', '\n', '\r', 0x0b, 0x0c => {},
            else => break,
        }
    }
    return value[index..];
}

pub const FormatResumeCommandSession = struct {
    persisted: bool = true,
    session_file: ?[]const u8 = null,
    session_id: []const u8,
    session_dir: []const u8 = "",
    uses_default_session_dir: bool = true,
};

pub fn formatResumeCommandAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: FormatResumeCommandSession,
    stdout_is_tty: bool,
) !?[]u8 {
    if (!stdout_is_tty) return null;
    if (!session.persisted) return null;

    const session_file = session.session_file orelse return null;
    std.Io.Dir.cwd().access(io, session_file, .{}) catch return null;

    var command: std.Io.Writer.Allocating = .init(allocator);
    errdefer command.deinit();

    try command.writer.writeAll(config.command_name);
    if (!session.uses_default_session_dir) {
        const quoted_session_dir = try quoteIfNeededAlloc(allocator, session.session_dir);
        defer allocator.free(quoted_session_dir);
        try command.writer.print(" --session-dir {s}", .{quoted_session_dir});
    }
    try command.writer.print(" --session {s}", .{session.session_id});
    return try command.toOwnedSlice();
}

pub fn formatResumeCommandFromManagerAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_manager: *const session_manager_mod.SessionManager,
    stdout_is_tty: bool,
    agent_dir: []const u8,
) !?[]u8 {
    const uses_default_session_dir = try session_manager.usesDefaultSessionDir(allocator, io, agent_dir);
    return formatResumeCommandAlloc(allocator, io, .{
        .persisted = session_manager.isPersisted(),
        .session_file = session_manager.getSessionFile(),
        .session_id = session_manager.getSessionId(),
        .session_dir = session_manager.getSessionDir(),
        .uses_default_session_dir = uses_default_session_dir,
    }, stdout_is_tty);
}

fn quoteIfNeededAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len > 0 and isShellSafeUnquoted(value)) {
        return allocator.dupe(u8, value);
    }

    var quoted: std.ArrayList(u8) = .empty;
    errdefer quoted.deinit(allocator);
    try quoted.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try quoted.appendSlice(allocator, "'\\''");
        } else {
            try quoted.append(allocator, byte);
        }
    }
    try quoted.append(allocator, '\'');
    return quoted.toOwnedSlice(allocator);
}

fn isShellSafeUnquoted(value: []const u8) bool {
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '_', '-', '.', '/', '~', ':', '@' => continue,
            else => return false,
        }
    }
    return true;
}

const TempSessionFile = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    path: []u8,

    fn deinit(self: *TempSessionFile) void {
        self.allocator.free(self.path);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

fn createTempSessionFile(allocator: std.mem.Allocator) !TempSessionFile {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();

    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);
    const session_file = try std.fs.path.join(allocator, &.{ tmp_path, "session.jsonl" });
    errdefer allocator.free(session_file);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = session_file,
        .data = "\n",
        .flags = .{ .read = true, .truncate = true },
    });
    return .{
        .allocator = allocator,
        .tmp = tmp,
        .path = session_file,
    };
}

fn expectResumeCommand(session: FormatResumeCommandSession, stdout_is_tty: bool, expected: ?[]const u8) !void {
    const actual = try formatResumeCommandAlloc(std.testing.allocator, std.testing.io, session, stdout_is_tty);
    defer if (actual) |value| std.testing.allocator.free(value);

    if (expected) |expected_value| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(expected_value, actual.?);
    } else {
        try std.testing.expectEqual(null, actual);
    }
}

// Ported from packages/coding-agent/test/format-resume-command.test.ts.
test "formatResumeCommand returns session resume command for default session dirs" {
    var session_file = try createTempSessionFile(std.testing.allocator);
    defer session_file.deinit();

    try expectResumeCommand(.{
        .session_file = session_file.path,
        .session_id = "test-session",
    }, true, "bulb --session test-session");
}

test "formatResumeCommand includes and quotes non-default session dirs" {
    var session_file = try createTempSessionFile(std.testing.allocator);
    defer session_file.deinit();

    try expectResumeCommand(.{
        .session_file = session_file.path,
        .session_id = "test-session",
        .session_dir = "/tmp/custom-bulb-sessions",
        .uses_default_session_dir = false,
    }, true, "bulb --session-dir /tmp/custom-bulb-sessions --session test-session");

    try expectResumeCommand(.{
        .session_file = session_file.path,
        .session_id = "test-session",
        .session_dir = "/tmp/custom bulb sessions",
        .uses_default_session_dir = false,
    }, true, "bulb --session-dir '/tmp/custom bulb sessions' --session test-session");

    try expectResumeCommand(.{
        .session_file = session_file.path,
        .session_id = "test-session",
        .session_dir = "/tmp/custom bulb's sessions",
        .uses_default_session_dir = false,
    }, true, "bulb --session-dir '/tmp/custom bulb'\\''s sessions' --session test-session");
}

test "formatResumeCommand returns null for non-TTY in-memory and missing session files" {
    var session_file = try createTempSessionFile(std.testing.allocator);
    defer session_file.deinit();

    try expectResumeCommand(.{
        .session_file = session_file.path,
        .session_id = "test-session",
    }, false, null);

    try expectResumeCommand(.{
        .persisted = false,
        .session_file = session_file.path,
        .session_id = "test-session",
    }, true, null);

    try expectResumeCommand(.{
        .session_file = "/tmp/bulb-missing-session.jsonl",
        .session_id = "test-session",
    }, true, null);

    try expectResumeCommand(.{
        .session_file = null,
        .session_id = "test-session",
    }, true, null);
}

const TestImportUi = struct {
    allocator: std.mem.Allocator,
    confirm_result: bool = true,
    prompt_cwd: ?[]const u8 = null,
    errors: std.ArrayList([]u8) = .empty,
    statuses: std.ArrayList([]u8) = .empty,
    confirm_titles: std.ArrayList([]u8) = .empty,
    confirm_messages: std.ArrayList([]u8) = .empty,
    clear_count: usize = 0,
    render_count: usize = 0,
    fatal_count: usize = 0,

    fn init(allocator: std.mem.Allocator) TestImportUi {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestImportUi) void {
        freeMessageList(self.allocator, &self.errors);
        freeMessageList(self.allocator, &self.statuses);
        freeMessageList(self.allocator, &self.confirm_titles);
        freeMessageList(self.allocator, &self.confirm_messages);
        self.* = undefined;
    }

    fn callbacks(self: *TestImportUi) ImportCommandUi {
        return .{
            .ptr = self,
            .show_error_fn = showError,
            .show_status_fn = showStatus,
            .show_confirm_fn = showConfirm,
            .clear_status_fn = clearStatus,
            .render_current_session_state_fn = renderCurrentSessionState,
            .prompt_missing_session_cwd_fn = promptForMissingSessionCwd,
            .handle_fatal_runtime_error_fn = handleFatalRuntimeError,
        };
    }

    fn appendMessage(self: *TestImportUi, list: *std.ArrayList([]u8), message: []const u8) !void {
        const copy = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(copy);
        try list.append(self.allocator, copy);
    }

    fn showError(ptr: ?*anyopaque, message: []const u8) !void {
        const self: *TestImportUi = @ptrCast(@alignCast(ptr.?));
        try self.appendMessage(&self.errors, message);
    }

    fn showStatus(ptr: ?*anyopaque, message: []const u8) !void {
        const self: *TestImportUi = @ptrCast(@alignCast(ptr.?));
        try self.appendMessage(&self.statuses, message);
    }

    fn showConfirm(ptr: ?*anyopaque, title: []const u8, message: []const u8) !bool {
        const self: *TestImportUi = @ptrCast(@alignCast(ptr.?));
        try self.appendMessage(&self.confirm_titles, title);
        try self.appendMessage(&self.confirm_messages, message);
        return self.confirm_result;
    }

    fn clearStatus(ptr: ?*anyopaque) !void {
        const self: *TestImportUi = @ptrCast(@alignCast(ptr.?));
        self.clear_count += 1;
    }

    fn renderCurrentSessionState(ptr: ?*anyopaque) !void {
        const self: *TestImportUi = @ptrCast(@alignCast(ptr.?));
        self.render_count += 1;
    }

    fn promptForMissingSessionCwd(ptr: ?*anyopaque) !?[]const u8 {
        const self: *TestImportUi = @ptrCast(@alignCast(ptr.?));
        return self.prompt_cwd;
    }

    fn handleFatalRuntimeError(ptr: ?*anyopaque, prefix: []const u8, err: anyerror) !void {
        _ = prefix;
        _ = @errorName(err);
        const self: *TestImportUi = @ptrCast(@alignCast(ptr.?));
        self.fatal_count += 1;
    }
};

fn freeMessageList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |message| allocator.free(message);
    list.deinit(allocator);
}

const TestInteractiveEventUi = struct {
    allocator: std.mem.Allocator,
    clear_chat_count: usize = 0,
    rebuild_chat_count: usize = 0,
    footer_invalidate_count: usize = 0,
    request_render_count: usize = 0,
    clear_status_count: usize = 0,
    terminal_progress_values: std.ArrayList(bool) = .empty,
    flush_will_retry_values: std.ArrayList(bool) = .empty,
    messages: std.ArrayList(messages_mod.CodingAgentMessage) = .empty,
    errors: std.ArrayList([]u8) = .empty,
    statuses: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator) TestInteractiveEventUi {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestInteractiveEventUi) void {
        self.terminal_progress_values.deinit(self.allocator);
        self.flush_will_retry_values.deinit(self.allocator);
        self.messages.deinit(self.allocator);
        freeMessageList(self.allocator, &self.errors);
        freeMessageList(self.allocator, &self.statuses);
        self.* = undefined;
    }

    fn callbacks(self: *TestInteractiveEventUi) InteractiveEventUi {
        return .{
            .ptr = self,
            .clear_chat_fn = clearChat,
            .rebuild_chat_from_messages_fn = rebuildChatFromMessages,
            .add_message_to_chat_fn = addMessageToChat,
            .flush_compaction_queue_fn = flushCompactionQueue,
            .request_render_fn = requestRender,
            .invalidate_footer_fn = invalidateFooter,
            .show_error_fn = showError,
            .show_status_fn = showStatus,
            .clear_status_fn = clearStatus,
            .set_terminal_progress_fn = setTerminalProgress,
        };
    }

    fn appendMessage(self: *TestInteractiveEventUi, list: *std.ArrayList([]u8), message: []const u8) !void {
        const copy = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(copy);
        try list.append(self.allocator, copy);
    }

    fn clearChat(ptr: ?*anyopaque) !void {
        const self: *TestInteractiveEventUi = @ptrCast(@alignCast(ptr.?));
        self.clear_chat_count += 1;
    }

    fn rebuildChatFromMessages(ptr: ?*anyopaque) !void {
        const self: *TestInteractiveEventUi = @ptrCast(@alignCast(ptr.?));
        self.rebuild_chat_count += 1;
    }

    fn addMessageToChat(ptr: ?*anyopaque, message: messages_mod.CodingAgentMessage) !void {
        const self: *TestInteractiveEventUi = @ptrCast(@alignCast(ptr.?));
        try self.messages.append(self.allocator, message);
    }

    fn flushCompactionQueue(ptr: ?*anyopaque, will_retry: bool) !void {
        const self: *TestInteractiveEventUi = @ptrCast(@alignCast(ptr.?));
        try self.flush_will_retry_values.append(self.allocator, will_retry);
    }

    fn requestRender(ptr: ?*anyopaque) !void {
        const self: *TestInteractiveEventUi = @ptrCast(@alignCast(ptr.?));
        self.request_render_count += 1;
    }

    fn invalidateFooter(ptr: ?*anyopaque) !void {
        const self: *TestInteractiveEventUi = @ptrCast(@alignCast(ptr.?));
        self.footer_invalidate_count += 1;
    }

    fn showError(ptr: ?*anyopaque, message: []const u8) !void {
        const self: *TestInteractiveEventUi = @ptrCast(@alignCast(ptr.?));
        try self.appendMessage(&self.errors, message);
    }

    fn showStatus(ptr: ?*anyopaque, message: []const u8) !void {
        const self: *TestInteractiveEventUi = @ptrCast(@alignCast(ptr.?));
        try self.appendMessage(&self.statuses, message);
    }

    fn clearStatus(ptr: ?*anyopaque) !void {
        const self: *TestInteractiveEventUi = @ptrCast(@alignCast(ptr.?));
        self.clear_status_count += 1;
    }

    fn setTerminalProgress(ptr: ?*anyopaque, enabled: bool) !void {
        const self: *TestInteractiveEventUi = @ptrCast(@alignCast(ptr.?));
        try self.terminal_progress_values.append(self.allocator, enabled);
    }
};

const TestAnthropicWarningRegistry = struct {
    api_key: ?[]const u8 = null,
    stored_auth_type: ?AnthropicWarningAuthType = null,
    get_stored_auth_type_count: usize = 0,
    get_api_key_count: usize = 0,

    fn callbacks(self: *TestAnthropicWarningRegistry) AnthropicWarningModelRegistry {
        return .{
            .ptr = self,
            .get_stored_auth_type_fn = getStoredAuthType,
            .get_api_key_for_provider_fn = getApiKeyForProvider,
        };
    }

    fn getStoredAuthType(ptr: ?*anyopaque, provider: []const u8) ?AnthropicWarningAuthType {
        const self: *TestAnthropicWarningRegistry = @ptrCast(@alignCast(ptr.?));
        self.get_stored_auth_type_count += 1;
        if (!std.mem.eql(u8, provider, "anthropic")) return null;
        return self.stored_auth_type;
    }

    fn getApiKeyForProvider(
        ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        provider: []const u8,
    ) !?[]u8 {
        const self: *TestAnthropicWarningRegistry = @ptrCast(@alignCast(ptr.?));
        self.get_api_key_count += 1;
        if (!std.mem.eql(u8, provider, "anthropic")) return null;
        const api_key = self.api_key orelse return null;
        return try allocator.dupe(u8, api_key);
    }
};

const TestAnthropicWarningUi = struct {
    allocator: std.mem.Allocator,
    warnings: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator) TestAnthropicWarningUi {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestAnthropicWarningUi) void {
        freeMessageList(self.allocator, &self.warnings);
        self.* = undefined;
    }

    fn callbacks(self: *TestAnthropicWarningUi) AnthropicWarningUi {
        return .{
            .ptr = self,
            .show_warning_fn = showWarning,
        };
    }

    fn showWarning(ptr: ?*anyopaque, message: []const u8) !void {
        const self: *TestAnthropicWarningUi = @ptrCast(@alignCast(ptr.?));
        const copy = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(copy);
        try self.warnings.append(self.allocator, copy);
    }
};

const TestSuspendUi = struct {
    allocator: std.mem.Allocator,
    start_count: usize = 0,
    stop_count: usize = 0,
    request_render_count: usize = 0,
    last_request_render_force: ?bool = null,
    statuses: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator) TestSuspendUi {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestSuspendUi) void {
        freeMessageList(self.allocator, &self.statuses);
        self.* = undefined;
    }

    fn callbacks(self: *TestSuspendUi) SuspendUi {
        return .{
            .ptr = self,
            .start_fn = start,
            .stop_fn = stop,
            .request_render_fn = requestRender,
            .show_status_fn = showStatus,
        };
    }

    fn start(ptr: ?*anyopaque) !void {
        const self: *TestSuspendUi = @ptrCast(@alignCast(ptr.?));
        self.start_count += 1;
    }

    fn stop(ptr: ?*anyopaque) !void {
        const self: *TestSuspendUi = @ptrCast(@alignCast(ptr.?));
        self.stop_count += 1;
    }

    fn requestRender(ptr: ?*anyopaque, force: bool) !void {
        const self: *TestSuspendUi = @ptrCast(@alignCast(ptr.?));
        self.request_render_count += 1;
        self.last_request_render_force = force;
    }

    fn showStatus(ptr: ?*anyopaque, message: []const u8) !void {
        const self: *TestSuspendUi = @ptrCast(@alignCast(ptr.?));
        const copy = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(copy);
        try self.statuses.append(self.allocator, copy);
    }
};

const TestSuspendProcess = struct {
    platform_value: SuspendPlatform = .posix,
    fail_kill: bool = false,
    set_interval_count: usize = 0,
    last_interval_ms: ?u64 = null,
    clear_interval_count: usize = 0,
    last_clear_handle: ?SuspendTimerHandle = null,
    on_sigint_count: usize = 0,
    once_sigcont_count: usize = 0,
    remove_sigint_count: usize = 0,
    kill_count: usize = 0,
    last_kill_signal: ?SuspendSignal = null,
    sigint_callback: ?SuspendSignalCallback = null,
    sigcont_callback: ?SuspendSignalCallback = null,
    removed_sigint_callback: ?SuspendSignalCallback = null,

    fn callbacks(self: *TestSuspendProcess) SuspendProcess {
        return .{
            .ptr = self,
            .platform_fn = platform,
            .set_interval_fn = setInterval,
            .clear_interval_fn = clearInterval,
            .on_signal_fn = onSignal,
            .once_signal_fn = onceSignal,
            .remove_listener_fn = removeListener,
            .kill_process_group_fn = killProcessGroup,
        };
    }

    fn platform(ptr: ?*anyopaque) SuspendPlatform {
        const self: *TestSuspendProcess = @ptrCast(@alignCast(ptr.?));
        return self.platform_value;
    }

    fn setInterval(
        ptr: ?*anyopaque,
        callback: SuspendTimerCallback,
        interval_ms: u64,
    ) !SuspendTimerHandle {
        _ = callback;
        const self: *TestSuspendProcess = @ptrCast(@alignCast(ptr.?));
        self.set_interval_count += 1;
        self.last_interval_ms = interval_ms;
        return .{ .id = 42 };
    }

    fn clearInterval(ptr: ?*anyopaque, handle: SuspendTimerHandle) !void {
        const self: *TestSuspendProcess = @ptrCast(@alignCast(ptr.?));
        self.clear_interval_count += 1;
        self.last_clear_handle = handle;
    }

    fn onSignal(ptr: ?*anyopaque, signal: SuspendSignal, callback: SuspendSignalCallback) !void {
        const self: *TestSuspendProcess = @ptrCast(@alignCast(ptr.?));
        if (signal == .sigint) {
            self.on_sigint_count += 1;
            self.sigint_callback = callback;
        }
    }

    fn onceSignal(ptr: ?*anyopaque, signal: SuspendSignal, callback: SuspendSignalCallback) !void {
        const self: *TestSuspendProcess = @ptrCast(@alignCast(ptr.?));
        if (signal == .sigcont) {
            self.once_sigcont_count += 1;
            self.sigcont_callback = callback;
        }
    }

    fn removeListener(ptr: ?*anyopaque, signal: SuspendSignal, callback: SuspendSignalCallback) !void {
        const self: *TestSuspendProcess = @ptrCast(@alignCast(ptr.?));
        if (signal == .sigint) {
            self.remove_sigint_count += 1;
            self.removed_sigint_callback = callback;
        }
    }

    fn killProcessGroup(ptr: ?*anyopaque, signal: SuspendSignal) !void {
        const self: *TestSuspendProcess = @ptrCast(@alignCast(ptr.?));
        self.kill_count += 1;
        self.last_kill_signal = signal;
        if (self.fail_kill) return error.SuspendFailed;
    }
};

fn expectSameSuspendCallback(expected: SuspendSignalCallback, actual: SuspendSignalCallback) !void {
    try std.testing.expectEqual(expected.ptr, actual.ptr);
    try std.testing.expect(expected.call_fn == actual.call_fn);
}

const TestStatusUi = struct {
    request_render_count: usize = 0,

    fn callbacks(self: *TestStatusUi) InteractiveStatusUi {
        return .{
            .ptr = self,
            .request_render_fn = requestRender,
        };
    }

    fn requestRender(ptr: ?*anyopaque) !void {
        const self: *TestStatusUi = @ptrCast(@alignCast(ptr.?));
        self.request_render_count += 1;
    }
};

const TestChatComponent = struct {
    label: []const u8,

    pub fn render(self: *TestChatComponent, allocator: std.mem.Allocator, _: usize) ![][]u8 {
        const lines = try allocator.alloc([]u8, 1);
        errdefer allocator.free(lines);
        lines[0] = try allocator.dupe(u8, self.label);
        return lines;
    }

    pub fn invalidate(_: *TestChatComponent) void {}
};

const TestToolExpansionUi = struct {
    request_render_count: usize = 0,

    fn callbacks(self: *TestToolExpansionUi) ToolExpansionUi {
        return .{
            .ptr = self,
            .request_render_fn = requestRender,
        };
    }

    fn requestRender(ptr: ?*anyopaque) !void {
        const self: *TestToolExpansionUi = @ptrCast(@alignCast(ptr.?));
        self.request_render_count += 1;
    }
};

const TestExpandableTarget = struct {
    set_count: usize = 0,
    last_expanded: ?bool = null,

    fn callbacks(self: *TestExpandableTarget) ToolExpansionTarget {
        return .{
            .ptr = self,
            .set_expanded_fn = setExpanded,
        };
    }

    fn setExpanded(ptr: ?*anyopaque, expanded: bool) !void {
        const self: *TestExpandableTarget = @ptrCast(@alignCast(ptr.?));
        self.set_count += 1;
        self.last_expanded = expanded;
    }
};

const TestAutocompleteRebuild = struct {
    count: usize = 0,

    fn callbacks(self: *TestAutocompleteRebuild) AutocompleteRebuildCallback {
        return .{
            .ptr = self,
            .call_fn = call,
        };
    }

    fn call(ptr: ?*anyopaque) !void {
        const self: *TestAutocompleteRebuild = @ptrCast(@alignCast(ptr.?));
        self.count += 1;
    }
};

const TestAutocompleteIdentityFactory = struct {
    fn factory() extension_types.AutocompleteProviderFactory {
        return .{ .wrap_fn = wrap };
    }

    fn wrap(_: ?*anyopaque, current: tui.AutocompleteProvider) !tui.AutocompleteProvider {
        return current;
    }
};

const TestBaseAutocompleteProviderFactory = struct {
    fn callbacks() BaseAutocompleteProviderFactory {
        return .{ .create_fn = create };
    }

    fn create(_: ?*anyopaque) !tui.AutocompleteProvider {
        return .{
            .get_suggestions_fn = getSuggestions,
            .apply_completion_fn = applyCompletion,
        };
    }

    fn getSuggestions(
        _: ?*anyopaque,
        _: std.mem.Allocator,
        _: []const []const u8,
        _: usize,
        _: usize,
        _: tui.autocomplete.SuggestionOptions,
    ) !?tui.AutocompleteSuggestions {
        return null;
    }

    fn applyCompletion(
        _: ?*anyopaque,
        allocator: std.mem.Allocator,
        lines: []const []const u8,
        cursor_line: usize,
        cursor_col: usize,
        _: tui.AutocompleteItem,
        _: []const u8,
    ) !tui.autocomplete.CompletionApplication {
        const cloned = try allocator.alloc([]u8, lines.len);
        var initialized: usize = 0;
        errdefer {
            for (cloned[0..initialized]) |line| allocator.free(line);
            allocator.free(cloned);
        }
        for (lines, 0..) |line, index| {
            cloned[index] = try allocator.dupe(u8, line);
            initialized += 1;
        }
        return .{
            .lines = cloned,
            .cursor_line = cursor_line,
            .cursor_col = cursor_col,
        };
    }
};

const TestAutocompleteEditor = struct {
    set_count: usize = 0,
    provider: ?tui.AutocompleteProvider = null,

    fn callbacks(self: *TestAutocompleteEditor) AutocompleteEditorTarget {
        return .{
            .ptr = self,
            .set_autocomplete_provider_fn = setAutocompleteProvider,
        };
    }

    fn setAutocompleteProvider(ptr: ?*anyopaque, provider: tui.AutocompleteProvider) !void {
        const self: *TestAutocompleteEditor = @ptrCast(@alignCast(ptr.?));
        self.set_count += 1;
        self.provider = provider;
    }
};

const TestAutocompleteTrace = struct {
    entries: [8][]const u8 = undefined,
    len: usize = 0,

    fn append(self: *TestAutocompleteTrace, entry: []const u8) void {
        self.entries[self.len] = entry;
        self.len += 1;
    }
};

const TestAutocompleteWrapper = struct {
    label: []const u8,
    trace: *TestAutocompleteTrace,
    current: ?tui.AutocompleteProvider = null,

    fn factory(self: *TestAutocompleteWrapper) extension_types.AutocompleteProviderFactory {
        return .{
            .ptr = self,
            .wrap_fn = wrap,
        };
    }

    fn wrap(ptr: ?*anyopaque, current: tui.AutocompleteProvider) !tui.AutocompleteProvider {
        const self: *TestAutocompleteWrapper = @ptrCast(@alignCast(ptr.?));
        self.current = current;
        return .{
            .context = self,
            .get_suggestions_fn = getSuggestions,
            .apply_completion_fn = applyCompletion,
            .should_trigger_file_completion_fn = shouldTriggerFileCompletion,
        };
    }

    fn getSuggestions(
        ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        lines: []const []const u8,
        cursor_line: usize,
        cursor_col: usize,
        options: tui.autocomplete.SuggestionOptions,
    ) !?tui.AutocompleteSuggestions {
        const self: *TestAutocompleteWrapper = @ptrCast(@alignCast(ptr.?));
        return try self.current.?.getSuggestions(allocator, lines, cursor_line, cursor_col, options);
    }

    fn applyCompletion(
        ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        lines: []const []const u8,
        cursor_line: usize,
        cursor_col: usize,
        item: tui.AutocompleteItem,
        prefix: []const u8,
    ) !tui.autocomplete.CompletionApplication {
        const self: *TestAutocompleteWrapper = @ptrCast(@alignCast(ptr.?));
        return try self.current.?.applyCompletion(allocator, lines, cursor_line, cursor_col, item, prefix);
    }

    fn shouldTriggerFileCompletion(
        ptr: ?*anyopaque,
        lines: []const []const u8,
        cursor_line: usize,
        cursor_col: usize,
    ) bool {
        const self: *TestAutocompleteWrapper = @ptrCast(@alignCast(ptr.?));
        self.trace.append(self.label);
        return self.current.?.shouldTriggerFileCompletion(lines, cursor_line, cursor_col);
    }
};

fn expectSameAutocompleteProvider(expected: tui.AutocompleteProvider, actual: tui.AutocompleteProvider) !void {
    try std.testing.expectEqual(expected.context, actual.context);
    try std.testing.expect(expected.get_suggestions_fn == actual.get_suggestions_fn);
    try std.testing.expect(expected.apply_completion_fn == actual.apply_completion_fn);
    try std.testing.expect(expected.should_trigger_file_completion_fn == actual.should_trigger_file_completion_fn);
}

const TestThemeSettings = struct {
    current_theme: []const u8 = "dark",
    set_count: usize = 0,
    last_set_theme: ?[]const u8 = null,

    fn callbacks(self: *TestThemeSettings) ExtensionThemeSettings {
        return .{
            .ptr = self,
            .get_theme_fn = getTheme,
            .set_theme_fn = setTheme,
        };
    }

    fn getTheme(ptr: ?*anyopaque) ?[]const u8 {
        const self: *TestThemeSettings = @ptrCast(@alignCast(ptr.?));
        return self.current_theme;
    }

    fn setTheme(ptr: ?*anyopaque, theme_name: []const u8) !void {
        const self: *TestThemeSettings = @ptrCast(@alignCast(ptr.?));
        self.current_theme = theme_name;
        self.last_set_theme = theme_name;
        self.set_count += 1;
    }
};

const TestExtensionThemeUi = struct {
    request_render_count: usize = 0,

    fn callbacks(self: *TestExtensionThemeUi) ExtensionThemeUi {
        return .{
            .ptr = self,
            .request_render_fn = requestRender,
        };
    }

    fn requestRender(ptr: ?*anyopaque) !void {
        const self: *TestExtensionThemeUi = @ptrCast(@alignCast(ptr.?));
        self.request_render_count += 1;
    }
};

const TestExtensionCustomComponent = struct {
    allocator: std.mem.Allocator,
    label: []const u8,
    focused: bool = false,
    inputs: std.ArrayList(u8) = .empty,
    text: std.ArrayList(u8) = .empty,

    fn init(allocator: std.mem.Allocator, label: []const u8) TestExtensionCustomComponent {
        return .{
            .allocator = allocator,
            .label = label,
        };
    }

    fn deinit(self: *TestExtensionCustomComponent) void {
        self.inputs.deinit(self.allocator);
        self.text.deinit(self.allocator);
    }

    fn component(self: *TestExtensionCustomComponent) tui.Component {
        return tui.Component.from(TestExtensionCustomComponent, self);
    }

    fn editorTextCallbacks(self: *TestExtensionCustomComponent) ExtensionCustomEditorText {
        return .{
            .ptr = self,
            .get_text_fn = getTextAlloc,
            .set_text_fn = setText,
        };
    }

    fn setTextForTest(self: *TestExtensionCustomComponent, value: []const u8) !void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.allocator, value);
    }

    pub fn render(self: *TestExtensionCustomComponent, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        _ = width;
        var lines = try allocator.alloc([]u8, 1);
        errdefer allocator.free(lines);
        lines[0] = try allocator.dupe(u8, self.label);
        return lines;
    }

    pub fn handleInput(self: *TestExtensionCustomComponent, _: std.mem.Allocator, data: []const u8) !void {
        try self.inputs.appendSlice(self.allocator, data);
    }

    pub fn invalidate(_: *TestExtensionCustomComponent) void {}

    fn getTextAlloc(ptr: ?*anyopaque, allocator: std.mem.Allocator) ![]u8 {
        const self: *TestExtensionCustomComponent = @ptrCast(@alignCast(ptr.?));
        return allocator.dupe(u8, self.text.items);
    }

    fn setText(ptr: ?*anyopaque, text: []const u8) !void {
        const self: *TestExtensionCustomComponent = @ptrCast(@alignCast(ptr.?));
        try self.setTextForTest(text);
    }
};

const TestCloneSessionManager = struct {
    leaf_id: ?[]const u8 = null,

    fn callbacks(self: *TestCloneSessionManager) CloneSessionManagerView {
        return .{
            .ptr = self,
            .get_leaf_id_fn = getLeafId,
        };
    }

    fn getLeafId(ptr: ?*anyopaque) ?[]const u8 {
        const self: *TestCloneSessionManager = @ptrCast(@alignCast(ptr.?));
        return self.leaf_id;
    }
};

const CloneForkCall = struct {
    entry_id: []u8,
    position: extension_types.ForkPosition,
};

const TestCloneRuntimeHost = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayList(CloneForkCall) = .empty,

    fn init(allocator: std.mem.Allocator) TestCloneRuntimeHost {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestCloneRuntimeHost) void {
        for (self.calls.items) |call| self.allocator.free(call.entry_id);
        self.calls.deinit(self.allocator);
        self.* = undefined;
    }

    fn callbacks(self: *TestCloneRuntimeHost) CloneRuntimeHost {
        return .{
            .ptr = self,
            .fork_fn = fork,
        };
    }

    fn fork(
        ptr: ?*anyopaque,
        entry_id: []const u8,
        options: extension_types.ForkOptions,
    ) !agent_session_runtime.SessionChangeResult {
        const self: *TestCloneRuntimeHost = @ptrCast(@alignCast(ptr.?));
        const entry_id_copy = try self.allocator.dupe(u8, entry_id);
        errdefer self.allocator.free(entry_id_copy);
        try self.calls.append(self.allocator, .{
            .entry_id = entry_id_copy,
            .position = options.position,
        });
        return .{};
    }
};

const TestCloneEditor = struct {
    allocator: std.mem.Allocator,
    texts: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator) TestCloneEditor {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestCloneEditor) void {
        freeMessageList(self.allocator, &self.texts);
        self.* = undefined;
    }

    fn callbacks(self: *TestCloneEditor) CloneCommandEditor {
        return .{
            .ptr = self,
            .set_text_fn = setText,
        };
    }

    fn setText(ptr: ?*anyopaque, text: []const u8) !void {
        const self: *TestCloneEditor = @ptrCast(@alignCast(ptr.?));
        const copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(copy);
        try self.texts.append(self.allocator, copy);
    }
};

const TestCloneUi = struct {
    allocator: std.mem.Allocator,
    statuses: std.ArrayList([]u8) = .empty,
    errors: std.ArrayList([]u8) = .empty,
    render_count: usize = 0,
    request_render_count: usize = 0,

    fn init(allocator: std.mem.Allocator) TestCloneUi {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestCloneUi) void {
        freeMessageList(self.allocator, &self.statuses);
        freeMessageList(self.allocator, &self.errors);
        self.* = undefined;
    }

    fn callbacks(self: *TestCloneUi) CloneCommandUi {
        return .{
            .ptr = self,
            .show_status_fn = showStatus,
            .show_error_fn = showError,
            .render_current_session_state_fn = renderCurrentSessionState,
            .request_render_fn = requestRender,
        };
    }

    fn appendMessage(self: *TestCloneUi, list: *std.ArrayList([]u8), message: []const u8) !void {
        const copy = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(copy);
        try list.append(self.allocator, copy);
    }

    fn showStatus(ptr: ?*anyopaque, message: []const u8) !void {
        const self: *TestCloneUi = @ptrCast(@alignCast(ptr.?));
        try self.appendMessage(&self.statuses, message);
    }

    fn showError(ptr: ?*anyopaque, message: []const u8) !void {
        const self: *TestCloneUi = @ptrCast(@alignCast(ptr.?));
        try self.appendMessage(&self.errors, message);
    }

    fn renderCurrentSessionState(ptr: ?*anyopaque) !void {
        const self: *TestCloneUi = @ptrCast(@alignCast(ptr.?));
        self.render_count += 1;
    }

    fn requestRender(ptr: ?*anyopaque) !void {
        const self: *TestCloneUi = @ptrCast(@alignCast(ptr.?));
        self.request_render_count += 1;
    }
};

const TestStartupEditor = struct {
    allocator: std.mem.Allocator,
    history: std.ArrayList([]u8) = .empty,
    texts: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator) TestStartupEditor {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestStartupEditor) void {
        freeMessageList(self.allocator, &self.history);
        freeMessageList(self.allocator, &self.texts);
        self.* = undefined;
    }

    fn callbacks(self: *TestStartupEditor) StartupSubmitEditor {
        return .{
            .ptr = self,
            .add_to_history_fn = addToHistory,
            .set_text_fn = setText,
        };
    }

    fn appendMessage(self: *TestStartupEditor, list: *std.ArrayList([]u8), message: []const u8) !void {
        const copy = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(copy);
        try list.append(self.allocator, copy);
    }

    fn addToHistory(ptr: ?*anyopaque, text: []const u8) !void {
        const self: *TestStartupEditor = @ptrCast(@alignCast(ptr.?));
        try self.appendMessage(&self.history, text);
    }

    fn setText(ptr: ?*anyopaque, text: []const u8) !void {
        const self: *TestStartupEditor = @ptrCast(@alignCast(ptr.?));
        try self.appendMessage(&self.texts, text);
    }
};

const TestStartupFlush = struct {
    count: usize = 0,

    fn callbacks(self: *TestStartupFlush) StartupFlushCallback {
        return .{
            .ptr = self,
            .call_fn = call,
        };
    }

    fn call(ptr: ?*anyopaque) !void {
        const self: *TestStartupFlush = @ptrCast(@alignCast(ptr.?));
        self.count += 1;
    }
};

const TestStartupInputCallback = struct {
    allocator: std.mem.Allocator,
    inputs: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator) TestStartupInputCallback {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestStartupInputCallback) void {
        freeMessageList(self.allocator, &self.inputs);
        self.* = undefined;
    }

    fn callbacks(self: *TestStartupInputCallback) StartupInputCallback {
        return .{
            .ptr = self,
            .call_fn = call,
        };
    }

    fn call(ptr: ?*anyopaque, text: []const u8) !void {
        const self: *TestStartupInputCallback = @ptrCast(@alignCast(ptr.?));
        const copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(copy);
        try self.inputs.append(self.allocator, copy);
    }
};

const ImportRuntimeScenario = enum {
    success,
    cancelled,
    missing_file,
    missing_cwd_once,
};

const ImportCall = struct {
    input_path: []u8,
    cwd_override: ?[]u8,
};

const TestImportRuntimeHost = struct {
    allocator: std.mem.Allocator,
    scenario: ImportRuntimeScenario,
    calls: std.ArrayList(ImportCall) = .empty,

    fn init(allocator: std.mem.Allocator, scenario: ImportRuntimeScenario) TestImportRuntimeHost {
        return .{
            .allocator = allocator,
            .scenario = scenario,
        };
    }

    fn deinit(self: *TestImportRuntimeHost) void {
        for (self.calls.items) |call| {
            self.allocator.free(call.input_path);
            if (call.cwd_override) |cwd_override| self.allocator.free(cwd_override);
        }
        self.calls.deinit(self.allocator);
        self.* = undefined;
    }

    fn callbacks(self: *TestImportRuntimeHost) ImportRuntimeHost {
        return .{
            .ptr = self,
            .import_from_jsonl_fn = importFromJsonl,
        };
    }

    fn importFromJsonl(
        ptr: ?*anyopaque,
        input_path: []const u8,
        cwd_override: ?[]const u8,
    ) !agent_session_runtime.SessionChangeResult {
        const self: *TestImportRuntimeHost = @ptrCast(@alignCast(ptr.?));
        const input_copy = try self.allocator.dupe(u8, input_path);
        var keep_call = false;
        errdefer if (!keep_call) self.allocator.free(input_copy);
        const cwd_copy = if (cwd_override) |cwd| try self.allocator.dupe(u8, cwd) else null;
        errdefer if (!keep_call) {
            if (cwd_copy) |cwd| self.allocator.free(cwd);
        };
        try self.calls.append(self.allocator, .{
            .input_path = input_copy,
            .cwd_override = cwd_copy,
        });
        keep_call = true;

        switch (self.scenario) {
            .success => return .{},
            .cancelled => return .{ .cancelled = true },
            .missing_file => return error.SessionImportFileNotFound,
            .missing_cwd_once => {
                if (self.calls.items.len == 1) return error.MissingSessionCwd;
                return .{};
            },
        }
    }
};

fn testSourceInfo(
    file_path: []const u8,
    source: []const u8,
    scope: source_info.SourceScope,
    origin: source_info.SourceOrigin,
    base_dir: ?[]const u8,
) LoadedResourceSourceInfo {
    return .{
        .path = file_path,
        .source = source,
        .scope = scope,
        .origin = origin,
        .base_dir = base_dir,
    };
}

fn renderContainerNormalizedAlloc(allocator: std.mem.Allocator, container: *tui.Container) ![]u8 {
    const lines = try container.render(allocator, 240);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    var filtered: std.ArrayList([]u8) = .empty;
    defer freeOwnedStringList(allocator, &filtered);
    for (lines) |line| {
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
        try filtered.append(allocator, try allocator.dupe(u8, trimRightAscii(line, " \t\r\n")));
    }
    return joinLinesAlloc(allocator, filtered.items);
}

fn expectRenderedContains(container: *tui.Container, needle: []const u8) !void {
    const allocator = std.testing.allocator;
    const output = try renderContainerNormalizedAlloc(allocator, container);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, needle) != null);
}

fn expectRenderedNotContains(container: *tui.Container, needle: []const u8) !void {
    const allocator = std.testing.allocator;
    const output = try renderContainerNormalizedAlloc(allocator, container);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, needle) == null);
}

fn trimRightAscii(value: []const u8, values_to_strip: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and std.mem.indexOfScalar(u8, values_to_strip, value[end - 1]) != null) {
        end -= 1;
    }
    return value[0..end];
}

// Ported from packages/coding-agent/test/interactive-mode-status.test.ts.
test "InteractiveMode showLoadedResources shows a compact resource listing by default" {
    const allocator = std.testing.allocator;
    var chat_container = tui.Container.init(allocator);
    defer chat_container.deinit();
    var controller = LoadedResourcesController.init(allocator, &chat_container);
    defer controller.deinit();

    const skills = [_]LoadedSkillResource{.{ .file_path = "/tmp/skill/SKILL.md", .name = "commit" }};
    try controller.showLoadedResources(.{ .skills = &skills }, .{
        .quiet_startup = false,
        .scope_groups_override = "resource-list",
    });

    try expectRenderedContains(&chat_container, "[Skills]");
    try expectRenderedContains(&chat_container, "commit");
    try expectRenderedNotContains(&chat_container, "resource-list");
}

test "InteractiveMode showLoadedResources shows full resource listing when expanded" {
    const allocator = std.testing.allocator;
    var chat_container = tui.Container.init(allocator);
    defer chat_container.deinit();
    var controller = LoadedResourcesController.init(allocator, &chat_container);
    defer controller.deinit();

    const skills = [_]LoadedSkillResource{.{ .file_path = "/tmp/skill/SKILL.md", .name = "commit" }};
    try controller.showLoadedResources(.{ .skills = &skills }, .{
        .quiet_startup = false,
        .tool_output_expanded = true,
        .scope_groups_override = "resource-list",
    });

    try expectRenderedContains(&chat_container, "[Skills]");
    try expectRenderedContains(&chat_container, "resource-list");
    try expectRenderedNotContains(&chat_container, "commit");
}

test "InteractiveMode showLoadedResources shows full resource listing on verbose startup even when tool output is collapsed" {
    const allocator = std.testing.allocator;
    var chat_container = tui.Container.init(allocator);
    defer chat_container.deinit();
    var controller = LoadedResourcesController.init(allocator, &chat_container);
    defer controller.deinit();

    const skills = [_]LoadedSkillResource{.{ .file_path = "/tmp/skill/SKILL.md", .name = "commit" }};
    try controller.showLoadedResources(.{ .skills = &skills }, .{
        .quiet_startup = true,
        .verbose = true,
        .tool_output_expanded = false,
        .scope_groups_override = "resource-list",
    });

    try expectRenderedContains(&chat_container, "[Skills]");
    try expectRenderedContains(&chat_container, "resource-list");
    try expectRenderedNotContains(&chat_container, "commit");
}

test "InteractiveMode showLoadedResources abbreviates extensions in compact listing" {
    const allocator = std.testing.allocator;
    var chat_container = tui.Container.init(allocator);
    defer chat_container.deinit();
    var controller = LoadedResourcesController.init(allocator, &chat_container);
    defer controller.deinit();

    const extensions = [_]LoadedResource{
        .{ .path = "/tmp/extensions/answer.ts" },
        .{ .path = "/tmp/extensions/btw.ts" },
    };
    try controller.showLoadedResources(.{ .extensions = &extensions }, .{ .quiet_startup = false });

    try expectRenderedContains(&chat_container, "[Extensions]");
    try expectRenderedContains(&chat_container, "answer.ts, btw.ts");
    try expectRenderedNotContains(&chat_container, "extensions/answer.ts");
}

test "InteractiveMode showLoadedResources captures mixed extension layouts in compact output" {
    const allocator = std.testing.allocator;
    var chat_container = tui.Container.init(allocator);
    defer chat_container.deinit();
    var controller = LoadedResourcesController.init(allocator, &chat_container);
    defer controller.deinit();

    const extensions = [_]LoadedResource{
        .{ .path = "/tmp/project/.bulb/extensions/answer.ts", .source_info = testSourceInfo("/tmp/project/.bulb/extensions/answer.ts", "local", .project, .top_level, "/tmp/project/.bulb/extensions") },
        .{ .path = "/tmp/project/.bulb/extensions/local-index/index.ts", .source_info = testSourceInfo("/tmp/project/.bulb/extensions/local-index/index.ts", "local", .project, .top_level, "/tmp/project/.bulb/extensions") },
        .{ .path = "/tmp/agent/extensions/user-index/index.ts", .source_info = testSourceInfo("/tmp/agent/extensions/user-index/index.ts", "local", .user, .top_level, "/tmp/agent/extensions") },
        .{ .path = "/tmp/project/.bulb/npm/node_modules/pi-markdown-preview/extensions/index.ts", .source_info = testSourceInfo("/tmp/project/.bulb/npm/node_modules/pi-markdown-preview/extensions/index.ts", "npm:pi-markdown-preview", .project, .package, "/tmp/project/.bulb/npm/node_modules/pi-markdown-preview") },
        .{ .path = "/tmp/project/.bulb/npm/node_modules/@scope/pi-scoped/extensions/index.ts", .source_info = testSourceInfo("/tmp/project/.bulb/npm/node_modules/@scope/pi-scoped/extensions/index.ts", "npm:@scope/pi-scoped", .project, .package, "/tmp/project/.bulb/npm/node_modules/@scope/pi-scoped") },
        .{ .path = "/tmp/project/.bulb/git/github.com/HazAT/pi-interactive-subagents/extensions/index.ts", .source_info = testSourceInfo("/tmp/project/.bulb/git/github.com/HazAT/pi-interactive-subagents/extensions/index.ts", "git:github.com/HazAT/pi-interactive-subagents", .project, .package, "/tmp/project/.bulb/git/github.com/HazAT/pi-interactive-subagents") },
        .{ .path = "/tmp/project/.bulb/git/github.com/HazAT/pi-interactive-subagents/extensions/subagents/index.ts", .source_info = testSourceInfo("/tmp/project/.bulb/git/github.com/HazAT/pi-interactive-subagents/extensions/subagents/index.ts", "git:github.com/HazAT/pi-interactive-subagents", .project, .package, "/tmp/project/.bulb/git/github.com/HazAT/pi-interactive-subagents") },
        .{ .path = "/tmp/temp/cli-extension.ts", .source_info = testSourceInfo("/tmp/temp/cli-extension.ts", "cli", .temporary, .top_level, "/tmp/temp") },
    };
    try controller.showLoadedResources(.{ .extensions = &extensions }, .{ .quiet_startup = false });

    const output = try renderContainerNormalizedAlloc(allocator, &chat_container);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(
        "[Extensions]\n  @scope/pi-scoped, answer.ts, cli-extension.ts, HazAT/pi-interactive-subagents, HazAT/pi-interactive-subagents:subagents, local-index, pi-markdown-preview, user-index",
        output,
    );
}

test "InteractiveMode showLoadedResources adds more parent folders until local extension labels are unique" {
    const allocator = std.testing.allocator;
    var chat_container = tui.Container.init(allocator);
    defer chat_container.deinit();
    var controller = LoadedResourcesController.init(allocator, &chat_container);
    defer controller.deinit();

    const extensions = [_]LoadedResource{
        .{ .path = "/tmp/alpha/one/index.ts", .source_info = testSourceInfo("/tmp/alpha/one/index.ts", "cli", .temporary, .top_level, "/tmp/alpha") },
        .{ .path = "/tmp/beta/one/index.ts", .source_info = testSourceInfo("/tmp/beta/one/index.ts", "cli", .temporary, .top_level, "/tmp/beta") },
        .{ .path = "/tmp/gamma/one/index.ts", .source_info = testSourceInfo("/tmp/gamma/one/index.ts", "cli", .temporary, .top_level, "/tmp/gamma") },
    };
    try controller.showLoadedResources(.{ .extensions = &extensions }, .{ .quiet_startup = false });

    const output = try renderContainerNormalizedAlloc(allocator, &chat_container);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("[Extensions]\n  alpha/one, beta/one, gamma/one", output);
}

test "InteractiveMode showLoadedResources strips index files from local extension labels" {
    const allocator = std.testing.allocator;
    var chat_container = tui.Container.init(allocator);
    defer chat_container.deinit();
    var controller = LoadedResourcesController.init(allocator, &chat_container);
    defer controller.deinit();

    const extensions = [_]LoadedResource{
        .{ .path = "/tmp/extensions/plan-mode/index.ts", .source_info = testSourceInfo("/tmp/extensions/plan-mode/index.ts", "local", .project, .top_level, "/tmp/extensions") },
        .{ .path = "/tmp/extensions/legacy-mode/index.js", .source_info = testSourceInfo("/tmp/extensions/legacy-mode/index.js", "local", .project, .top_level, "/tmp/extensions") },
        .{ .path = "/tmp/extensions/webfetch.ts", .source_info = testSourceInfo("/tmp/extensions/webfetch.ts", "local", .project, .top_level, "/tmp/extensions") },
    };
    try controller.showLoadedResources(.{ .extensions = &extensions }, .{ .quiet_startup = false });

    const output = try renderContainerNormalizedAlloc(allocator, &chat_container);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("[Extensions]\n  legacy-mode, plan-mode, webfetch.ts", output);
}

test "InteractiveMode showLoadedResources disambiguates repeated index parent directories" {
    const allocator = std.testing.allocator;
    var chat_container = tui.Container.init(allocator);
    defer chat_container.deinit();
    var controller = LoadedResourcesController.init(allocator, &chat_container);
    defer controller.deinit();

    const extensions = [_]LoadedResource{
        .{ .path = "/tmp/alpha/tools/index.ts", .source_info = testSourceInfo("/tmp/alpha/tools/index.ts", "cli", .temporary, .top_level, "/tmp/alpha") },
        .{ .path = "/tmp/beta/tools/index.ts", .source_info = testSourceInfo("/tmp/beta/tools/index.ts", "cli", .temporary, .top_level, "/tmp/beta") },
    };
    try controller.showLoadedResources(.{ .extensions = &extensions }, .{ .quiet_startup = false });

    const output = try renderContainerNormalizedAlloc(allocator, &chat_container);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("[Extensions]\n  alpha/tools, beta/tools", output);
}

test "InteractiveMode showLoadedResources keeps non-index file names and package extension labels" {
    const allocator = std.testing.allocator;
    var chat_container = tui.Container.init(allocator);
    defer chat_container.deinit();
    var controller = LoadedResourcesController.init(allocator, &chat_container);
    defer controller.deinit();

    const extensions = [_]LoadedResource{
        .{ .path = "/tmp/extensions/my-ext/main.ts", .source_info = testSourceInfo("/tmp/extensions/my-ext/main.ts", "local", .project, .top_level, "/tmp/extensions") },
        .{ .path = "/tmp/project/.bulb/npm/node_modules/pi-markdown-preview/extensions/index.ts", .source_info = testSourceInfo("/tmp/project/.bulb/npm/node_modules/pi-markdown-preview/extensions/index.ts", "npm:pi-markdown-preview", .project, .package, "/tmp/project/.bulb/npm/node_modules/pi-markdown-preview") },
    };
    try controller.showLoadedResources(.{ .extensions = &extensions }, .{ .quiet_startup = false });

    const output = try renderContainerNormalizedAlloc(allocator, &chat_container);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("[Extensions]\n  main.ts, pi-markdown-preview", output);
}

test "InteractiveMode showLoadedResources captures mixed extension layouts in expanded output" {
    const allocator = std.testing.allocator;
    var chat_container = tui.Container.init(allocator);
    defer chat_container.deinit();
    var controller = LoadedResourcesController.init(allocator, &chat_container);
    defer controller.deinit();

    const extensions = [_]LoadedResource{
        .{ .path = "/tmp/project/.bulb/extensions/answer.ts", .source_info = testSourceInfo("/tmp/project/.bulb/extensions/answer.ts", "local", .project, .top_level, "/tmp/project/.bulb/extensions") },
        .{ .path = "/tmp/project/.bulb/extensions/local-index/index.ts", .source_info = testSourceInfo("/tmp/project/.bulb/extensions/local-index/index.ts", "local", .project, .top_level, "/tmp/project/.bulb/extensions") },
        .{ .path = "/tmp/agent/extensions/user-index/index.ts", .source_info = testSourceInfo("/tmp/agent/extensions/user-index/index.ts", "local", .user, .top_level, "/tmp/agent/extensions") },
        .{ .path = "/tmp/project/.bulb/npm/node_modules/pi-markdown-preview/extensions/index.ts", .source_info = testSourceInfo("/tmp/project/.bulb/npm/node_modules/pi-markdown-preview/extensions/index.ts", "npm:pi-markdown-preview", .project, .package, "/tmp/project/.bulb/npm/node_modules/pi-markdown-preview") },
        .{ .path = "/tmp/project/.bulb/npm/node_modules/@scope/pi-scoped/extensions/index.ts", .source_info = testSourceInfo("/tmp/project/.bulb/npm/node_modules/@scope/pi-scoped/extensions/index.ts", "npm:@scope/pi-scoped", .project, .package, "/tmp/project/.bulb/npm/node_modules/@scope/pi-scoped") },
        .{ .path = "/tmp/project/.bulb/git/github.com/HazAT/pi-interactive-subagents/extensions/index.ts", .source_info = testSourceInfo("/tmp/project/.bulb/git/github.com/HazAT/pi-interactive-subagents/extensions/index.ts", "git:github.com/HazAT/pi-interactive-subagents", .project, .package, "/tmp/project/.bulb/git/github.com/HazAT/pi-interactive-subagents") },
        .{ .path = "/tmp/project/.bulb/git/github.com/HazAT/pi-interactive-subagents/extensions/subagents/index.ts", .source_info = testSourceInfo("/tmp/project/.bulb/git/github.com/HazAT/pi-interactive-subagents/extensions/subagents/index.ts", "git:github.com/HazAT/pi-interactive-subagents", .project, .package, "/tmp/project/.bulb/git/github.com/HazAT/pi-interactive-subagents") },
        .{ .path = "/tmp/temp/cli-extension.ts", .source_info = testSourceInfo("/tmp/temp/cli-extension.ts", "cli", .temporary, .top_level, "/tmp/temp") },
    };
    try controller.showLoadedResources(.{ .extensions = &extensions }, .{
        .quiet_startup = false,
        .tool_output_expanded = true,
    });

    const output = try renderContainerNormalizedAlloc(allocator, &chat_container);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(
        "[Extensions]\n  project\n    /tmp/project/.bulb/extensions/answer.ts\n    /tmp/project/.bulb/extensions/local-index\n    git:github.com/HazAT/pi-interactive-subagents\n      extensions\n      extensions/subagents\n    npm:@scope/pi-scoped\n      extensions\n    npm:pi-markdown-preview\n      extensions\n  user\n    /tmp/agent/extensions/user-index\n  path\n    /tmp/temp/cli-extension.ts",
        output,
    );
}

test "InteractiveMode showLoadedResources formats context paths compactly and fully when expanded" {
    const allocator = std.testing.allocator;
    const home = "/Users/example";
    const cwd = try std.fs.path.join(allocator, &.{ home, "Development", "bulb-mono" });
    defer allocator.free(cwd);
    const global_agents = try std.fs.path.join(allocator, &.{ home, ".bulb", "agent", "AGENTS.md" });
    defer allocator.free(global_agents);
    const project_agents = try std.fs.path.join(allocator, &.{ cwd, "AGENTS.md" });
    defer allocator.free(project_agents);

    const context_files = [_]LoadedContextFile{
        .{ .path = global_agents },
        .{ .path = project_agents },
    };

    {
        var chat_container = tui.Container.init(allocator);
        defer chat_container.deinit();
        var controller = LoadedResourcesController.init(allocator, &chat_container);
        defer controller.deinit();
        try controller.showLoadedResources(.{ .context_files = &context_files }, .{
            .quiet_startup = false,
            .cwd = cwd,
            .home_dir = home,
        });
        const output = try renderContainerNormalizedAlloc(allocator, &chat_container);
        defer allocator.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "[Context]") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "~/.bulb/agent/AGENTS.md, AGENTS.md") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, project_agents) == null);
    }

    {
        var chat_container = tui.Container.init(allocator);
        defer chat_container.deinit();
        var controller = LoadedResourcesController.init(allocator, &chat_container);
        defer controller.deinit();
        try controller.showLoadedResources(.{ .context_files = &context_files }, .{
            .quiet_startup = false,
            .tool_output_expanded = true,
            .cwd = cwd,
            .home_dir = home,
        });
        const output = try renderContainerNormalizedAlloc(allocator, &chat_container);
        defer allocator.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "~/.bulb/agent/AGENTS.md") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "~/Development/bulb-mono/AGENTS.md") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "~/.bulb/agent/AGENTS.md, AGENTS.md") == null);
    }
}

test "InteractiveMode showLoadedResources honors quiet startup and diagnostics override" {
    const allocator = std.testing.allocator;
    const skills = [_]LoadedSkillResource{.{ .file_path = "/tmp/skill/SKILL.md", .name = "commit" }};

    {
        var chat_container = tui.Container.init(allocator);
        defer chat_container.deinit();
        var controller = LoadedResourcesController.init(allocator, &chat_container);
        defer controller.deinit();
        try controller.showLoadedResources(.{ .skills = &skills }, .{
            .quiet_startup = true,
            .show_diagnostics_when_quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 0), chat_container.children.items.len);
    }

    {
        var chat_container = tui.Container.init(allocator);
        defer chat_container.deinit();
        var controller = LoadedResourcesController.init(allocator, &chat_container);
        defer controller.deinit();
        var diagnostic = try resource_loader.ResourceDiagnostic.initAlloc(allocator, .warning, "duplicate skill name", "", null);
        defer diagnostic.deinit();
        const diagnostics = [_]resource_loader.ResourceDiagnostic{diagnostic};
        try controller.showLoadedResources(.{
            .skills = &skills,
            .skill_diagnostics = &diagnostics,
        }, .{
            .quiet_startup = true,
            .show_diagnostics_when_quiet = true,
        });
        try expectRenderedContains(&chat_container, "[Skill conflicts]");
        try expectRenderedContains(&chat_container, "duplicate skill name");
        try expectRenderedNotContains(&chat_container, "[Skills]");
    }
}

test "InteractiveMode showStatus coalesces immediately-sequential status messages" {
    const allocator = std.testing.allocator;
    var chat_container = tui.Container.init(allocator);
    defer chat_container.deinit();
    var ui = TestStatusUi{};
    var controller = InteractiveStatusController.init(allocator, &chat_container, ui.callbacks());
    defer controller.deinit();

    try controller.showStatus("STATUS_ONE");
    try std.testing.expectEqual(@as(usize, 2), chat_container.children.items.len);
    try std.testing.expectEqualStrings("STATUS_ONE", controller.last_status_text.?.text);

    try controller.showStatus("STATUS_TWO");
    try std.testing.expectEqual(@as(usize, 2), chat_container.children.items.len);
    try std.testing.expectEqualStrings("STATUS_TWO", controller.last_status_text.?.text);
    try std.testing.expect(std.mem.indexOf(u8, controller.last_status_text.?.text, "STATUS_ONE") == null);
    try std.testing.expectEqual(@as(usize, 2), ui.request_render_count);
}

test "InteractiveMode showStatus appends a new status line if something else was added in between" {
    const allocator = std.testing.allocator;
    var chat_container = tui.Container.init(allocator);
    defer chat_container.deinit();
    var ui = TestStatusUi{};
    var controller = InteractiveStatusController.init(allocator, &chat_container, ui.callbacks());
    defer controller.deinit();

    try controller.showStatus("STATUS_ONE");
    try std.testing.expectEqual(@as(usize, 2), chat_container.children.items.len);

    var other = TestChatComponent{ .label = "OTHER" };
    try chat_container.addChild(tui.Component.from(TestChatComponent, &other));
    try std.testing.expectEqual(@as(usize, 3), chat_container.children.items.len);

    try controller.showStatus("STATUS_TWO");
    try std.testing.expectEqual(@as(usize, 5), chat_container.children.items.len);
    try std.testing.expectEqualStrings("STATUS_TWO", controller.last_status_text.?.text);
}

test "InteractiveMode setToolsExpanded applies expansion state to the active header and chat entries" {
    var tool_output_expanded = false;
    var header = TestExpandableTarget{};
    var chat_child = TestExpandableTarget{};
    var ui = TestToolExpansionUi{};
    const chat_children = [_]ToolExpansionTarget{chat_child.callbacks()};

    try setToolsExpanded(.{
        .tool_output_expanded = &tool_output_expanded,
        .built_in_header = header.callbacks(),
        .chat_children = &chat_children,
        .ui = ui.callbacks(),
    }, true);

    try std.testing.expectEqual(true, tool_output_expanded);
    try std.testing.expectEqual(@as(usize, 1), header.set_count);
    try std.testing.expectEqual(true, header.last_expanded.?);
    try std.testing.expectEqual(@as(usize, 1), chat_child.set_count);
    try std.testing.expectEqual(true, chat_child.last_expanded.?);
    try std.testing.expectEqual(@as(usize, 1), ui.request_render_count);
}

test "InteractiveMode addAutocompleteProvider stores wrapper factories and rebuilds autocomplete immediately" {
    const allocator = std.testing.allocator;
    var wrappers: std.ArrayList(extension_types.AutocompleteProviderFactory) = .empty;
    defer wrappers.deinit(allocator);
    var rebuild = TestAutocompleteRebuild{};
    const wrapper = TestAutocompleteIdentityFactory.factory();

    try addAutocompleteProviderWrapper(allocator, &wrappers, wrapper, rebuild.callbacks());

    try std.testing.expectEqual(@as(usize, 1), wrappers.items.len);
    try std.testing.expect(wrappers.items[0].wrap_fn == wrapper.wrap_fn);
    try std.testing.expectEqual(@as(usize, 1), rebuild.count);
}

test "InteractiveMode setupAutocompleteProvider stacks wrapper factories over a fresh base provider" {
    var default_editor = TestAutocompleteEditor{};
    var custom_editor = TestAutocompleteEditor{};
    var trace = TestAutocompleteTrace{};
    var wrap1 = TestAutocompleteWrapper{ .label = "shouldTrigger:wrap1", .trace = &trace };
    var wrap2 = TestAutocompleteWrapper{ .label = "shouldTrigger:wrap2", .trace = &trace };
    const wrappers = [_]extension_types.AutocompleteProviderFactory{
        wrap1.factory(),
        wrap2.factory(),
    };
    var current_provider: ?tui.AutocompleteProvider = null;

    try setupAutocompleteProvider(.{
        .autocomplete_provider = &current_provider,
        .create_base_provider = TestBaseAutocompleteProviderFactory.callbacks(),
        .default_editor = default_editor.callbacks(),
        .editor = custom_editor.callbacks(),
        .wrappers = &wrappers,
    });

    try std.testing.expect(current_provider != null);
    try std.testing.expectEqual(@as(usize, 1), default_editor.set_count);
    try std.testing.expectEqual(@as(usize, 1), custom_editor.set_count);
    try expectSameAutocompleteProvider(default_editor.provider.?, custom_editor.provider.?);
    try expectSameAutocompleteProvider(current_provider.?, default_editor.provider.?);

    const lines = [_][]const u8{"foo"};
    try std.testing.expect(default_editor.provider.?.shouldTriggerFileCompletion(&lines, 0, 3));
    try std.testing.expectEqual(@as(usize, 2), trace.len);
    try std.testing.expectEqualStrings("shouldTrigger:wrap2", trace.entries[0]);
    try std.testing.expectEqualStrings("shouldTrigger:wrap1", trace.entries[1]);
}

test "InteractiveMode createExtensionUIContext setTheme persists theme changes to settings manager" {
    var settings = TestThemeSettings{ .current_theme = "dark" };
    var ui = TestExtensionThemeUi{};

    const result = try setExtensionTheme(.{
        .settings = settings.callbacks(),
        .ui = ui.callbacks(),
    }, "light");

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 1), settings.set_count);
    try std.testing.expectEqualStrings("light", settings.last_set_theme.?);
    try std.testing.expectEqualStrings("light", settings.current_theme);
    try std.testing.expectEqual(@as(usize, 1), ui.request_render_count);
}

test "InteractiveMode createExtensionUIContext setTheme does not persist invalid theme names" {
    var settings = TestThemeSettings{ .current_theme = "dark" };
    var ui = TestExtensionThemeUi{};

    const result = try setExtensionTheme(.{
        .settings = settings.callbacks(),
        .ui = ui.callbacks(),
    }, "__missing_theme__");

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(usize, 0), settings.set_count);
    try std.testing.expectEqualStrings("dark", settings.current_theme);
    try std.testing.expectEqual(@as(usize, 0), ui.request_render_count);
}

test "InteractiveMode showExtensionCustom overlay custom UI reclaims input after non-overlay custom UI closes" {
    const allocator = std.testing.allocator;
    var virtual_terminal = tui.VirtualTerminal.init(allocator, 80, 24);
    defer virtual_terminal.deinit();
    var ui = tui.TUI.init(allocator, virtual_terminal.asTerminal());
    defer ui.deinit();
    var editor_container = tui.Container.init(allocator);
    defer editor_container.deinit();
    var editor = TestExtensionCustomComponent.init(allocator, "EDITOR");
    defer editor.deinit();
    var palette = TestExtensionCustomComponent.init(allocator, "PALETTE");
    defer palette.deinit();
    var overlay = TestExtensionCustomComponent.init(allocator, "OVERLAY");
    defer overlay.deinit();
    var replacement = TestExtensionCustomComponent.init(allocator, "REPLACEMENT");
    defer replacement.deinit();

    try editor.setTextForTest("draft prompt");
    try editor_container.addChild(editor.component());
    try ui.addChild(tui.Component.from(tui.Container, &editor_container));
    try ui.addChild(palette.component());
    ui.setFocus(palette.component());
    try ui.start();
    defer ui.stop() catch {};

    const context = ExtensionCustomContext{
        .ui = &ui,
        .editor_container = &editor_container,
        .editor = editor.component(),
        .editor_text = editor.editorTextCallbacks(),
    };

    var overlay_handle = try showExtensionCustom(
        allocator,
        context,
        .{ .component = overlay.component() },
        .{ .overlay = true },
    );
    defer overlay_handle.deinit();
    try ui.requestRender(true);
    try std.testing.expect(overlay.focused);

    var replacement_handle = try showExtensionCustom(
        allocator,
        context,
        .{ .component = replacement.component() },
        .{},
    );
    defer replacement_handle.deinit();
    try ui.requestRender(true);
    try std.testing.expect(replacement.focused);

    try replacement_handle.close();
    try ui.requestRender(true);
    virtual_terminal.sendInput("x");
    try ui.requestRender(true);

    try std.testing.expectEqualStrings("x", overlay.inputs.items);
    try std.testing.expectEqualStrings("", editor.inputs.items);
    try std.testing.expect(overlay.focused);
    try std.testing.expectEqualStrings("draft prompt", editor.text.items);

    try overlay_handle.close();
}

// Ported from packages/coding-agent/test/interactive-mode-suspend.test.ts.
test "InteractiveMode handleCtrlZ shows a status message and skips suspend on Windows" {
    const allocator = std.testing.allocator;
    var ui = TestSuspendUi.init(allocator);
    defer ui.deinit();
    var process = TestSuspendProcess{ .platform_value = .windows };

    try handleCtrlZ(allocator, .{
        .ui = ui.callbacks(),
        .process = process.callbacks(),
    });

    try std.testing.expectEqual(@as(usize, 1), ui.statuses.items.len);
    try std.testing.expectEqualStrings("Suspend to background is not supported on Windows", ui.statuses.items[0]);
    try std.testing.expectEqual(@as(usize, 0), ui.stop_count);
    try std.testing.expectEqual(@as(usize, 0), process.set_interval_count);
    try std.testing.expectEqual(@as(usize, 0), process.on_sigint_count);
    try std.testing.expectEqual(@as(usize, 0), process.once_sigcont_count);
    try std.testing.expectEqual(@as(usize, 0), process.kill_count);
}

test "InteractiveMode handleCtrlZ keeps the process alive while suspended and restores the TUI on SIGCONT" {
    const allocator = std.testing.allocator;
    var ui = TestSuspendUi.init(allocator);
    defer ui.deinit();
    var process = TestSuspendProcess{ .platform_value = .posix };

    try handleCtrlZ(allocator, .{
        .ui = ui.callbacks(),
        .process = process.callbacks(),
    });

    try std.testing.expectEqual(@as(usize, 1), process.set_interval_count);
    try std.testing.expectEqual(suspend_keep_alive_interval_ms, process.last_interval_ms.?);
    try std.testing.expectEqual(@as(usize, 1), process.on_sigint_count);
    try std.testing.expectEqual(@as(usize, 1), process.once_sigcont_count);
    try std.testing.expectEqual(@as(usize, 1), ui.stop_count);
    try std.testing.expectEqual(@as(usize, 1), process.kill_count);
    try std.testing.expectEqual(SuspendSignal.sigtstp, process.last_kill_signal.?);
    try std.testing.expect(process.sigint_callback != null);
    try std.testing.expect(process.sigcont_callback != null);

    try process.sigcont_callback.?.call();

    try std.testing.expectEqual(@as(usize, 1), process.clear_interval_count);
    try std.testing.expectEqual(@as(usize, 42), process.last_clear_handle.?.id);
    try std.testing.expectEqual(@as(usize, 1), process.remove_sigint_count);
    try expectSameSuspendCallback(process.sigint_callback.?, process.removed_sigint_callback.?);
    try std.testing.expectEqual(@as(usize, 1), ui.start_count);
    try std.testing.expectEqual(@as(usize, 1), ui.request_render_count);
    try std.testing.expectEqual(true, ui.last_request_render_force.?);
}

test "InteractiveMode handleCtrlZ cleans up temporary handlers if suspension fails" {
    const allocator = std.testing.allocator;
    var ui = TestSuspendUi.init(allocator);
    defer ui.deinit();
    var process = TestSuspendProcess{
        .platform_value = .posix,
        .fail_kill = true,
    };

    try std.testing.expectError(error.SuspendFailed, handleCtrlZ(allocator, .{
        .ui = ui.callbacks(),
        .process = process.callbacks(),
    }));

    try std.testing.expectEqual(@as(usize, 1), ui.stop_count);
    try std.testing.expectEqual(@as(usize, 1), process.set_interval_count);
    try std.testing.expectEqual(@as(usize, 1), process.clear_interval_count);
    try std.testing.expectEqual(@as(usize, 42), process.last_clear_handle.?.id);
    try std.testing.expectEqual(@as(usize, 1), process.remove_sigint_count);
    try expectSameSuspendCallback(process.sigint_callback.?, process.removed_sigint_callback.?);
    try std.testing.expectEqual(@as(usize, 0), ui.start_count);
    try std.testing.expectEqual(@as(usize, 0), ui.request_render_count);
}

// Ported from packages/coding-agent/test/interactive-mode-compaction.test.ts.
test "InteractiveMode compaction events rebuilds chat and appends a synthetic summary at the bottom" {
    const allocator = std.testing.allocator;
    var ui = TestInteractiveEventUi.init(allocator);
    defer ui.deinit();

    try handleInteractiveModeEvent(std.testing.io, .{
        .ui = ui.callbacks(),
    }, .{ .compaction_end = .{
        .reason = .manual,
        .result = .{
            .summary = "summary",
            .first_kept_entry_id = "kept-entry",
            .tokens_before = 123,
        },
        .aborted = false,
        .will_retry = false,
    } });

    try std.testing.expectEqual(@as(usize, 1), ui.clear_chat_count);
    try std.testing.expectEqual(@as(usize, 1), ui.rebuild_chat_count);
    try std.testing.expectEqual(@as(usize, 1), ui.messages.items.len);
    const summary = switch (ui.messages.items[0]) {
        .compaction_summary => |message| message,
        else => return error.ExpectedCompactionSummaryMessage,
    };
    try std.testing.expectEqualStrings("summary", summary.summary);
    try std.testing.expectEqual(@as(u64, 123), summary.tokens_before);
    try std.testing.expect(summary.timestamp_ms > 0);
    try std.testing.expectEqual(@as(usize, 1), ui.flush_will_retry_values.items.len);
    try std.testing.expectEqual(false, ui.flush_will_retry_values.items[0]);
}

// Ported from packages/coding-agent/test/interactive-mode-anthropic-warning.test.ts.
test "InteractiveMode maybeWarnAboutAnthropicSubscriptionAuth warns once when subscription auth is detected" {
    const allocator = std.testing.allocator;
    var state = AnthropicSubscriptionWarningState{};
    var registry = TestAnthropicWarningRegistry{ .api_key = "sk-ant-oat01-test" };
    var ui = TestAnthropicWarningUi.init(allocator);
    defer ui.deinit();

    const context = AnthropicWarningContext{
        .state = &state,
        .model_registry = registry.callbacks(),
        .ui = ui.callbacks(),
    };
    try maybeWarnAboutAnthropicSubscriptionAuth(allocator, context, .{ .provider = "anthropic" });
    try maybeWarnAboutAnthropicSubscriptionAuth(allocator, context, .{ .provider = "anthropic" });

    try std.testing.expectEqual(@as(usize, 1), ui.warnings.items.len);
    try std.testing.expectEqualStrings(anthropic_subscription_auth_warning, ui.warnings.items[0]);
    try std.testing.expectEqual(@as(usize, 1), registry.get_api_key_count);
}

test "InteractiveMode maybeWarnAboutAnthropicSubscriptionAuth warns for stored Anthropic OAuth without token lookup" {
    const allocator = std.testing.allocator;
    var state = AnthropicSubscriptionWarningState{};
    var registry = TestAnthropicWarningRegistry{ .stored_auth_type = .oauth };
    var ui = TestAnthropicWarningUi.init(allocator);
    defer ui.deinit();

    try maybeWarnAboutAnthropicSubscriptionAuth(allocator, .{
        .state = &state,
        .model_registry = registry.callbacks(),
        .ui = ui.callbacks(),
    }, .{ .provider = "anthropic" });

    try std.testing.expectEqual(@as(usize, 1), ui.warnings.items.len);
    try std.testing.expectEqualStrings(anthropic_subscription_auth_warning, ui.warnings.items[0]);
    try std.testing.expectEqual(@as(usize, 0), registry.get_api_key_count);
}

test "InteractiveMode maybeWarnAboutAnthropicSubscriptionAuth does not warn for non-Anthropic models" {
    const allocator = std.testing.allocator;
    var state = AnthropicSubscriptionWarningState{};
    var registry = TestAnthropicWarningRegistry{};
    var ui = TestAnthropicWarningUi.init(allocator);
    defer ui.deinit();

    try maybeWarnAboutAnthropicSubscriptionAuth(allocator, .{
        .state = &state,
        .model_registry = registry.callbacks(),
        .ui = ui.callbacks(),
    }, .{ .provider = "openai" });

    try std.testing.expectEqual(@as(usize, 0), ui.warnings.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.get_stored_auth_type_count);
    try std.testing.expectEqual(@as(usize, 0), registry.get_api_key_count);
}

test "InteractiveMode maybeWarnAboutAnthropicSubscriptionAuth honors disabled extra usage warning" {
    const allocator = std.testing.allocator;
    var state = AnthropicSubscriptionWarningState{};
    var registry = TestAnthropicWarningRegistry{ .api_key = "sk-ant-oat01-test" };
    var ui = TestAnthropicWarningUi.init(allocator);
    defer ui.deinit();

    try maybeWarnAboutAnthropicSubscriptionAuth(allocator, .{
        .state = &state,
        .settings = .{ .anthropic_extra_usage = false },
        .model_registry = registry.callbacks(),
        .ui = ui.callbacks(),
    }, .{ .provider = "anthropic" });

    try std.testing.expectEqual(@as(usize, 0), ui.warnings.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.get_stored_auth_type_count);
    try std.testing.expectEqual(@as(usize, 0), registry.get_api_key_count);
}

// Ported from packages/coding-agent/test/interactive-mode-import-command.test.ts.
test "InteractiveMode /import parsing strips quotes from path arguments" {
    try std.testing.expectEqualStrings(
        "path/to/session.jsonl",
        getPathCommandArgument("/import \"path/to/session.jsonl\"", "/import").?,
    );
    try std.testing.expectEqualStrings(
        "path with spaces/session.jsonl",
        getPathCommandArgument("/import \"path with spaces/session.jsonl\"", "/import").?,
    );
}

test "InteractiveMode /import parsing preserves apostrophes in unquoted path arguments" {
    try std.testing.expectEqualStrings(
        "john's/session.jsonl",
        getPathCommandArgument("/import john's/session.jsonl", "/import").?,
    );
}

test "InteractiveMode path command parsing enforces command token boundaries" {
    try std.testing.expect(getPathCommandArgument("/important /tmp/session.jsonl", "/import") == null);
    try std.testing.expect(getPathCommandArgument("/exporter out.html", "/export") == null);
    try std.testing.expectEqualStrings(
        "/tmp/session.jsonl",
        getPathCommandArgument("/import /tmp/session.jsonl", "/import").?,
    );
}

test "InteractiveMode handleImportCommand passes unquoted path to runtime host" {
    const allocator = std.testing.allocator;
    var ui = TestImportUi.init(allocator);
    defer ui.deinit();
    var runtime = TestImportRuntimeHost.init(allocator, .success);
    defer runtime.deinit();

    try handleImportCommand(allocator, .{
        .runtime_host = runtime.callbacks(),
        .ui = ui.callbacks(),
    }, "/import \"path/to/session.jsonl\"");

    try std.testing.expectEqual(@as(usize, 1), ui.confirm_titles.items.len);
    try std.testing.expectEqualStrings("Import session", ui.confirm_titles.items[0]);
    try std.testing.expectEqualStrings("Replace current session with path/to/session.jsonl?", ui.confirm_messages.items[0]);
    try std.testing.expectEqual(@as(usize, 1), runtime.calls.items.len);
    try std.testing.expectEqualStrings("path/to/session.jsonl", runtime.calls.items[0].input_path);
    try std.testing.expect(runtime.calls.items[0].cwd_override == null);
    try std.testing.expectEqual(@as(usize, 0), ui.errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), ui.statuses.items.len);
    try std.testing.expectEqualStrings("Session imported from: path/to/session.jsonl", ui.statuses.items[0]);
    try std.testing.expectEqual(@as(usize, 1), ui.clear_count);
    try std.testing.expectEqual(@as(usize, 1), ui.render_count);
}

test "InteractiveMode handleImportCommand preserves unquoted apostrophe paths" {
    const allocator = std.testing.allocator;
    var ui = TestImportUi.init(allocator);
    defer ui.deinit();
    var runtime = TestImportRuntimeHost.init(allocator, .success);
    defer runtime.deinit();

    try handleImportCommand(allocator, .{
        .runtime_host = runtime.callbacks(),
        .ui = ui.callbacks(),
    }, "/import john's/session.jsonl");

    try std.testing.expectEqual(@as(usize, 1), runtime.calls.items.len);
    try std.testing.expectEqualStrings("john's/session.jsonl", runtime.calls.items[0].input_path);
    try std.testing.expectEqual(@as(usize, 0), ui.errors.items.len);
    try std.testing.expectEqualStrings("Session imported from: john's/session.jsonl", ui.statuses.items[0]);
}

test "InteractiveMode handleImportCommand shows non-fatal error for missing import path" {
    const allocator = std.testing.allocator;
    var ui = TestImportUi.init(allocator);
    defer ui.deinit();
    var runtime = TestImportRuntimeHost.init(allocator, .missing_file);
    defer runtime.deinit();

    try handleImportCommand(allocator, .{
        .runtime_host = runtime.callbacks(),
        .ui = ui.callbacks(),
    }, "/import /tmp/missing-session.jsonl");

    try std.testing.expectEqual(@as(usize, 1), runtime.calls.items.len);
    try std.testing.expectEqualStrings("/tmp/missing-session.jsonl", runtime.calls.items[0].input_path);
    try std.testing.expectEqual(@as(usize, 1), ui.errors.items.len);
    try std.testing.expectEqualStrings(
        "Failed to import session: File not found: /tmp/missing-session.jsonl",
        ui.errors.items[0],
    );
    try std.testing.expectEqual(@as(usize, 0), ui.statuses.items.len);
    try std.testing.expectEqual(@as(usize, 0), ui.fatal_count);
}

// Ported from packages/coding-agent/test/interactive-mode-clone-command.test.ts.
test "InteractiveMode /clone clones the current leaf into a new session" {
    const allocator = std.testing.allocator;
    var session_manager = TestCloneSessionManager{ .leaf_id = "leaf-123" };
    var runtime = TestCloneRuntimeHost.init(allocator);
    defer runtime.deinit();
    var editor = TestCloneEditor.init(allocator);
    defer editor.deinit();
    var ui = TestCloneUi.init(allocator);
    defer ui.deinit();

    try handleCloneCommand(allocator, .{
        .session_manager = session_manager.callbacks(),
        .runtime_host = runtime.callbacks(),
        .editor = editor.callbacks(),
        .ui = ui.callbacks(),
    });

    try std.testing.expectEqual(@as(usize, 1), runtime.calls.items.len);
    try std.testing.expectEqualStrings("leaf-123", runtime.calls.items[0].entry_id);
    try std.testing.expectEqual(extension_types.ForkPosition.at, runtime.calls.items[0].position);
    try std.testing.expectEqual(@as(usize, 1), ui.render_count);
    try std.testing.expectEqual(@as(usize, 1), editor.texts.items.len);
    try std.testing.expectEqualStrings("", editor.texts.items[0]);
    try std.testing.expectEqual(@as(usize, 1), ui.statuses.items.len);
    try std.testing.expectEqualStrings("Cloned to new session", ui.statuses.items[0]);
    try std.testing.expectEqual(@as(usize, 0), ui.errors.items.len);
    try std.testing.expectEqual(@as(usize, 0), ui.request_render_count);
}

test "InteractiveMode /clone shows status when there is nothing to clone" {
    const allocator = std.testing.allocator;
    var session_manager = TestCloneSessionManager{};
    var runtime = TestCloneRuntimeHost.init(allocator);
    defer runtime.deinit();
    var editor = TestCloneEditor.init(allocator);
    defer editor.deinit();
    var ui = TestCloneUi.init(allocator);
    defer ui.deinit();

    try handleCloneCommand(allocator, .{
        .session_manager = session_manager.callbacks(),
        .runtime_host = runtime.callbacks(),
        .editor = editor.callbacks(),
        .ui = ui.callbacks(),
    });

    try std.testing.expectEqual(@as(usize, 0), runtime.calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), ui.statuses.items.len);
    try std.testing.expectEqualStrings("Nothing to clone yet", ui.statuses.items[0]);
    try std.testing.expectEqual(@as(usize, 0), ui.errors.items.len);
}

// Ported from packages/coding-agent/test/interactive-mode-startup-input.test.ts.
test "InteractiveMode startup input queues normal prompt before callback is installed" {
    const allocator = std.testing.allocator;
    var controller = StartupInputController.init(allocator);
    defer controller.deinit();
    var editor = TestStartupEditor.init(allocator);
    defer editor.deinit();
    var flush = TestStartupFlush{};

    try controller.submitEditorText(.{
        .editor = editor.callbacks(),
        .session = .{
            .is_compacting = false,
            .is_streaming = false,
            .is_bash_running = false,
        },
        .flush_pending_bash_components = flush.callbacks(),
    }, " early prompt ");

    try std.testing.expectEqual(@as(usize, 1), controller.pending_user_inputs.items.len);
    try std.testing.expectEqualStrings("early prompt", controller.pending_user_inputs.items[0]);
    try std.testing.expectEqual(@as(usize, 1), flush.count);
    try std.testing.expectEqual(@as(usize, 1), editor.history.items.len);
    try std.testing.expectEqualStrings("early prompt", editor.history.items[0]);
}

test "InteractiveMode startup input returns queued prompt before installing callback" {
    const allocator = std.testing.allocator;
    var controller = StartupInputController.init(allocator);
    defer controller.deinit();
    var callback = TestStartupInputCallback.init(allocator);
    defer callback.deinit();

    try controller.queueInput("queued prompt");
    const result = try controller.getUserInput(callback.callbacks());
    const queued = switch (result) {
        .queued => |value| value,
        .waiting => return error.ExpectedQueuedStartupInput,
    };
    defer allocator.free(queued);

    try std.testing.expectEqualStrings("queued prompt", queued);
    try std.testing.expect(controller.on_input_callback == null);
    try std.testing.expectEqual(@as(usize, 0), controller.pending_user_inputs.items.len);
    try std.testing.expectEqual(@as(usize, 0), callback.inputs.items.len);
}
