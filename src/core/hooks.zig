const std = @import("std");
const Io = std.Io;
const contract_mod = @import("contract.zig");
const tool = @import("tool.zig");
const diag = @import("../tools/diag.zig");
const permissions = @import("permissions.zig");

pub const Phase = enum { pre, post };

pub const Pre = union(enum) {
    allow,
    deny: []const u8,
};

/// Redact secret-shaped assignments in tool output. Inspectable: the key name stays.
pub fn mask(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        const rest = s[i..];
        const hit = secretAt(rest) orelse {
            try out.append(allocator, s[i]);
            i += 1;
            continue;
        };
        try out.appendSlice(allocator, rest[0..hit.from]);
        try out.appendSlice(allocator, rest[hit.from..hit.name_end]);
        try out.appendSlice(allocator, "***");
        i += hit.skip;
    }
    return out.toOwnedSlice(allocator);
}

pub fn hasSecret(s: []const u8) bool {
    return secretAt(s) != null;
}

const Hit = struct { from: usize, name_end: usize, skip: usize };

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn secretAt(s: []const u8) ?Hit {
    const keys = [_][]const u8{ "api_key", "apikey", "api-key", "secret", "token", "password", "passwd" };
    var k: usize = 0;
    while (k < s.len) : (k += 1) {
        if (k > 0 and isIdent(s[k - 1])) continue;
        for (keys) |key| {
            if (k + key.len >= s.len) continue;
            if (!std.ascii.eqlIgnoreCase(s[k .. k + key.len], key)) continue;
            var j = k + key.len;
            while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
            if (j >= s.len or (s[j] != '=' and s[j] != ':')) continue;
            j += 1;
            while (j < s.len and (s[j] == ' ' or s[j] == '\t' or s[j] == '"')) j += 1;
            var end = j;
            while (end < s.len and !std.ascii.isWhitespace(s[end]) and s[end] != '"' and s[end] != '\'') end += 1;
            if (end <= j) continue;
            return .{ .from = k, .name_end = k + key.len, .skip = end };
        }
    }
    return null;
}

pub fn pre(contract: contract_mod.Contract, name: []const u8, args_json: []const u8) Pre {
    const t = tool.Name.fromSlice(name) orelse return .allow;
    return switch (t) {
        .bash => blk: {
            // Decoded first: a `never:` rule matched against the escaped form
            // is matched against something other than what the shell will run.
            var buf: [permissions.max_command]u8 = undefined;
            const command = permissions.shellCommand(&buf, args_json) orelse
                break :blk .{ .deny = "hook: command too long to check; blocked\n" };
            break :blk if (contract.blocksBash(command))
                .{ .deny = "hook: never-run from AGENTS.md; command blocked\n" }
            else
                .allow;
        },
        .todo,
        .job,
        .read_result,
        .read,
        .write,
        .edit,
        .glob,
        .grep,
        .list,
        .copy,
        .mkdir,
        .delete,
        .rename,
        .file_info,
        .open_file,
        .semantic_search,
        .web_fetch,
        .web_scrape,
        .web_search,
        .ask_user,
        .memory,
        .browser,
        .peer,
        .board,
        .mcp,
        .patch,
        .compact,
        => .allow,
    };
}

pub fn post(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    dir: Io.Dir,
    contract: contract_mod.Contract,
    name: []const u8,
    path: ?[]const u8,
    result: []const u8,
) ![]u8 {
    const masked = try mask(allocator, result);
    errdefer allocator.free(masked);
    const t = tool.Name.fromSlice(name) orelse return masked;
    var extra: std.ArrayList(u8) = .empty;
    errdefer extra.deinit(allocator);
    if (t.needsVerify()) {
        if (contract.firstVerify()) |cmd| {
            var v = try diag.runVerifyCmd(allocator, io, workspace, cmd);
            defer v.deinit(allocator);
            const line = try v.render(allocator, cmd);
            defer allocator.free(line);
            try extra.appendSlice(allocator, line);
        } else {
            const v = diag.afterVerify(allocator, io, workspace, dir) catch
                try allocator.dupe(u8, "verify: unavailable (checker failed); not a clean verdict\n");
            defer allocator.free(v);
            try extra.appendSlice(allocator, v);
        }
    }
    if (t.needsAttach()) {
        if (path) |p| {
            const att = try contract_mod.attach(allocator, dir, io, contract, p);
            defer allocator.free(att);
            try extra.appendSlice(allocator, att);
        }
    }
    if (extra.items.len == 0) return masked;
    const joined = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ masked, extra.items });
    allocator.free(masked);
    extra.deinit(allocator);
    return joined;
}

test "mask redacts secret assignments and keeps the key name" {
    const s = try mask(std.testing.allocator, "api_key=sk-secret-value rest");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "sk-secret-value") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "api_key") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "***") != null);
}

test "pre blocks never-run bash" {
    var c = try contract_mod.parse(std.testing.allocator, "## Never\n- `rm -rf`\n");
    defer c.deinit(std.testing.allocator);
    try std.testing.expect(pre(c, "bash", "{\"command\":\"rm -rf /tmp\"}") == .deny);
    try std.testing.expect(pre(c, "bash", "{\"command\":\"zig build test\"}") == .allow);
    try std.testing.expect(pre(c, "read", "{\"path\":\"a.txt\"}") == .allow);
}

test "a never-rule is matched against what the shell will run" {
    var c = try contract_mod.parse(std.testing.allocator, "# Never\n- `rm -rf`\n");
    defer c.deinit(std.testing.allocator);
    try std.testing.expect(c.blocksBash("rm -rf /tmp/x"));
    // The decoded command is what reaches the matcher. Escaping a newline
    // cannot hide a second command from a rule that names it.
    const chained = "{\"command\":\"git status\\\\nrm -rf /tmp/victim\"}";
    switch (pre(c, "bash", chained)) {
        .deny => {},
        .allow => return error.ChainedCommandSlippedPastNeverRule,
    }
    switch (pre(c, "bash", "{\"command\":\"git status\"}")) {
        .allow => {},
        .deny => return error.SafeCommandBlocked,
    }
}

test "an unreadably long command is denied, not passed through" {
    const c = contract_mod.Contract{};
    const long = "x" ** (permissions.max_command + 16);
    const args = "{\"command\":\"" ++ long ++ "\"}";
    switch (pre(c, "bash", args)) {
        .deny => {},
        .allow => return error.UncheckableCommandAllowed,
    }
}
