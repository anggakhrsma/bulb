pub const SourceScope = enum {
    user,
    project,
    temporary,
};

pub const SourceOrigin = enum {
    package,
    top_level,
};

pub const SourceInfo = struct {
    path: []const u8,
    source: []const u8,
    scope: SourceScope,
    origin: SourceOrigin,
    base_dir: ?[]const u8 = null,
};

pub const PathMetadata = struct {
    source: []const u8,
    scope: SourceScope,
    origin: SourceOrigin,
    base_dir: ?[]const u8 = null,
};

pub const SyntheticSourceOptions = struct {
    source: []const u8,
    scope: SourceScope = .temporary,
    origin: SourceOrigin = .top_level,
    base_dir: ?[]const u8 = null,
};

pub fn createSourceInfo(path: []const u8, metadata: PathMetadata) SourceInfo {
    return .{
        .path = path,
        .source = metadata.source,
        .scope = metadata.scope,
        .origin = metadata.origin,
        .base_dir = metadata.base_dir,
    };
}

pub fn createSyntheticSourceInfo(path: []const u8, options: SyntheticSourceOptions) SourceInfo {
    return .{
        .path = path,
        .source = options.source,
        .scope = options.scope,
        .origin = options.origin,
        .base_dir = options.base_dir,
    };
}
