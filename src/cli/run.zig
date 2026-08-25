const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const config = @import("../core/config.zig");
const catalog = @import("../providers/catalog.zig");

pub const missing_key_text =
    \\Error: NO_PROVIDER: no provider configured
    \\Set a vendor key (ANTHROPIC_API_KEY, OPENAI_API_KEY, GROQ_API_KEY, OPENROUTER_API_KEY, ...)
    \\or OMFX_PROVIDER=ollama for a local host.
    \\
    \\Fix: omfx login
    \\
;

pub const DoctorInfo = struct {
    permission_mode: config.PermissionMode,
    sandbox: []const u8,
    model: []const u8,
    profile_root: []const u8,
    provider: []const u8 = "(unset)",
    catalog: []const u8 = "",
};

pub fn renderDoctor(allocator: std.mem.Allocator, info: DoctorInfo) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\omfx doctor
        \\permission_mode={s}
        \\sandbox={s}
        \\provider={s}
        \\model={s}
        \\profile={s}
        \\catalog={s}
        \\
    , .{
        info.permission_mode.asSlice(),
        info.sandbox,
        info.provider,
        info.model,
        info.profile_root,
        info.catalog,
    });
}

pub fn joinPrompt(allocator: std.mem.Allocator, rest: []const []const u8) ![]u8 {
    if (rest.len == 0) return allocator.dupe(u8, "");
    return std.mem.join(allocator, " ", rest);
}

pub fn sandboxName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "macos",
        else => "none",
    };
}

pub fn doctorText(allocator: std.mem.Allocator, home: []const u8, model: []const u8, provider: []const u8) ![]u8 {
    const profile = try config.profileRoot(allocator, home);
    defer allocator.free(profile);
    const ids = try catalog.idsComma(allocator);
    defer allocator.free(ids);
    return renderDoctor(allocator, .{
        .permission_mode = .auto,
        .sandbox = sandboxName(),
        .model = model,
        .profile_root = profile,
        .provider = provider,
        .catalog = ids,
    });
}

pub fn writeAll(writer: *Io.Writer, bytes: []const u8) !void {
    try writer.writeAll(bytes);
    try writer.flush();
}

test "ask error names env keys" {
    try std.testing.expect(std.mem.indexOf(u8, missing_key_text, "ANTHROPIC_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing_key_text, "GROQ_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing_key_text, "Fix: omfx login") != null);
}

test "join prompt" {
    const parts = [_][]const u8{ "list", "the", "files" };
    const s = try joinPrompt(std.testing.allocator, &parts);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("list the files", s);
}

test "doctor names mode sandbox and model" {
    const text = try renderDoctor(std.testing.allocator, .{
        .permission_mode = .auto,
        .sandbox = "none",
        .model = "(unset)",
        .profile_root = "/Users/demo/.omfx",
        .provider = "(unset)",
        .catalog = "anthropic,openai",
    });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "permission_mode=auto") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sandbox=none") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "model=(unset)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "catalog=anthropic,openai") != null);
}
