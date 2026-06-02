const std = @import("std");

pub const OAuthDeviceCodeInfo = struct {
    user_code: []const u8,
    verification_uri: []const u8,
    interval_seconds: ?f64 = null,
    expires_in_seconds: ?u64 = null,
};

pub const DeviceCodeCallback = struct {
    ptr: ?*anyopaque = null,
    call: *const fn (?*anyopaque, OAuthDeviceCodeInfo) anyerror!void,

    pub fn invoke(self: DeviceCodeCallback, info: OAuthDeviceCodeInfo) !void {
        try self.call(self.ptr, info);
    }
};

pub const OAuthAuthInfo = struct {
    url: []const u8,
    instructions: ?[]const u8 = null,
};

pub const AuthCallback = struct {
    ptr: ?*anyopaque = null,
    call: *const fn (?*anyopaque, OAuthAuthInfo) anyerror!void,

    pub fn invoke(self: AuthCallback, info: OAuthAuthInfo) !void {
        try self.call(self.ptr, info);
    }
};

pub const OAuthPrompt = struct {
    message: []const u8,
    placeholder: ?[]const u8 = null,
    allow_empty: bool = false,
};

pub const PromptCallback = struct {
    ptr: ?*anyopaque = null,
    call: *const fn (?*anyopaque, OAuthPrompt) anyerror![]const u8,

    pub fn invoke(self: PromptCallback, prompt: OAuthPrompt) ![]const u8 {
        return self.call(self.ptr, prompt);
    }
};

pub const ProgressCallback = struct {
    ptr: ?*anyopaque = null,
    call: *const fn (?*anyopaque, []const u8) anyerror!void,

    pub fn invoke(self: ProgressCallback, message: []const u8) !void {
        try self.call(self.ptr, message);
    }
};

pub const ManualCodeInputCallback = struct {
    ptr: ?*anyopaque = null,
    call: *const fn (?*anyopaque) anyerror![]const u8,

    pub fn invoke(self: ManualCodeInputCallback) ![]const u8 {
        return self.call(self.ptr);
    }
};

pub const OAuthSelectOption = struct {
    id: []const u8,
    label: []const u8,
};

pub const OAuthSelectPrompt = struct {
    message: []const u8,
    options: []const OAuthSelectOption,
};

pub const SelectCallback = struct {
    ptr: ?*anyopaque = null,
    call: *const fn (?*anyopaque, OAuthSelectPrompt) anyerror!?[]const u8,

    pub fn invoke(self: SelectCallback, prompt: OAuthSelectPrompt) !?[]const u8 {
        return self.call(self.ptr, prompt);
    }
};

test "OAuth callback wrappers forward native prompt and progress values" {
    const Recorder = struct {
        prompt: ?OAuthPrompt = null,
        progress: ?[]const u8 = null,
        manual_input: []const u8 = "http://localhost/callback?code=manual",

        fn onPrompt(ptr: ?*anyopaque, prompt: OAuthPrompt) anyerror![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.prompt = prompt;
            return "answer";
        }

        fn onProgress(ptr: ?*anyopaque, message: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.progress = message;
        }

        fn onManualCodeInput(ptr: ?*anyopaque) anyerror![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            return self.manual_input;
        }
    };

    var recorder: Recorder = .{};
    const prompt = PromptCallback{ .ptr = &recorder, .call = Recorder.onPrompt };
    try std.testing.expectEqualStrings("answer", try prompt.invoke(.{
        .message = "Question",
        .placeholder = "Placeholder",
        .allow_empty = true,
    }));
    try std.testing.expectEqualStrings("Question", recorder.prompt.?.message);
    try std.testing.expectEqualStrings("Placeholder", recorder.prompt.?.placeholder.?);
    try std.testing.expect(recorder.prompt.?.allow_empty);

    const progress = ProgressCallback{ .ptr = &recorder, .call = Recorder.onProgress };
    try progress.invoke("Working");
    try std.testing.expectEqualStrings("Working", recorder.progress.?);

    const manual_input = ManualCodeInputCallback{ .ptr = &recorder, .call = Recorder.onManualCodeInput };
    try std.testing.expectEqualStrings(recorder.manual_input, try manual_input.invoke());
}
