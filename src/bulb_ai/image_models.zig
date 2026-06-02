const std = @import("std");
const generated = @import("image_models_generated.zig");
const types = @import("types.zig");

pub const ImageModelIterator = struct {
    provider: []const u8,
    index: usize = 0,

    pub fn next(self: *ImageModelIterator) ?*const types.ImageModel {
        while (self.index < generated.image_models.len) {
            const model = &generated.image_models[self.index];
            self.index += 1;
            if (std.mem.eql(u8, model.provider, self.provider)) return model;
        }
        return null;
    }

    pub fn count(self: ImageModelIterator) usize {
        var iterator = self;
        var result: usize = 0;
        while (iterator.next() != null) result += 1;
        return result;
    }
};

pub fn allImageModels() []const types.ImageModel {
    return generated.image_models[0..];
}

pub fn getImageProviders() []const []const u8 {
    return generated.providers[0..];
}

pub fn getImageModels(provider: []const u8) ImageModelIterator {
    return .{ .provider = provider };
}

pub fn getImageModel(provider: []const u8, model_id: []const u8) ?*const types.ImageModel {
    for (&generated.image_models) |*model| {
        if (std.mem.eql(u8, model.provider, provider) and std.mem.eql(u8, model.id, model_id)) {
            return model;
        }
    }
    return null;
}

fn expectStringMembers(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |left, right| {
        try std.testing.expectEqualStrings(left, right);
    }
}

// Ported from packages/ai/src/image-models.ts and packages/ai/test/openrouter-images.test.ts.
test "image registry exposes OpenRouter image models" {
    try std.testing.expectEqual(@as(usize, 1), getImageProviders().len);
    try std.testing.expectEqualStrings("openrouter", getImageProviders()[0]);
    try std.testing.expect(allImageModels().len >= 29);

    const auto = getImageModel("openrouter", "openrouter/auto") orelse return error.ModelMissing;
    try std.testing.expectEqualStrings("Auto Router", auto.name);
    try std.testing.expectEqualStrings("openrouter-images", auto.api);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1", auto.base_url);
    try expectStringMembers(&.{ "text", "image" }, auto.input);
    try expectStringMembers(&.{ "text", "image" }, auto.output);
    try std.testing.expectApproxEqAbs(@as(f64, -1000000), auto.cost.input, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, -1000000), auto.cost.output, 0.000001);

    var iterator = getImageModels("openrouter");
    try std.testing.expectEqual(allImageModels().len, iterator.count());
}

test "image registry returns null for unknown provider or model" {
    try std.testing.expect(getImageModel("openrouter", "missing") == null);
    try std.testing.expect(getImageModel("missing", "openrouter/auto") == null);
}
