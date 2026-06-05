const std = @import("std");
const config = @import("config.zig");
const package_manager = @import("package_manager.zig");
const paths = @import("paths.zig");
const prompt_templates = @import("prompt_templates.zig");
const settings_manager = @import("settings_manager.zig");
const skills = @import("skills.zig");
const source_info = @import("source_info.zig");
const theme = @import("theme.zig");

pub const ResourceCollision = skills.ResourceCollision;
pub const ResourceDiagnostic = skills.ResourceDiagnostic;
pub const SourceInfo = source_info.SourceInfo;
pub const PathMetadata = source_info.PathMetadata;
pub const PromptTemplate = prompt_templates.PromptTemplate;
pub const Skill = skills.Skill;
pub const Theme = theme.Theme;

pub const AgentFile = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    content: []u8,

    fn initAlloc(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !AgentFile {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const owned_content = try allocator.dupe(u8, content);
        errdefer allocator.free(owned_content);
        return .{
            .allocator = allocator,
            .path = owned_path,
            .content = owned_content,
        };
    }

    fn deinit(self: *AgentFile) void {
        self.allocator.free(self.path);
        self.allocator.free(self.content);
        self.* = undefined;
    }
};

pub const LoadedExtension = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    source_info: SourceInfo,

    fn initAlloc(allocator: std.mem.Allocator, path: []const u8, info: SourceInfo) !LoadedExtension {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const owned_info = try cloneSourceInfoAlloc(allocator, info);
        return .{
            .allocator = allocator,
            .path = owned_path,
            .source_info = owned_info,
        };
    }

    fn deinit(self: *LoadedExtension) void {
        self.allocator.free(self.path);
        deinitSourceInfo(self.allocator, &self.source_info);
        self.* = undefined;
    }
};

pub const ExtensionError = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    error_message: []u8,

    fn initAlloc(allocator: std.mem.Allocator, path: []const u8, error_message: []const u8) !ExtensionError {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const owned_error = try allocator.dupe(u8, error_message);
        errdefer allocator.free(owned_error);
        return .{
            .allocator = allocator,
            .path = owned_path,
            .error_message = owned_error,
        };
    }

    fn deinit(self: *ExtensionError) void {
        self.allocator.free(self.path);
        self.allocator.free(self.error_message);
        self.* = undefined;
    }
};

pub const LoadExtensionsResult = struct {
    allocator: std.mem.Allocator,
    extensions: []LoadedExtension,
    errors: []ExtensionError,

    pub fn deinit(self: *LoadExtensionsResult) void {
        for (self.extensions) |*extension| extension.deinit();
        self.allocator.free(self.extensions);
        for (self.errors) |*extension_error| extension_error.deinit();
        self.allocator.free(self.errors);
        self.* = undefined;
    }
};

pub const ResourcePathEntry = struct {
    path: []const u8,
    metadata: PathMetadata,
};

pub const ResourceExtensionPaths = struct {
    skill_paths: []const ResourcePathEntry = &.{},
    prompt_paths: []const ResourcePathEntry = &.{},
    theme_paths: []const ResourcePathEntry = &.{},
};

pub const DefaultResourceLoaderOptions = struct {
    cwd: []const u8,
    agent_dir: []const u8,
    settings_manager: ?*settings_manager.SettingsManager = null,
    additional_extension_paths: []const []const u8 = &.{},
    additional_skill_paths: []const []const u8 = &.{},
    additional_prompt_template_paths: []const []const u8 = &.{},
    additional_theme_paths: []const []const u8 = &.{},
    no_extensions: bool = false,
    no_skills: bool = false,
    no_prompt_templates: bool = false,
    no_themes: bool = false,
    no_context_files: bool = false,
    system_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const []const u8 = null,
};

pub const DefaultResourceLoader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []u8,
    agent_dir: []u8,
    settings_manager_ptr: *settings_manager.SettingsManager,
    owns_settings_manager: bool,
    package_manager: package_manager.DefaultPackageManager,
    additional_extension_paths: []const []const u8,
    additional_skill_paths: []const []const u8,
    additional_prompt_template_paths: []const []const u8,
    additional_theme_paths: []const []const u8,
    no_extensions: bool,
    no_skills: bool,
    no_prompt_templates: bool,
    no_themes: bool,
    no_context_files: bool,
    system_prompt_source: ?[]u8,
    append_system_prompt_source: ?[]const []const u8,
    extensions_result: LoadExtensionsResult,
    loaded_skills: []Skill,
    skill_diagnostics: []ResourceDiagnostic,
    prompts: []PromptTemplate,
    prompt_diagnostics: []ResourceDiagnostic,
    themes: []Theme,
    theme_diagnostics: []ResourceDiagnostic,
    agents_files: []AgentFile,
    system_prompt: ?[]u8,
    append_system_prompt: []const []const u8,
    last_skill_paths: []const []const u8,
    last_prompt_paths: []const []const u8,
    last_theme_paths: []const []const u8,
    extension_skill_source_infos: []SourceInfoEntry,
    extension_prompt_source_infos: []SourceInfoEntry,
    extension_theme_source_infos: []SourceInfoEntry,

    pub fn initAlloc(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: DefaultResourceLoaderOptions,
    ) !DefaultResourceLoader {
        const resolved_cwd = try paths.resolvePathAlloc(allocator, options.cwd, ".", .{});
        errdefer allocator.free(resolved_cwd);
        const resolved_agent_dir = try paths.resolvePathAlloc(allocator, options.agent_dir, ".", .{});
        errdefer allocator.free(resolved_agent_dir);

        var owns_settings_manager = false;
        const settings_ptr = if (options.settings_manager) |manager|
            manager
        else blk: {
            const manager = try allocator.create(settings_manager.SettingsManager);
            errdefer allocator.destroy(manager);
            manager.* = try settings_manager.SettingsManager.create(allocator, io, resolved_cwd, resolved_agent_dir);
            owns_settings_manager = true;
            break :blk manager;
        };

        var manager_for_errdefer: ?*settings_manager.SettingsManager = if (owns_settings_manager) settings_ptr else null;
        errdefer if (manager_for_errdefer) |manager| {
            manager.deinit();
            allocator.destroy(manager);
        };

        var packages = try package_manager.DefaultPackageManager.initAlloc(allocator, io, .{
            .cwd = resolved_cwd,
            .agent_dir = resolved_agent_dir,
            .settings_manager = settings_ptr,
        });
        errdefer packages.deinit();

        const additional_extension_paths = try cloneStringArray(allocator, options.additional_extension_paths);
        errdefer freeStringArray(allocator, additional_extension_paths);
        const additional_skill_paths = try cloneStringArray(allocator, options.additional_skill_paths);
        errdefer freeStringArray(allocator, additional_skill_paths);
        const additional_prompt_template_paths = try cloneStringArray(allocator, options.additional_prompt_template_paths);
        errdefer freeStringArray(allocator, additional_prompt_template_paths);
        const additional_theme_paths = try cloneStringArray(allocator, options.additional_theme_paths);
        errdefer freeStringArray(allocator, additional_theme_paths);
        const append_source = if (options.append_system_prompt) |sources|
            try cloneStringArray(allocator, sources)
        else
            null;
        errdefer if (append_source) |sources| freeStringArray(allocator, sources);

        const empty_extensions = try emptySlice(allocator, LoadedExtension);
        errdefer allocator.free(empty_extensions);
        const empty_extension_errors = try emptySlice(allocator, ExtensionError);
        errdefer allocator.free(empty_extension_errors);
        const empty_skills = try emptySlice(allocator, Skill);
        errdefer allocator.free(empty_skills);
        const empty_skill_diagnostics = try emptySlice(allocator, ResourceDiagnostic);
        errdefer allocator.free(empty_skill_diagnostics);
        const empty_prompts = try emptySlice(allocator, PromptTemplate);
        errdefer allocator.free(empty_prompts);
        const empty_prompt_diagnostics = try emptySlice(allocator, ResourceDiagnostic);
        errdefer allocator.free(empty_prompt_diagnostics);
        const empty_themes = try emptySlice(allocator, Theme);
        errdefer allocator.free(empty_themes);
        const empty_theme_diagnostics = try emptySlice(allocator, ResourceDiagnostic);
        errdefer allocator.free(empty_theme_diagnostics);
        const empty_agents_files = try emptySlice(allocator, AgentFile);
        errdefer allocator.free(empty_agents_files);
        const empty_append = try emptySlice(allocator, []const u8);
        errdefer allocator.free(empty_append);
        const empty_last_skill_paths = try emptySlice(allocator, []const u8);
        errdefer allocator.free(empty_last_skill_paths);
        const empty_last_prompt_paths = try emptySlice(allocator, []const u8);
        errdefer allocator.free(empty_last_prompt_paths);
        const empty_last_theme_paths = try emptySlice(allocator, []const u8);
        errdefer allocator.free(empty_last_theme_paths);
        const empty_skill_infos = try emptySlice(allocator, SourceInfoEntry);
        errdefer allocator.free(empty_skill_infos);
        const empty_prompt_infos = try emptySlice(allocator, SourceInfoEntry);
        errdefer allocator.free(empty_prompt_infos);
        const empty_theme_infos = try emptySlice(allocator, SourceInfoEntry);
        errdefer allocator.free(empty_theme_infos);

        manager_for_errdefer = null;
        return .{
            .allocator = allocator,
            .io = io,
            .cwd = resolved_cwd,
            .agent_dir = resolved_agent_dir,
            .settings_manager_ptr = settings_ptr,
            .owns_settings_manager = owns_settings_manager,
            .package_manager = packages,
            .additional_extension_paths = additional_extension_paths,
            .additional_skill_paths = additional_skill_paths,
            .additional_prompt_template_paths = additional_prompt_template_paths,
            .additional_theme_paths = additional_theme_paths,
            .no_extensions = options.no_extensions,
            .no_skills = options.no_skills,
            .no_prompt_templates = options.no_prompt_templates,
            .no_themes = options.no_themes,
            .no_context_files = options.no_context_files,
            .system_prompt_source = if (options.system_prompt) |value| try allocator.dupe(u8, value) else null,
            .append_system_prompt_source = append_source,
            .extensions_result = .{
                .allocator = allocator,
                .extensions = empty_extensions,
                .errors = empty_extension_errors,
            },
            .loaded_skills = empty_skills,
            .skill_diagnostics = empty_skill_diagnostics,
            .prompts = empty_prompts,
            .prompt_diagnostics = empty_prompt_diagnostics,
            .themes = empty_themes,
            .theme_diagnostics = empty_theme_diagnostics,
            .agents_files = empty_agents_files,
            .system_prompt = null,
            .append_system_prompt = empty_append,
            .last_skill_paths = empty_last_skill_paths,
            .last_prompt_paths = empty_last_prompt_paths,
            .last_theme_paths = empty_last_theme_paths,
            .extension_skill_source_infos = empty_skill_infos,
            .extension_prompt_source_infos = empty_prompt_infos,
            .extension_theme_source_infos = empty_theme_infos,
        };
    }

    pub fn deinit(self: *DefaultResourceLoader) void {
        self.extensions_result.deinit();
        skills.deinitSkills(self.allocator, self.loaded_skills);
        skills.deinitDiagnostics(self.allocator, self.skill_diagnostics);
        prompt_templates.deinitPromptTemplates(self.allocator, self.prompts);
        skills.deinitDiagnostics(self.allocator, self.prompt_diagnostics);
        theme.deinitThemes(self.allocator, self.themes);
        skills.deinitDiagnostics(self.allocator, self.theme_diagnostics);
        deinitAgentFiles(self.allocator, self.agents_files);
        if (self.system_prompt) |value| self.allocator.free(value);
        freeStringArray(self.allocator, self.append_system_prompt);
        freeStringArray(self.allocator, self.last_skill_paths);
        freeStringArray(self.allocator, self.last_prompt_paths);
        freeStringArray(self.allocator, self.last_theme_paths);
        deinitSourceInfoEntries(self.allocator, self.extension_skill_source_infos);
        deinitSourceInfoEntries(self.allocator, self.extension_prompt_source_infos);
        deinitSourceInfoEntries(self.allocator, self.extension_theme_source_infos);
        freeStringArray(self.allocator, self.additional_extension_paths);
        freeStringArray(self.allocator, self.additional_skill_paths);
        freeStringArray(self.allocator, self.additional_prompt_template_paths);
        freeStringArray(self.allocator, self.additional_theme_paths);
        if (self.system_prompt_source) |value| self.allocator.free(value);
        if (self.append_system_prompt_source) |sources| freeStringArray(self.allocator, sources);
        self.package_manager.deinit();
        if (self.owns_settings_manager) {
            self.settings_manager_ptr.deinit();
            self.allocator.destroy(self.settings_manager_ptr);
        }
        self.allocator.free(self.cwd);
        self.allocator.free(self.agent_dir);
        self.* = undefined;
    }

    pub fn getExtensions(self: *const DefaultResourceLoader) *const LoadExtensionsResult {
        return &self.extensions_result;
    }

    pub fn getSkills(self: *const DefaultResourceLoader) SkillsSnapshot {
        return .{ .skills = self.loaded_skills, .diagnostics = self.skill_diagnostics };
    }

    pub fn getPrompts(self: *const DefaultResourceLoader) PromptsSnapshot {
        return .{ .prompts = self.prompts, .diagnostics = self.prompt_diagnostics };
    }

    pub fn getThemes(self: *const DefaultResourceLoader) ThemesSnapshot {
        return .{ .themes = self.themes, .diagnostics = self.theme_diagnostics };
    }

    pub fn getAgentsFiles(self: *const DefaultResourceLoader) []AgentFile {
        return self.agents_files;
    }

    pub fn getSystemPrompt(self: *const DefaultResourceLoader) ?[]const u8 {
        return self.system_prompt;
    }

    pub fn getAppendSystemPrompt(self: *const DefaultResourceLoader) []const []const u8 {
        return self.append_system_prompt;
    }

    pub fn extendResources(self: *DefaultResourceLoader, extension_paths: ResourceExtensionPaths) !void {
        try self.extendSourceInfos(&self.extension_skill_source_infos, extension_paths.skill_paths);
        try self.extendSourceInfos(&self.extension_prompt_source_infos, extension_paths.prompt_paths);
        try self.extendSourceInfos(&self.extension_theme_source_infos, extension_paths.theme_paths);

        if (extension_paths.skill_paths.len > 0) {
            const incoming = try self.normalizedPathsFromEntries(extension_paths.skill_paths);
            defer freeStringArray(self.allocator, incoming);
            const merged = try self.mergePaths(self.last_skill_paths, incoming);
            freeStringArray(self.allocator, self.last_skill_paths);
            self.last_skill_paths = merged;
            try self.updateSkillsFromPaths(self.last_skill_paths, null);
        }
        if (extension_paths.prompt_paths.len > 0) {
            const incoming = try self.normalizedPathsFromEntries(extension_paths.prompt_paths);
            defer freeStringArray(self.allocator, incoming);
            const merged = try self.mergePaths(self.last_prompt_paths, incoming);
            freeStringArray(self.allocator, self.last_prompt_paths);
            self.last_prompt_paths = merged;
            try self.updatePromptsFromPaths(self.last_prompt_paths, null);
        }
        if (extension_paths.theme_paths.len > 0) {
            const incoming = try self.normalizedPathsFromEntries(extension_paths.theme_paths);
            defer freeStringArray(self.allocator, incoming);
            const merged = try self.mergePaths(self.last_theme_paths, incoming);
            freeStringArray(self.allocator, self.last_theme_paths);
            self.last_theme_paths = merged;
            try self.updateThemesFromPaths(self.last_theme_paths, null);
        }
    }

    pub fn reload(self: *DefaultResourceLoader) !void {
        try self.settings_manager_ptr.reload();
        var resolved_paths = try self.package_manager.resolve();
        defer resolved_paths.deinit();

        try self.updateExtensionsFromResolved(resolved_paths.extensions);

        const discovered_skill_paths = try pathsFromResolvedAlloc(self.allocator, resolved_paths.skills, true);
        defer freeStringArray(self.allocator, discovered_skill_paths);
        const skill_paths = if (self.no_skills)
            try self.mergePaths(&.{}, self.additional_skill_paths)
        else
            try self.mergePaths(discovered_skill_paths, self.additional_skill_paths);
        freeStringArray(self.allocator, self.last_skill_paths);
        self.last_skill_paths = skill_paths;
        try self.updateSkillsFromPaths(skill_paths, resolved_paths.skills);

        const discovered_prompt_paths = try pathsFromResolvedAlloc(self.allocator, resolved_paths.prompts, true);
        defer freeStringArray(self.allocator, discovered_prompt_paths);
        const prompt_paths = if (self.no_prompt_templates)
            try self.mergePaths(&.{}, self.additional_prompt_template_paths)
        else
            try self.mergePaths(discovered_prompt_paths, self.additional_prompt_template_paths);
        freeStringArray(self.allocator, self.last_prompt_paths);
        self.last_prompt_paths = prompt_paths;
        try self.updatePromptsFromPaths(prompt_paths, resolved_paths.prompts);

        const discovered_theme_paths = try pathsFromResolvedAlloc(self.allocator, resolved_paths.themes, true);
        defer freeStringArray(self.allocator, discovered_theme_paths);
        const theme_paths = if (self.no_themes)
            try self.mergePaths(&.{}, self.additional_theme_paths)
        else
            try self.mergePaths(discovered_theme_paths, self.additional_theme_paths);
        freeStringArray(self.allocator, self.last_theme_paths);
        self.last_theme_paths = theme_paths;
        try self.updateThemesFromPaths(theme_paths, resolved_paths.themes);

        const agents_files = if (self.no_context_files)
            try emptySlice(self.allocator, AgentFile)
        else
            try loadProjectContextFilesAlloc(self.allocator, self.io, .{ .cwd = self.cwd, .agent_dir = self.agent_dir });
        deinitAgentFiles(self.allocator, self.agents_files);
        self.agents_files = agents_files;

        const base_system_prompt_source = self.system_prompt_source orelse try self.discoverSystemPromptFileAlloc();
        const owns_discovered_system = self.system_prompt_source == null and base_system_prompt_source != null;
        defer if (owns_discovered_system) self.allocator.free(base_system_prompt_source.?);
        const system_prompt = try resolvePromptInputAlloc(self.allocator, self.io, base_system_prompt_source);
        if (self.system_prompt) |value| self.allocator.free(value);
        self.system_prompt = system_prompt;

        var append_sources_owned: ?[]const []const u8 = null;
        defer if (append_sources_owned) |sources| freeStringArray(self.allocator, sources);
        const append_sources = if (self.append_system_prompt_source) |sources|
            sources
        else blk: {
            if (try self.discoverAppendSystemPromptFileAlloc()) |path| {
                const one = try self.allocator.alloc([]const u8, 1);
                one[0] = path;
                append_sources_owned = one;
                break :blk one;
            }
            break :blk &.{};
        };
        var append_values: std.ArrayList([]const u8) = .empty;
        errdefer freeStringArray(self.allocator, append_values.items);
        for (append_sources) |source| {
            if (try resolvePromptInputAlloc(self.allocator, self.io, source)) |value| {
                try append_values.append(self.allocator, value);
            }
        }
        freeStringArray(self.allocator, self.append_system_prompt);
        self.append_system_prompt = try append_values.toOwnedSlice(self.allocator);
    }

    fn updateExtensionsFromResolved(
        self: *DefaultResourceLoader,
        resolved_extensions: []const package_manager.ResolvedResource,
    ) !void {
        var extensions: std.ArrayList(LoadedExtension) = .empty;
        errdefer deinitExtensionList(self.allocator, &extensions);
        var errors: std.ArrayList(ExtensionError) = .empty;
        errdefer deinitExtensionErrorList(self.allocator, &errors);

        if (!self.no_extensions) {
            for (resolved_extensions) |resource| {
                if (!resource.enabled) continue;
                try extensions.append(self.allocator, try LoadedExtension.initAlloc(
                    self.allocator,
                    resource.path,
                    source_info.createSourceInfo(resource.path, resource.metadata),
                ));
            }
        }

        for (self.additional_extension_paths) |path| {
            const resolved = paths.resolvePathAlloc(self.allocator, path, self.cwd, .{ .trim = true }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            defer self.allocator.free(resolved);
            if (std.Io.Dir.cwd().statFile(self.io, resolved, .{ .follow_symlinks = true })) |_| {
                try extensions.append(self.allocator, try LoadedExtension.initAlloc(
                    self.allocator,
                    resolved,
                    self.getDefaultSourceInfoForPath(resolved),
                ));
            } else |_| {
                try errors.append(self.allocator, try ExtensionError.initAlloc(self.allocator, resolved, "Extension path does not exist"));
            }
        }

        const result = LoadExtensionsResult{
            .allocator = self.allocator,
            .extensions = try extensions.toOwnedSlice(self.allocator),
            .errors = try errors.toOwnedSlice(self.allocator),
        };
        self.extensions_result.deinit();
        self.extensions_result = result;
    }

    fn updateSkillsFromPaths(
        self: *DefaultResourceLoader,
        skill_paths: []const []const u8,
        resolved_resources: ?[]const package_manager.ResolvedResource,
    ) !void {
        if (self.no_skills and skill_paths.len == 0) {
            skills.deinitSkills(self.allocator, self.loaded_skills);
            skills.deinitDiagnostics(self.allocator, self.skill_diagnostics);
            self.loaded_skills = try emptySlice(self.allocator, Skill);
            self.skill_diagnostics = try emptySlice(self.allocator, ResourceDiagnostic);
            return;
        }

        var result = try skills.loadSkillsAlloc(self.allocator, self.io, .{
            .cwd = self.cwd,
            .agent_dir = self.agent_dir,
            .skill_paths = skill_paths,
            .include_defaults = false,
        });
        errdefer result.deinit();
        for (result.skills) |*loaded_skill| {
            const info = self.findSourceInfoForPath(
                loaded_skill.file_path,
                self.extension_skill_source_infos,
                resolved_resources,
            ) orelse self.getDefaultSourceInfoForPath(loaded_skill.file_path);
            try replaceSourceInfoAlloc(self.allocator, &loaded_skill.source_info, info);
        }
        skills.deinitSkills(self.allocator, self.loaded_skills);
        skills.deinitDiagnostics(self.allocator, self.skill_diagnostics);
        self.loaded_skills = result.skills;
        self.skill_diagnostics = result.diagnostics;
        result.skills = &.{};
        result.diagnostics = &.{};
    }

    fn updatePromptsFromPaths(
        self: *DefaultResourceLoader,
        prompt_paths: []const []const u8,
        resolved_resources: ?[]const package_manager.ResolvedResource,
    ) !void {
        if (self.no_prompt_templates and prompt_paths.len == 0) {
            prompt_templates.deinitPromptTemplates(self.allocator, self.prompts);
            skills.deinitDiagnostics(self.allocator, self.prompt_diagnostics);
            self.prompts = try emptySlice(self.allocator, PromptTemplate);
            self.prompt_diagnostics = try emptySlice(self.allocator, ResourceDiagnostic);
            return;
        }

        const loaded = try prompt_templates.loadPromptTemplatesAlloc(self.allocator, self.io, .{
            .cwd = self.cwd,
            .agent_dir = self.agent_dir,
            .prompt_paths = prompt_paths,
            .include_defaults = false,
        });
        var deduped = try self.dedupePrompts(loaded);
        errdefer deduped.deinit(self.allocator);
        for (deduped.prompts) |*prompt| {
            const info = self.findSourceInfoForPath(
                prompt.file_path,
                self.extension_prompt_source_infos,
                resolved_resources,
            ) orelse self.getDefaultSourceInfoForPath(prompt.file_path);
            try replaceSourceInfoAlloc(self.allocator, &prompt.source_info, info);
        }
        prompt_templates.deinitPromptTemplates(self.allocator, self.prompts);
        skills.deinitDiagnostics(self.allocator, self.prompt_diagnostics);
        self.prompts = deduped.prompts;
        self.prompt_diagnostics = deduped.diagnostics;
        deduped.prompts = &.{};
        deduped.diagnostics = &.{};
    }

    fn updateThemesFromPaths(
        self: *DefaultResourceLoader,
        theme_paths: []const []const u8,
        resolved_resources: ?[]const package_manager.ResolvedResource,
    ) !void {
        if (self.no_themes and theme_paths.len == 0) {
            theme.deinitThemes(self.allocator, self.themes);
            skills.deinitDiagnostics(self.allocator, self.theme_diagnostics);
            self.themes = try emptySlice(self.allocator, Theme);
            self.theme_diagnostics = try emptySlice(self.allocator, ResourceDiagnostic);
            return;
        }

        var loaded = try self.loadThemes(theme_paths);
        errdefer loaded.deinit(self.allocator);
        var deduped = try self.dedupeThemes(loaded.themes, loaded.diagnostics);
        loaded.themes = &.{};
        loaded.diagnostics = &.{};
        errdefer deduped.deinit(self.allocator);
        for (deduped.themes) |*loaded_theme| {
            const info = self.findSourceInfoForPath(
                loaded_theme.source_path,
                self.extension_theme_source_infos,
                resolved_resources,
            ) orelse self.getDefaultSourceInfoForPath(loaded_theme.source_path);
            try replaceSourceInfoAlloc(self.allocator, &loaded_theme.source_info, info);
        }
        theme.deinitThemes(self.allocator, self.themes);
        skills.deinitDiagnostics(self.allocator, self.theme_diagnostics);
        self.themes = deduped.themes;
        self.theme_diagnostics = deduped.diagnostics;
        deduped.themes = &.{};
        deduped.diagnostics = &.{};
    }

    fn loadThemes(self: *DefaultResourceLoader, theme_paths: []const []const u8) !ThemeLoadResult {
        var themes: std.ArrayList(Theme) = .empty;
        errdefer deinitThemeList(self.allocator, &themes);
        var diagnostics: std.ArrayList(ResourceDiagnostic) = .empty;
        errdefer deinitDiagnosticList(self.allocator, &diagnostics);
        for (theme_paths) |raw_path| {
            const resolved = paths.resolvePathAlloc(self.allocator, raw_path, self.cwd, .{ .trim = true }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            defer self.allocator.free(resolved);
            const stat = std.Io.Dir.cwd().statFile(self.io, resolved, .{ .follow_symlinks = true }) catch {
                try appendDiagnostic(&diagnostics, self.allocator, .warning, "theme path does not exist", resolved, null);
                continue;
            };
            if (stat.kind == .directory) {
                try self.loadThemesFromDir(resolved, &themes, &diagnostics);
            } else if (stat.kind == .file and std.mem.endsWith(u8, resolved, ".json")) {
                try self.loadThemeFromFile(resolved, &themes, &diagnostics);
            } else {
                try appendDiagnostic(&diagnostics, self.allocator, .warning, "theme path is not a json file", resolved, null);
            }
        }
        return .{
            .themes = try themes.toOwnedSlice(self.allocator),
            .diagnostics = try diagnostics.toOwnedSlice(self.allocator),
        };
    }

    fn loadThemesFromDir(
        self: *DefaultResourceLoader,
        dir: []const u8,
        themes: *std.ArrayList(Theme),
        diagnostics: *std.ArrayList(ResourceDiagnostic),
    ) !void {
        var directory = openDirPath(self.io, dir, .{ .iterate = true }) catch return;
        defer directory.close(self.io);
        var iterator = directory.iterate();
        while (iterator.next(self.io) catch null) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            const kind = entryKindFollowSymlink(self.io, directory, entry) orelse continue;
            if (kind != .file) continue;
            const file_path = try std.fs.path.join(self.allocator, &.{ dir, entry.name });
            defer self.allocator.free(file_path);
            try self.loadThemeFromFile(file_path, themes, diagnostics);
        }
    }

    fn loadThemeFromFile(
        self: *DefaultResourceLoader,
        file_path: []const u8,
        themes: *std.ArrayList(Theme),
        diagnostics: *std.ArrayList(ResourceDiagnostic),
    ) !void {
        const loaded_theme = theme.loadThemeFromPathAlloc(self.allocator, self.io, file_path, self.getDefaultSourceInfoForPath(file_path)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try appendDiagnostic(diagnostics, self.allocator, .warning, "failed to load theme", file_path, null);
                return;
            },
        };
        try themes.append(self.allocator, loaded_theme);
    }

    fn dedupePrompts(self: *DefaultResourceLoader, loaded: []PromptTemplate) !PromptLoadResult {
        var prompts_out: std.ArrayList(PromptTemplate) = .empty;
        errdefer deinitPromptList(self.allocator, &prompts_out);
        var diagnostics: std.ArrayList(ResourceDiagnostic) = .empty;
        errdefer deinitDiagnosticList(self.allocator, &diagnostics);
        var seen: std.StringHashMapUnmanaged(usize) = .empty;
        defer seen.deinit(self.allocator);
        defer self.allocator.free(loaded);

        for (loaded) |prompt| {
            var moved = prompt;
            if (seen.get(moved.name)) |winner_index| {
                const winner = prompts_out.items[winner_index];
                const collision = try ResourceCollision.initAlloc(self.allocator, "prompt", moved.name, winner.file_path, moved.file_path);
                try appendDiagnostic(&diagnostics, self.allocator, .collision, try std.fmt.allocPrint(self.allocator, "name \"/{s}\" collision", .{moved.name}), moved.file_path, collision);
                moved.deinit();
            } else {
                try seen.put(self.allocator, moved.name, prompts_out.items.len);
                try prompts_out.append(self.allocator, moved);
            }
        }
        return .{
            .prompts = try prompts_out.toOwnedSlice(self.allocator),
            .diagnostics = try diagnostics.toOwnedSlice(self.allocator),
        };
    }

    fn dedupeThemes(self: *DefaultResourceLoader, loaded_themes: []Theme, loaded_diagnostics: []ResourceDiagnostic) !ThemeLoadResult {
        var themes_out: std.ArrayList(Theme) = .empty;
        errdefer deinitThemeList(self.allocator, &themes_out);
        var diagnostics: std.ArrayList(ResourceDiagnostic) = .empty;
        errdefer deinitDiagnosticList(self.allocator, &diagnostics);
        for (loaded_diagnostics) |diagnostic| try diagnostics.append(self.allocator, diagnostic);
        self.allocator.free(loaded_diagnostics);
        var seen: std.StringHashMapUnmanaged(usize) = .empty;
        defer seen.deinit(self.allocator);
        defer self.allocator.free(loaded_themes);

        for (loaded_themes) |loaded_theme| {
            var moved = loaded_theme;
            if (seen.get(moved.name)) |winner_index| {
                const winner = themes_out.items[winner_index];
                const collision = try ResourceCollision.initAlloc(self.allocator, "theme", moved.name, winner.source_path, moved.source_path);
                const message = try std.fmt.allocPrint(self.allocator, "name \"{s}\" collision", .{moved.name});
                try appendDiagnostic(&diagnostics, self.allocator, .collision, message, moved.source_path, collision);
                moved.deinit();
            } else {
                try seen.put(self.allocator, moved.name, themes_out.items.len);
                try themes_out.append(self.allocator, moved);
            }
        }
        return .{
            .themes = try themes_out.toOwnedSlice(self.allocator),
            .diagnostics = try diagnostics.toOwnedSlice(self.allocator),
        };
    }

    fn findSourceInfoForPath(
        self: *DefaultResourceLoader,
        resource_path: []const u8,
        extra_source_infos: []const SourceInfoEntry,
        resolved_resources: ?[]const package_manager.ResolvedResource,
    ) ?SourceInfo {
        _ = self;
        for (extra_source_infos) |entry| {
            if (isUnderPath(resource_path, entry.path)) {
                return source_info.createSourceInfo(resource_path, entry.metadata);
            }
        }
        if (resolved_resources) |resources| {
            for (resources) |resource| {
                if (isUnderPath(resource_path, resource.path)) {
                    return source_info.createSourceInfo(resource_path, resource.metadata);
                }
                if (resource.metadata.base_dir) |base_dir| {
                    if (isUnderPath(resource_path, base_dir)) {
                        return source_info.createSourceInfo(resource_path, resource.metadata);
                    }
                }
            }
        }
        return null;
    }

    fn getDefaultSourceInfoForPath(self: *DefaultResourceLoader, file_path: []const u8) SourceInfo {
        if (file_path.len >= 2 and file_path[0] == '<' and file_path[file_path.len - 1] == '>') {
            return source_info.createSyntheticSourceInfo(file_path, .{
                .source = "temporary",
            });
        }
        const roots = [_]struct { path: []const u8, scope: source_info.SourceScope }{
            .{ .path = "skills", .scope = .user },
            .{ .path = "prompts", .scope = .user },
            .{ .path = "themes", .scope = .user },
            .{ .path = "extensions", .scope = .user },
        };
        for (roots) |root| {
            const base = std.fs.path.join(self.allocator, &.{ self.agent_dir, root.path }) catch continue;
            defer self.allocator.free(base);
            if (isUnderPath(file_path, base)) {
                return source_info.createSyntheticSourceInfo(file_path, .{
                    .source = "local",
                    .scope = root.scope,
                    .base_dir = base,
                });
            }
        }
        const project_roots = [_][]const u8{ "skills", "prompts", "themes", "extensions" };
        for (project_roots) |root| {
            const base = std.fs.path.join(self.allocator, &.{ self.cwd, config.project_config_dir, root }) catch continue;
            defer self.allocator.free(base);
            if (isUnderPath(file_path, base)) {
                return source_info.createSyntheticSourceInfo(file_path, .{
                    .source = "local",
                    .scope = .project,
                    .base_dir = base,
                });
            }
        }
        return source_info.createSyntheticSourceInfo(file_path, .{
            .source = "local",
            .scope = .temporary,
            .base_dir = std.fs.path.dirname(file_path),
        });
    }

    fn mergePaths(
        self: *DefaultResourceLoader,
        primary: []const []const u8,
        additional: []const []const u8,
    ) ![]const []const u8 {
        var merged: std.ArrayList([]const u8) = .empty;
        errdefer freeStringArray(self.allocator, merged.items);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer deinitStringSet(self.allocator, &seen);
        for (primary) |path| try self.appendMergedPath(&merged, &seen, path);
        for (additional) |path| try self.appendMergedPath(&merged, &seen, path);
        return merged.toOwnedSlice(self.allocator);
    }

    fn appendMergedPath(
        self: *DefaultResourceLoader,
        merged: *std.ArrayList([]const u8),
        seen: *std.StringHashMapUnmanaged(void),
        raw_path: []const u8,
    ) !void {
        const resolved = try paths.resolvePathAlloc(self.allocator, raw_path, self.cwd, .{ .trim = true });
        defer self.allocator.free(resolved);
        const canonical = try paths.canonicalizePathAlloc(self.allocator, self.io, resolved);
        errdefer self.allocator.free(canonical);
        if (seen.contains(canonical)) {
            self.allocator.free(canonical);
            return;
        }
        try seen.put(self.allocator, canonical, {});
        try merged.append(self.allocator, try self.allocator.dupe(u8, resolved));
    }

    fn normalizedPathsFromEntries(self: *DefaultResourceLoader, entries: []const ResourcePathEntry) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer freeStringArray(self.allocator, list.items);
        for (entries) |entry| {
            try list.append(self.allocator, try paths.resolvePathAlloc(self.allocator, entry.path, self.cwd, .{ .trim = true }));
        }
        return list.toOwnedSlice(self.allocator);
    }

    fn extendSourceInfos(
        self: *DefaultResourceLoader,
        target: *[]SourceInfoEntry,
        entries: []const ResourcePathEntry,
    ) !void {
        if (entries.len == 0) return;
        var list: std.ArrayList(SourceInfoEntry) = .empty;
        errdefer deinitSourceInfoEntryList(self.allocator, &list);
        for (target.*) |entry| try list.append(self.allocator, entry);
        self.allocator.free(target.*);
        target.* = &.{};
        for (entries) |entry| {
            const resolved = try paths.resolvePathAlloc(self.allocator, entry.path, self.cwd, .{ .trim = true });
            defer self.allocator.free(resolved);
            try list.append(self.allocator, try SourceInfoEntry.initAlloc(self.allocator, resolved, entry.metadata));
        }
        target.* = try list.toOwnedSlice(self.allocator);
    }

    fn discoverSystemPromptFileAlloc(self: *DefaultResourceLoader) !?[]u8 {
        const project_path = try std.fs.path.join(self.allocator, &.{ self.cwd, config.project_config_dir, "SYSTEM.md" });
        errdefer self.allocator.free(project_path);
        if (statKind(self.io, project_path) == .file) return project_path;
        self.allocator.free(project_path);
        const global_path = try std.fs.path.join(self.allocator, &.{ self.agent_dir, "SYSTEM.md" });
        errdefer self.allocator.free(global_path);
        if (statKind(self.io, global_path) == .file) return global_path;
        self.allocator.free(global_path);
        return null;
    }

    fn discoverAppendSystemPromptFileAlloc(self: *DefaultResourceLoader) !?[]u8 {
        const project_path = try std.fs.path.join(self.allocator, &.{ self.cwd, config.project_config_dir, "APPEND_SYSTEM.md" });
        errdefer self.allocator.free(project_path);
        if (statKind(self.io, project_path) == .file) return project_path;
        self.allocator.free(project_path);
        const global_path = try std.fs.path.join(self.allocator, &.{ self.agent_dir, "APPEND_SYSTEM.md" });
        errdefer self.allocator.free(global_path);
        if (statKind(self.io, global_path) == .file) return global_path;
        self.allocator.free(global_path);
        return null;
    }
};

pub const SkillsSnapshot = struct {
    skills: []Skill,
    diagnostics: []ResourceDiagnostic,
};

pub const PromptsSnapshot = struct {
    prompts: []PromptTemplate,
    diagnostics: []ResourceDiagnostic,
};

pub const ThemesSnapshot = struct {
    themes: []Theme,
    diagnostics: []ResourceDiagnostic,
};

pub const LoadProjectContextFilesOptions = struct {
    cwd: []const u8,
    agent_dir: []const u8,
};

pub fn loadProjectContextFilesAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: LoadProjectContextFilesOptions,
) ![]AgentFile {
    const resolved_cwd = try paths.resolvePathAlloc(allocator, options.cwd, ".", .{});
    defer allocator.free(resolved_cwd);
    const resolved_agent_dir = try paths.resolvePathAlloc(allocator, options.agent_dir, ".", .{});
    defer allocator.free(resolved_agent_dir);
    var files: std.ArrayList(AgentFile) = .empty;
    errdefer deinitAgentFileList(allocator, &files);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer deinitStringSet(allocator, &seen);

    if (try loadContextFileFromDirAlloc(allocator, io, resolved_agent_dir)) |global_context| {
        try seen.put(allocator, try allocator.dupe(u8, global_context.path), {});
        try files.append(allocator, global_context);
    }

    var ancestors: std.ArrayList(AgentFile) = .empty;
    errdefer deinitAgentFileList(allocator, &ancestors);
    var current = try allocator.dupe(u8, resolved_cwd);
    defer allocator.free(current);
    while (true) {
        if (try loadContextFileFromDirAlloc(allocator, io, current)) |context_file| {
            if (seen.contains(context_file.path)) {
                var duplicate = context_file;
                duplicate.deinit();
            } else {
                try seen.put(allocator, try allocator.dupe(u8, context_file.path), {});
                try ancestors.insert(allocator, 0, context_file);
            }
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    for (ancestors.items) |context_file| {
        try files.append(allocator, context_file);
    }
    ancestors.clearRetainingCapacity();
    ancestors.deinit(allocator);
    return files.toOwnedSlice(allocator);
}

const SourceInfoEntry = struct {
    path: []u8,
    metadata: PathMetadata,

    fn initAlloc(allocator: std.mem.Allocator, path: []const u8, metadata: PathMetadata) !SourceInfoEntry {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const owned_source = try allocator.dupe(u8, metadata.source);
        errdefer allocator.free(owned_source);
        const owned_base_dir = if (metadata.base_dir) |base_dir|
            try allocator.dupe(u8, base_dir)
        else
            null;
        errdefer if (owned_base_dir) |base_dir| allocator.free(base_dir);
        return .{
            .path = owned_path,
            .metadata = .{
                .source = owned_source,
                .scope = metadata.scope,
                .origin = metadata.origin,
                .base_dir = owned_base_dir,
            },
        };
    }

    fn deinit(self: *SourceInfoEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(@constCast(self.metadata.source));
        if (self.metadata.base_dir) |base_dir| allocator.free(@constCast(base_dir));
        self.* = undefined;
    }
};

const PromptLoadResult = struct {
    prompts: []PromptTemplate,
    diagnostics: []ResourceDiagnostic,

    fn deinit(self: *PromptLoadResult, allocator: std.mem.Allocator) void {
        prompt_templates.deinitPromptTemplates(allocator, self.prompts);
        skills.deinitDiagnostics(allocator, self.diagnostics);
    }
};

const ThemeLoadResult = struct {
    themes: []Theme,
    diagnostics: []ResourceDiagnostic,

    fn deinit(self: *ThemeLoadResult, allocator: std.mem.Allocator) void {
        theme.deinitThemes(allocator, self.themes);
        skills.deinitDiagnostics(allocator, self.diagnostics);
    }
};

fn loadContextFileFromDirAlloc(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) !?AgentFile {
    const candidates = [_][]const u8{ "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD" };
    for (candidates) |filename| {
        const file_path = try std.fs.path.join(allocator, &.{ dir, filename });
        defer allocator.free(file_path);
        const content = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer allocator.free(content);
        return try AgentFile.initAlloc(allocator, file_path, content);
    }
    return null;
}

fn resolvePromptInputAlloc(allocator: std.mem.Allocator, io: std.Io, input: ?[]const u8) !?[]u8 {
    const source = input orelse return null;
    const content = std.Io.Dir.cwd().readFileAlloc(io, source, allocator, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return @as(?[]u8, try allocator.dupe(u8, source)),
    };
    return @as(?[]u8, content);
}

fn pathsFromResolvedAlloc(
    allocator: std.mem.Allocator,
    resolved: []const package_manager.ResolvedResource,
    only_enabled: bool,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer freeStringArray(allocator, list.items);
    for (resolved) |resource| {
        if (only_enabled and !resource.enabled) continue;
        try list.append(allocator, try allocator.dupe(u8, resource.path));
    }
    return list.toOwnedSlice(allocator);
}

fn appendDiagnostic(
    diagnostics: *std.ArrayList(ResourceDiagnostic),
    allocator: std.mem.Allocator,
    diagnostic_type: skills.DiagnosticType,
    message: []const u8,
    path: []const u8,
    collision: ?ResourceCollision,
) !void {
    var owned_message = message;
    var free_message = false;
    if (diagnostic_type == .collision and std.mem.startsWith(u8, message, "name ")) {
        owned_message = message;
        free_message = true;
    }
    defer if (free_message) allocator.free(@constCast(owned_message));
    try diagnostics.append(allocator, try ResourceDiagnostic.initAlloc(allocator, diagnostic_type, owned_message, path, collision));
}

fn replaceSourceInfoAlloc(allocator: std.mem.Allocator, target: *SourceInfo, replacement: SourceInfo) !void {
    deinitSourceInfo(allocator, target);
    target.* = try cloneSourceInfoAlloc(allocator, replacement);
}

fn cloneSourceInfoAlloc(allocator: std.mem.Allocator, info: SourceInfo) !SourceInfo {
    const owned_path = try allocator.dupe(u8, info.path);
    errdefer allocator.free(owned_path);
    const owned_source = try allocator.dupe(u8, info.source);
    errdefer allocator.free(owned_source);
    const owned_base_dir = if (info.base_dir) |base_dir|
        try allocator.dupe(u8, base_dir)
    else
        null;
    errdefer if (owned_base_dir) |base_dir| allocator.free(base_dir);
    return .{
        .path = owned_path,
        .source = owned_source,
        .scope = info.scope,
        .origin = info.origin,
        .base_dir = owned_base_dir,
    };
}

fn deinitSourceInfo(allocator: std.mem.Allocator, info: *SourceInfo) void {
    allocator.free(@constCast(info.path));
    allocator.free(@constCast(info.source));
    if (info.base_dir) |base_dir| allocator.free(@constCast(base_dir));
}

fn isUnderPath(target: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, target, root)) return true;
    if (!std.mem.startsWith(u8, target, root)) return false;
    return target.len > root.len and (target[root.len] == std.fs.path.sep or target[root.len] == '/');
}

fn statKind(io: std.Io, path: []const u8) ?std.Io.File.Kind {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return null;
    return stat.kind;
}

fn entryKindFollowSymlink(io: std.Io, directory: std.Io.Dir, entry: std.Io.Dir.Entry) ?std.Io.File.Kind {
    return switch (entry.kind) {
        .file, .directory => entry.kind,
        .sym_link, .unknown => blk: {
            const stat = directory.statFile(io, entry.name, .{ .follow_symlinks = true }) catch break :blk null;
            break :blk stat.kind;
        },
        else => null,
    };
}

fn openDirPath(io: std.Io, path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openDirAbsolute(io, path, options);
    return std.Io.Dir.cwd().openDir(io, path, options);
}

fn emptySlice(allocator: std.mem.Allocator, comptime T: type) ![]T {
    return allocator.alloc(T, 0);
}

fn cloneStringArray(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    var cloned = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(cloned);
    for (values, 0..) |value, index| {
        cloned[index] = try allocator.dupe(u8, value);
    }
    return cloned;
}

fn freeStringArray(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(@constCast(value));
    allocator.free(values);
}

fn deinitAgentFiles(allocator: std.mem.Allocator, files: []AgentFile) void {
    for (files) |*file| file.deinit();
    allocator.free(files);
}

fn deinitAgentFileList(allocator: std.mem.Allocator, files: *std.ArrayList(AgentFile)) void {
    for (files.items) |*file| file.deinit();
    files.deinit(allocator);
}

fn deinitExtensionList(allocator: std.mem.Allocator, extensions: *std.ArrayList(LoadedExtension)) void {
    for (extensions.items) |*extension| extension.deinit();
    extensions.deinit(allocator);
}

fn deinitExtensionErrorList(allocator: std.mem.Allocator, errors: *std.ArrayList(ExtensionError)) void {
    for (errors.items) |*extension_error| extension_error.deinit();
    errors.deinit(allocator);
}

fn deinitPromptList(allocator: std.mem.Allocator, prompts: *std.ArrayList(PromptTemplate)) void {
    for (prompts.items) |*prompt| prompt.deinit();
    prompts.deinit(allocator);
}

fn deinitThemeList(allocator: std.mem.Allocator, themes: *std.ArrayList(Theme)) void {
    for (themes.items) |*loaded_theme| loaded_theme.deinit();
    themes.deinit(allocator);
}

fn deinitDiagnosticList(allocator: std.mem.Allocator, diagnostics: *std.ArrayList(ResourceDiagnostic)) void {
    for (diagnostics.items) |*diagnostic| diagnostic.deinit();
    diagnostics.deinit(allocator);
}

fn deinitSourceInfoEntries(allocator: std.mem.Allocator, entries: []SourceInfoEntry) void {
    for (entries) |*entry| entry.deinit(allocator);
    allocator.free(entries);
}

fn deinitSourceInfoEntryList(allocator: std.mem.Allocator, entries: *std.ArrayList(SourceInfoEntry)) void {
    for (entries.items) |*entry| entry.deinit(allocator);
    entries.deinit(allocator);
}

fn deinitStringSet(allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void)) void {
    var it = set.keyIterator();
    while (it.next()) |key| allocator.free(@constCast(key.*));
    set.deinit(allocator);
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

fn writeFile(path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(std.testing.io, parent);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = data,
        .flags = .{ .read = true, .truncate = true },
    });
}

fn writeJoinedFile(allocator: std.mem.Allocator, parts: []const []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(allocator, parts);
    defer allocator.free(path);
    try writeFile(path, data);
}

fn findSkill(loaded_skills: []Skill, name: []const u8) ?*Skill {
    for (loaded_skills) |*loaded_skill| {
        if (std.mem.eql(u8, loaded_skill.name, name)) return loaded_skill;
    }
    return null;
}

fn findPrompt(prompts: []PromptTemplate, name: []const u8) ?*PromptTemplate {
    for (prompts) |*prompt| {
        if (std.mem.eql(u8, prompt.name, name)) return prompt;
    }
    return null;
}

fn findTheme(themes: []Theme, name: []const u8) ?*Theme {
    for (themes) |*loaded_theme| {
        if (std.mem.eql(u8, loaded_theme.name, name)) return loaded_theme;
    }
    return null;
}

test "DefaultResourceLoader initializes empty before reload" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const agent_dir = try std.fs.path.join(allocator, &.{ root, "agent" });
    defer allocator.free(agent_dir);
    const cwd = try std.fs.path.join(allocator, &.{ root, "project" });
    defer allocator.free(cwd);
    try std.Io.Dir.cwd().createDirPath(io, agent_dir);
    try std.Io.Dir.cwd().createDirPath(io, cwd);
    var loader = try DefaultResourceLoader.initAlloc(allocator, io, .{ .cwd = cwd, .agent_dir = agent_dir });
    defer loader.deinit();
    try std.testing.expectEqual(@as(usize, 0), loader.getExtensions().extensions.len);
    try std.testing.expectEqual(@as(usize, 0), loader.getSkills().skills.len);
    try std.testing.expectEqual(@as(usize, 0), loader.getPrompts().prompts.len);
    try std.testing.expectEqual(@as(usize, 0), loader.getThemes().themes.len);
}

test "DefaultResourceLoader discovers skills prompts and project precedence" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const agent_dir = try std.fs.path.join(allocator, &.{ root, "agent" });
    defer allocator.free(agent_dir);
    const cwd = try std.fs.path.join(allocator, &.{ root, "project" });
    defer allocator.free(cwd);
    try std.Io.Dir.cwd().createDirPath(io, agent_dir);
    try std.Io.Dir.cwd().createDirPath(io, cwd);

    const user_prompt = try std.fs.path.join(allocator, &.{ agent_dir, "prompts", "commit.md" });
    defer allocator.free(user_prompt);
    const project_prompt = try std.fs.path.join(allocator, &.{ cwd, ".bulb", "prompts", "commit.md" });
    defer allocator.free(project_prompt);
    try writeFile(user_prompt, "User prompt");
    try writeFile(project_prompt, "Project prompt");

    const user_skill = try std.fs.path.join(allocator, &.{ agent_dir, "skills", "collision-skill", "SKILL.md" });
    defer allocator.free(user_skill);
    const project_skill = try std.fs.path.join(allocator, &.{ cwd, ".bulb", "skills", "collision-skill", "SKILL.md" });
    defer allocator.free(project_skill);
    try writeFile(user_skill, "---\nname: collision-skill\ndescription: user\n---\nUser skill");
    try writeFile(project_skill, "---\nname: collision-skill\ndescription: project\n---\nProject skill");

    const user_theme = try std.fs.path.join(allocator, &.{ agent_dir, "themes", "collision.json" });
    defer allocator.free(user_theme);
    const project_theme = try std.fs.path.join(allocator, &.{ cwd, ".bulb", "themes", "collision.json" });
    defer allocator.free(project_theme);
    try writeFile(user_theme, "{\"name\":\"collision-theme\",\"colors\":{\"accent\":\"#00ffff\"}}");
    try writeFile(project_theme, "{\"name\":\"collision-theme\",\"colors\":{\"accent\":\"#ff00ff\"}}");

    const extra_skill_dir = try std.fs.path.join(allocator, &.{ agent_dir, "skills", "browser-tools" });
    defer allocator.free(extra_skill_dir);
    const extra_skill = try std.fs.path.join(allocator, &.{ extra_skill_dir, "SKILL.md" });
    defer allocator.free(extra_skill);
    const ignored_md = try std.fs.path.join(allocator, &.{ extra_skill_dir, "EFFICIENCY.md" });
    defer allocator.free(ignored_md);
    try writeFile(extra_skill, "---\nname: browser-tools\ndescription: Browser tools\n---\nSkill content");
    try writeFile(ignored_md, "No frontmatter here");

    var loader = try DefaultResourceLoader.initAlloc(allocator, io, .{ .cwd = cwd, .agent_dir = agent_dir });
    defer loader.deinit();
    try loader.reload();

    const prompt = findPrompt(loader.getPrompts().prompts, "commit").?;
    try std.testing.expectEqualStrings(project_prompt, prompt.file_path);
    const skill = findSkill(loader.getSkills().skills, "collision-skill").?;
    try std.testing.expectEqualStrings(project_skill, skill.file_path);
    try std.testing.expect(findSkill(loader.getSkills().skills, "browser-tools") != null);
    for (loader.getSkills().diagnostics) |diagnostic| {
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.path, "EFFICIENCY.md") == null);
    }
    const loaded_theme = findTheme(loader.getThemes().themes, "collision-theme").?;
    try std.testing.expectEqualStrings(project_theme, loaded_theme.source_path);
}

test "DefaultResourceLoader honors settings overrides and no flags" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const agent_dir = try std.fs.path.join(allocator, &.{ root, "agent" });
    defer allocator.free(agent_dir);
    const cwd = try std.fs.path.join(allocator, &.{ root, "project" });
    defer allocator.free(cwd);
    try std.Io.Dir.cwd().createDirPath(io, agent_dir);
    try std.Io.Dir.cwd().createDirPath(io, cwd);
    try writeJoinedFile(allocator, &.{ agent_dir, "skills", "skip-skill", "SKILL.md" }, "---\nname: skip-skill\ndescription: Skip me\n---\nContent");
    try writeJoinedFile(allocator, &.{ agent_dir, "prompts", "skip.md" }, "Skip prompt");
    try writeJoinedFile(allocator, &.{ agent_dir, "themes", "skip.json" }, "{\"name\":\"skip\",\"colors\":{\"accent\":\"#00ffff\"}}");

    var manager = try settings_manager.SettingsManager.create(allocator, io, cwd, agent_dir);
    defer manager.deinit();
    try manager.setSkillPaths(&.{"-skills/skip-skill"});
    try manager.setPromptTemplatePaths(&.{"-prompts/skip.md"});
    try manager.setThemePaths(&.{"-themes/skip.json"});
    var loader = try DefaultResourceLoader.initAlloc(allocator, io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .settings_manager = &manager,
    });
    defer loader.deinit();
    try loader.reload();
    try std.testing.expect(findSkill(loader.getSkills().skills, "skip-skill") == null);
    try std.testing.expect(findPrompt(loader.getPrompts().prompts, "skip") == null);
    try std.testing.expect(findTheme(loader.getThemes().themes, "skip") == null);

    var no_skills_loader = try DefaultResourceLoader.initAlloc(allocator, io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .no_skills = true,
    });
    defer no_skills_loader.deinit();
    try no_skills_loader.reload();
    try std.testing.expectEqual(@as(usize, 0), no_skills_loader.getSkills().skills.len);
}

test "DefaultResourceLoader loads context and system prompt files from Bulb paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const agent_dir = try std.fs.path.join(allocator, &.{ root, "agent" });
    defer allocator.free(agent_dir);
    const cwd = try std.fs.path.join(allocator, &.{ root, "project", "nested" });
    defer allocator.free(cwd);
    try std.Io.Dir.cwd().createDirPath(io, agent_dir);
    try std.Io.Dir.cwd().createDirPath(io, cwd);
    const project_root = try std.fs.path.join(allocator, &.{ root, "project" });
    defer allocator.free(project_root);
    try writeJoinedFile(allocator, &.{ agent_dir, "AGENTS.md" }, "# Global Guidelines");
    try writeJoinedFile(allocator, &.{ project_root, "AGENTS.md" }, "# Project Guidelines");
    try writeJoinedFile(allocator, &.{ cwd, ".bulb", "SYSTEM.md" }, "You are a helpful assistant.");
    try writeJoinedFile(allocator, &.{ cwd, ".bulb", "APPEND_SYSTEM.md" }, "Additional instructions.");

    var loader = try DefaultResourceLoader.initAlloc(allocator, io, .{ .cwd = cwd, .agent_dir = agent_dir });
    defer loader.deinit();
    try loader.reload();
    try std.testing.expectEqual(@as(usize, 2), loader.getAgentsFiles().len);
    try std.testing.expectEqualStrings("You are a helpful assistant.", loader.getSystemPrompt().?);
    try std.testing.expectEqual(@as(usize, 1), loader.getAppendSystemPrompt().len);
    try std.testing.expectEqualStrings("Additional instructions.", loader.getAppendSystemPrompt()[0]);

    var no_context_loader = try DefaultResourceLoader.initAlloc(allocator, io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .no_context_files = true,
    });
    defer no_context_loader.deinit();
    try no_context_loader.reload();
    try std.testing.expectEqual(@as(usize, 0), no_context_loader.getAgentsFiles().len);
}

test "DefaultResourceLoader extendResources loads extension metadata and file URLs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const agent_dir = try std.fs.path.join(allocator, &.{ root, "agent" });
    defer allocator.free(agent_dir);
    const cwd = try std.fs.path.join(allocator, &.{ root, "project" });
    defer allocator.free(cwd);
    try std.Io.Dir.cwd().createDirPath(io, agent_dir);
    try std.Io.Dir.cwd().createDirPath(io, cwd);

    const extra_skill_dir = try std.fs.path.join(allocator, &.{ root, "extra skills", "file-url-skill" });
    defer allocator.free(extra_skill_dir);
    const skill_path = try std.fs.path.join(allocator, &.{ extra_skill_dir, "SKILL.md" });
    defer allocator.free(skill_path);
    try writeFile(skill_path, "---\nname: file-url-skill\ndescription: File URL skill\n---\nExtra content");
    const extra_prompt_dir = try std.fs.path.join(allocator, &.{ root, "extra-prompts" });
    defer allocator.free(extra_prompt_dir);
    const prompt_path = try std.fs.path.join(allocator, &.{ extra_prompt_dir, "extra.md" });
    defer allocator.free(prompt_path);
    try writeFile(prompt_path, "---\ndescription: Extra prompt\n---\nExtra prompt content");

    var loader = try DefaultResourceLoader.initAlloc(allocator, io, .{ .cwd = cwd, .agent_dir = agent_dir });
    defer loader.deinit();
    try loader.reload();
    const file_url_skill = try std.fmt.allocPrint(allocator, "file://{s}", .{extra_skill_dir});
    defer allocator.free(file_url_skill);
    try loader.extendResources(.{
        .skill_paths = &.{
            .{
                .path = file_url_skill,
                .metadata = .{
                    .source = "extension:file-url",
                    .scope = .temporary,
                    .origin = .top_level,
                    .base_dir = extra_skill_dir,
                },
            },
        },
        .prompt_paths = &.{
            .{
                .path = prompt_path,
                .metadata = .{
                    .source = "extension:extra",
                    .scope = .temporary,
                    .origin = .top_level,
                    .base_dir = extra_prompt_dir,
                },
            },
        },
    });

    const loaded_skill = findSkill(loader.getSkills().skills, "file-url-skill").?;
    try std.testing.expectEqualStrings(skill_path, loaded_skill.file_path);
    try std.testing.expectEqualStrings("extension:file-url", loaded_skill.source_info.source);
    const loaded_prompt = findPrompt(loader.getPrompts().prompts, "extra").?;
    try std.testing.expectEqualStrings("extension:extra", loaded_prompt.source_info.source);
}
