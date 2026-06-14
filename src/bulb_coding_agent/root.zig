pub const ai = @import("bulb_ai");
pub const agent = @import("bulb_agent");
pub const tui = @import("bulb_tui");
pub const extension_sdk = @import("bulb_extension_sdk");
pub const config = @import("config.zig");
pub const resolve_config_value = @import("resolve_config_value.zig");
pub const agent_session_services = @import("agent_session_services.zig");
pub const agent_session_runtime = @import("agent_session_runtime.zig");
pub const resource_loader = @import("resource_loader.zig");
pub const session_events = @import("session_events.zig");
pub const session_stats = @import("session_stats.zig");
pub const session_cwd = @import("session_cwd.zig");
pub const session_manager = @import("session_manager.zig");
pub const compaction = @import("compaction.zig");
pub const settings_manager = @import("settings_manager.zig");
pub const session_selector = @import("session_selector.zig");
pub const session_selector_search = @import("session_selector_search.zig");
pub const tree_selector = @import("tree_selector.zig");
pub const system_prompt = @import("system_prompt.zig");
pub const extensions = @import("extensions/root.zig");
pub const tools = @import("tools/root.zig");
pub const auth_guidance = @import("auth_guidance.zig");
pub const auth_storage = @import("auth_storage.zig");
pub const assistant_message = @import("assistant_message.zig");
pub const footer = @import("footer.zig");
pub const ansi = @import("ansi.zig");
pub const bash_executor = @import("bash_executor.zig");
pub const cli_args = @import("cli_args.zig");
pub const event_bus = @import("event_bus.zig");
pub const file_processor = @import("file_processor.zig");
pub const frontmatter = @import("frontmatter.zig");
pub const git = @import("git.zig");
pub const initial_message = @import("initial_message.zig");
pub const interactive_mode = @import("interactive_mode.zig");
pub const json = @import("json.zig");
pub const keybindings = @import("keybindings.zig");
pub const list_models = @import("list_models.zig");
pub const mime = @import("mime.zig");
pub const migrations = @import("migrations.zig");
pub const model_registry = @import("model_registry.zig");
pub const model_resolver = @import("model_resolver.zig");
pub const messages = @import("messages.zig");
pub const oauth_selector = @import("oauth_selector.zig");
pub const output_guard = @import("output_guard.zig");
pub const package_manager = @import("package_manager.zig");
pub const paths = @import("paths.zig");
pub const path_utils = @import("path_utils.zig");
pub const plan_mode_utils = @import("plan_mode_utils.zig");
pub const provider_display_names = @import("provider_display_names.zig");
pub const prompt_templates = @import("prompt_templates.zig");
pub const restore_sandbox_env = @import("restore_sandbox_env.zig");
pub const shell = @import("shell.zig");
pub const skills = @import("skills.zig");
pub const sleep = @import("sleep.zig");
pub const source_info = @import("source_info.zig");
pub const startup_session_name = @import("startup_session_name.zig");
pub const theme = @import("theme.zig");
pub const user_agent = @import("user_agent.zig");
pub const version_check = @import("version_check.zig");

const build_options = @import("build_options");

pub const version = build_options.version;

pub const Args = cli_args.Args;
pub const parseArgs = cli_args.parseArgs;
pub const getAgentDirAlloc = config.agentDirAlloc;
pub const VERSION = version;
pub const getProviderLoginHelpAlloc = auth_guidance.getProviderLoginHelpAlloc;
pub const formatNoApiKeyFoundMessageAlloc = auth_guidance.formatNoApiKeyFoundMessageAlloc;
pub const formatNoModelSelectedMessageAlloc = auth_guidance.formatNoModelSelectedMessageAlloc;
pub const formatNoModelsAvailableMessageAlloc = auth_guidance.formatNoModelsAvailableMessageAlloc;
pub const AuthStorage = auth_storage.AuthStorage;
pub const AuthCredential = auth_storage.AuthCredential;
pub const AuthStatus = auth_storage.AuthStatus;
pub const FooterComponent = footer.FooterComponent;
pub const FooterDataSnapshot = footer.FooterDataSnapshot;
pub const FooterSessionSnapshot = footer.FooterSessionSnapshot;
pub const ProcessedFiles = file_processor.ProcessedFiles;
pub const processFileArgumentsAlloc = file_processor.processFileArgumentsAlloc;
pub const ModelRegistry = model_registry.ModelRegistry;
pub const SettingsManager = settings_manager.SettingsManager;
pub const RetrySettings = settings_manager.RetrySettings;
pub const ProviderRetrySettings = settings_manager.ProviderRetrySettings;
pub const SessionManager = session_manager.SessionManager;
pub const AgentSessionServices = agent_session_services.AgentSessionServices;
pub const AgentSessionRuntimeDiagnostic = agent_session_services.AgentSessionRuntimeDiagnostic;
pub const AgentSessionRuntimeDiagnosticType = agent_session_services.AgentSessionRuntimeDiagnosticType;
pub const CreateAgentSessionServicesOptions = agent_session_services.CreateAgentSessionServicesOptions;
pub const ExtensionFlagInput = agent_session_services.ExtensionFlagInput;
pub const createAgentSessionServicesAlloc = agent_session_services.createAgentSessionServicesAlloc;
pub const AgentSessionRuntime = agent_session_runtime.AgentSessionRuntime;
pub const BeforeSessionInvalidateCallback = agent_session_runtime.BeforeSessionInvalidateCallback;
pub const CreateAgentSessionRuntimeFactory = agent_session_runtime.CreateAgentSessionRuntimeFactory;
pub const CreateAgentSessionRuntimeOptions = agent_session_runtime.CreateAgentSessionRuntimeOptions;
pub const CreateAgentSessionRuntimeResult = agent_session_runtime.CreateAgentSessionRuntimeResult;
pub const RebindSessionCallback = agent_session_runtime.RebindSessionCallback;
pub const RuntimeSession = agent_session_runtime.RuntimeSession;
pub const RuntimeSessionReloadOptions = agent_session_runtime.RuntimeSessionReloadOptions;
pub const SessionChangeResult = agent_session_runtime.SessionChangeResult;
pub const SwitchSessionOptions = agent_session_runtime.SwitchSessionOptions;
pub const createAgentSessionRuntime = agent_session_runtime.createAgentSessionRuntime;
pub const CompactionSettings = compaction.CompactionSettings;
pub const CompactionPreparation = compaction.CompactionPreparation;
pub const CompactionResult = compaction.CompactionResult;
pub const SummaryExecutor = compaction.SummaryExecutor;
pub const RegistrySummaryExecutorContext = compaction.RegistrySummaryExecutorContext;
pub const default_compaction_settings = compaction.default_compaction_settings;
pub const SessionEventBridge = session_events.SessionEventBridge;
pub const SessionEvent = session_events.SessionEvent;
pub const SessionEventListener = session_events.SessionEventListener;
pub const SessionSubscription = session_events.SessionSubscription;
pub const SessionStats = session_stats.SessionStats;
pub const SessionStatsOptions = session_stats.SessionStatsOptions;
pub const SessionTokenStats = session_stats.SessionTokenStats;
pub const getContextUsageAlloc = session_stats.getContextUsageAlloc;
pub const getSessionStatsAlloc = session_stats.getSessionStatsAlloc;
pub const writeListModels = list_models.writeListModels;
pub const restoreSandboxEnv = restore_sandbox_env.restoreSandboxEnv;
pub const QueueUpdateSessionEvent = session_events.QueueUpdateSessionEvent;
pub const QueueMode = session_events.QueueMode;
pub const CustomMessageDelivery = session_events.CustomMessageDelivery;
pub const queuedExtensionCommandErrorMessageAlloc = session_events.queuedExtensionCommandErrorMessageAlloc;
pub const MessageEndListener = session_events.MessageEndListener;
pub const AutoRetryController = session_events.AutoRetryController;
pub const AgentSessionReplay = session_events.AgentSessionReplay;
pub const AutoCompactionConfig = session_events.AutoCompactionConfig;
pub const CompactionAuthMode = session_events.CompactionAuthMode;
pub const CompactionRequestAuthResolver = session_events.CompactionRequestAuthResolver;
pub const ResolvedCompactionRequestOptions = session_events.ResolvedCompactionRequestOptions;
pub const ToolDefinition = extensions.ToolDefinition;
pub const ToolExecutionMode = extensions.ToolExecutionMode;
pub const ExtensionContext = extensions.ExtensionContext;
pub const ExtensionCommandContext = extensions.ExtensionCommandContext;
pub const ExtensionEvent = extensions.ExtensionEvent;
pub const ExtensionAPI = extensions.ExtensionAPI;
pub const ProviderConfig = extensions.ProviderConfig;
pub const ProviderModelConfig = extensions.ProviderModelConfig;
pub const ToolName = tools.tool_registry.ToolName;
pub const ToolsOptions = tools.tool_registry.ToolsOptions;
pub const AgentTool = tools.tool_registry.AgentTool;
pub const createToolDefinition = tools.tool_registry.createToolDefinition;
pub const createTool = tools.tool_registry.createTool;
pub const createCodingToolsAlloc = tools.tool_registry.createCodingToolsAlloc;
pub const createReadOnlyToolsAlloc = tools.tool_registry.createReadOnlyToolsAlloc;
pub const createAllTools = tools.tool_registry.createAllTools;
pub const EventBus = event_bus.EventBus;
pub const EventBusController = event_bus.EventBusController;
pub const createEventBus = event_bus.EventBusController.init;
pub const createExtensionRuntime = extensions.createExtensionRuntime;
pub const ExtensionRunner = extensions.ExtensionRunner;
pub const loadExtensionFromFactoryAlloc = extensions.loadExtensionFromFactoryAlloc;
pub const loadExtensionsAlloc = extensions.loadExtensionsAlloc;
pub const wrapRegisteredTool = extensions.wrapRegisteredTool;
pub const wrapRegisteredToolsAlloc = extensions.wrapRegisteredToolsAlloc;

pub fn createReadToolDefinition(cwd: []const u8, options: tools.read.ReadToolOptions) ToolDefinition {
    var all_options: ToolsOptions = .{};
    all_options.read = options;
    return tools.tool_registry.createToolDefinition(.read, cwd, all_options);
}

pub fn createBashToolDefinition(cwd: []const u8, options: tools.bash.BashToolOptions) ToolDefinition {
    var all_options: ToolsOptions = .{};
    all_options.bash = options;
    return tools.tool_registry.createToolDefinition(.bash, cwd, all_options);
}

pub fn createEditToolDefinition(cwd: []const u8, options: tools.edit.EditToolOptions) ToolDefinition {
    var all_options: ToolsOptions = .{};
    all_options.edit = options;
    return tools.tool_registry.createToolDefinition(.edit, cwd, all_options);
}

pub fn createWriteToolDefinition(cwd: []const u8, options: tools.write.WriteToolOptions) ToolDefinition {
    var all_options: ToolsOptions = .{};
    all_options.write = options;
    return tools.tool_registry.createToolDefinition(.write, cwd, all_options);
}

pub fn createGrepToolDefinition(cwd: []const u8, options: tools.grep.GrepToolOptions) ToolDefinition {
    var all_options: ToolsOptions = .{};
    all_options.grep = options;
    return tools.tool_registry.createToolDefinition(.grep, cwd, all_options);
}

pub fn createFindToolDefinition(cwd: []const u8, options: tools.find.FindToolOptions) ToolDefinition {
    var all_options: ToolsOptions = .{};
    all_options.find = options;
    return tools.tool_registry.createToolDefinition(.find, cwd, all_options);
}

pub fn createLsToolDefinition(cwd: []const u8, options: tools.ls.LsToolOptions) ToolDefinition {
    var all_options: ToolsOptions = .{};
    all_options.ls = options;
    return tools.tool_registry.createToolDefinition(.ls, cwd, all_options);
}

pub fn createReadTool(cwd: []const u8, options: tools.read.ReadToolOptions) AgentTool {
    return tools.tool_registry.wrapToolDefinition(createReadToolDefinition(cwd, options));
}

pub fn createBashTool(cwd: []const u8, options: tools.bash.BashToolOptions) AgentTool {
    return tools.tool_registry.wrapToolDefinition(createBashToolDefinition(cwd, options));
}

pub fn createEditTool(cwd: []const u8, options: tools.edit.EditToolOptions) AgentTool {
    return tools.tool_registry.wrapToolDefinition(createEditToolDefinition(cwd, options));
}

pub fn createWriteTool(cwd: []const u8, options: tools.write.WriteToolOptions) AgentTool {
    return tools.tool_registry.wrapToolDefinition(createWriteToolDefinition(cwd, options));
}

pub fn createGrepTool(cwd: []const u8, options: tools.grep.GrepToolOptions) AgentTool {
    return tools.tool_registry.wrapToolDefinition(createGrepToolDefinition(cwd, options));
}

pub fn createFindTool(cwd: []const u8, options: tools.find.FindToolOptions) AgentTool {
    return tools.tool_registry.wrapToolDefinition(createFindToolDefinition(cwd, options));
}

pub fn createLsTool(cwd: []const u8, options: tools.ls.LsToolOptions) AgentTool {
    return tools.tool_registry.wrapToolDefinition(createLsToolDefinition(cwd, options));
}

test {
    _ = @import("config.zig");
    _ = @import("resolve_config_value.zig");
    _ = @import("agent_session_services.zig");
    _ = @import("agent_session_runtime.zig");
    _ = @import("resource_loader.zig");
    _ = @import("session_events.zig");
    _ = @import("session_stats.zig");
    _ = @import("session_cwd.zig");
    _ = @import("session_manager.zig");
    _ = @import("compaction.zig");
    _ = @import("settings_manager.zig");
    _ = @import("session_selector.zig");
    _ = @import("session_selector_search.zig");
    _ = @import("tree_selector.zig");
    _ = @import("system_prompt.zig");
    _ = @import("extensions/root.zig");
    _ = @import("tools/root.zig");
    _ = @import("auth_guidance.zig");
    _ = @import("auth_storage.zig");
    _ = @import("assistant_message.zig");
    _ = @import("footer.zig");
    _ = @import("ansi.zig");
    _ = @import("bash_executor.zig");
    _ = @import("cli_args.zig");
    _ = @import("event_bus.zig");
    _ = @import("file_processor.zig");
    _ = @import("frontmatter.zig");
    _ = @import("git.zig");
    _ = @import("initial_message.zig");
    _ = @import("interactive_mode.zig");
    _ = @import("json.zig");
    _ = @import("keybindings.zig");
    _ = @import("list_models.zig");
    _ = @import("mime.zig");
    _ = @import("migrations.zig");
    _ = @import("model_registry.zig");
    _ = @import("model_resolver.zig");
    _ = @import("messages.zig");
    _ = @import("oauth_selector.zig");
    _ = @import("output_guard.zig");
    _ = @import("package_manager.zig");
    _ = @import("paths.zig");
    _ = @import("path_utils.zig");
    _ = @import("plan_mode_utils.zig");
    _ = @import("provider_display_names.zig");
    _ = @import("prompt_templates.zig");
    _ = @import("restore_sandbox_env.zig");
    _ = @import("shell.zig");
    _ = @import("skills.zig");
    _ = @import("sleep.zig");
    _ = @import("source_info.zig");
    _ = @import("startup_session_name.zig");
    _ = @import("theme.zig");
    _ = @import("user_agent.zig");
    _ = @import("version_check.zig");
}
