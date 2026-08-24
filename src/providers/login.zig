const std = @import("std");
const Io = std.Io;
const catalog = @import("catalog.zig");
const auth = @import("auth.zig");
const oauth = @import("oauth.zig");

fn readLine(io: Io, allocator: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    var reader = Io.File.Reader.initStreaming(.stdin(), io, &buf);
    const line = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return error.Canceled,
        else => return err,
    };
    const trimmed = std.mem.trim(u8, line, " \r\t");
    return allocator.dupe(u8, trimmed);
}

fn writeAuth(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    id: []const u8,
    object_json: []const u8,
) ![]u8 {
    try auth.upsertFile(allocator, io, home, id, object_json);
    return auth.path(allocator, home);
}

fn pasteApiKey(allocator: std.mem.Allocator, io: Io, home: []const u8, stdout: *Io.Writer, spec: catalog.Spec) !void {
    try stdout.print("Paste {s} API key (empty to cancel): ", .{spec.name});
    try stdout.flush();
    const key = try readLine(io, allocator);
    defer allocator.free(key);
    if (key.len == 0) return error.Canceled;
    const obj = try std.fmt.allocPrint(allocator, "{{\"type\":\"api_key\",\"key\":\"{s}\"}}", .{key});
    defer allocator.free(obj);
    const store = catalog.storeId(spec);
    const path = try writeAuth(allocator, io, home, store, obj);
    defer allocator.free(path);
    try stdout.print("saved {s} in {s}\n", .{ store, path });
    try stdout.flush();
}

fn objectFromToken(allocator: std.mem.Allocator, tok: oauth.Token) ![]u8 {
    return auth.encodeOAuthObject(allocator, .{
        .access = tok.access,
        .refresh = tok.refresh,
        .expires_at = tok.expires_at,
        .token_endpoint = tok.token_endpoint,
    });
}

fn saveToken(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    stdout: *Io.Writer,
    spec: catalog.Spec,
    tok: oauth.Token,
) !void {
    const obj = try objectFromToken(allocator, tok);
    defer allocator.free(obj);
    const store = catalog.storeId(spec);
    const path = try writeAuth(allocator, io, home, store, obj);
    defer allocator.free(path);
    try stdout.print("saved {s} in {s}\n", .{ store, path });
    try stdout.print("then: ./zig-out/bin/omfx --provider {s}\n", .{store});
    try stdout.flush();
}

fn loginPkce(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    stdout: *Io.Writer,
    spec: catalog.Spec,
    flow: oauth.PkceFlow,
) !void {
    const pkce = try oauth.generatePkce(allocator, io);
    defer pkce.deinit(allocator);
    const url = try oauth.authorizeUrl(allocator, flow, pkce);
    defer allocator.free(url);
    try stdout.print("omfx: {s} login\nOpen {s}\n", .{ spec.name, url });
    try stdout.writeAll("Complete login, then paste the redirect URL or authorization code:\n> ");
    try stdout.flush();
    oauth.openBrowser(io, url);
    const line = try readLine(io, allocator);
    defer allocator.free(line);
    const code = oauth.codeFromInput(line);
    if (code.len == 0) return error.Canceled;
    const http = oauth.Http{ .allocator = allocator, .io = io };
    var tok = try oauth.exchangePkce(http, flow, code, pkce.verifier, pkce.state);
    defer tok.deinit(allocator);
    try saveToken(allocator, io, home, stdout, spec, tok);
}

pub fn saveApiKey(allocator: std.mem.Allocator, io: Io, home: []const u8, id: []const u8, key: []const u8) ![]u8 {
    const obj = try std.fmt.allocPrint(allocator, "{{\"type\":\"api_key\",\"key\":\"{s}\"}}", .{key});
    defer allocator.free(obj);
    return writeAuth(allocator, io, home, id, obj);
}

pub fn pick(input: []const u8) ?catalog.Spec {
    if (std.fmt.parseInt(usize, input, 10)) |n| {
        if (n >= 1 and n <= catalog.all.len) return catalog.all[n - 1];
    } else |_| {}
    return catalog.byId(input);
}

pub fn formatMenu(allocator: std.mem.Allocator, auth_json: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "login  pick a number or id, empty to cancel\n\n");
    for (catalog.all, 0..) |spec, i| {
        const on = auth.extractKey(auth_json, catalog.storeId(spec)) != null or auth.extractKey(auth_json, spec.id) != null;
        const mark: []const u8 = if (on) "✓ configured" else "";
        const kind: []const u8 = switch (spec.login) {
            .api_key => "key",
            .device => "device",
            .pkce => "browser",
        };
        var line_buf: [160]u8 = undefined;
        const line = if (mark.len > 0)
            std.fmt.bufPrint(&line_buf, "  {d: >2}  {s: <22} {s: <8} {s}\n", .{ i + 1, spec.id, kind, mark }) catch continue
        else
            std.fmt.bufPrint(&line_buf, "  {d: >2}  {s: <22} {s}\n", .{ i + 1, spec.id, kind }) catch continue;
        try out.appendSlice(allocator, line);
    }
    try out.appendSlice(allocator, "\nthen paste a key, or complete the browser/device flow.\n");
    return out.toOwnedSlice(allocator);
}

fn printList(stdout: *Io.Writer) !void {
    try stdout.writeAll("omfx login <provider>\n\nOAuth (browser / device code):\n");
    for (catalog.all) |spec| {
        if (spec.login == .api_key) continue;
        try stdout.print("  {s: <24} {s}\n", .{ spec.id, spec.name });
    }
    try stdout.writeAll("\nAPI key (paste):\n");
    for (catalog.all) |spec| {
        if (spec.login != .api_key) continue;
        try stdout.print("  {s: <24} {s}\n", .{ spec.id, spec.name });
    }
    try stdout.writeAll("\nExamples:\n  omfx login xai-oauth\n  omfx login anthropic\n  omfx login groq\n");
}

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    provider_arg: ?[]const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    const name = provider_arg orelse {
        try printList(stdout);
        try stdout.writeAll("\nOr open a session and type /login for the numbered list.\n");
        try stdout.flush();
        return;
    };
    const spec = pick(name) orelse {
        try stderr.print("omfx login: unknown provider '{s}'\nOpen a session and type /login.\n", .{name});
        try stderr.flush();
        return error.UnknownProvider;
    };
    switch (spec.login) {
        .api_key => try pasteApiKey(allocator, io, home, stdout, spec),
        .device => try runDevice(allocator, io, home, stdout, spec),
        .pkce => |kind| try loginPkce(allocator, io, home, stdout, spec, oauth.pkceFlow(kind)),
    }
}

pub const PkceHold = struct {
    id: []const u8,
    verifier: []u8,
    state: []u8,
    url: []u8,

    pub fn deinit(self: PkceHold, allocator: std.mem.Allocator) void {
        allocator.free(self.verifier);
        allocator.free(self.state);
        allocator.free(self.url);
    }
};

pub fn beginPkce(allocator: std.mem.Allocator, io: Io, spec: catalog.Spec) !PkceHold {
    const kind = switch (spec.login) {
        .pkce => |p| p,
        else => return error.UnknownProvider,
    };
    const flow = oauth.pkceFlow(kind);
    const pkce = try oauth.generatePkce(allocator, io);
    errdefer pkce.deinit(allocator);
    const url = try oauth.authorizeUrl(allocator, flow, pkce);
    oauth.openBrowser(io, url);
    allocator.free(pkce.challenge);
    return .{ .id = spec.id, .verifier = pkce.verifier, .state = pkce.state, .url = url };
}

pub fn finishPkce(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    stdout: *Io.Writer,
    hold: PkceHold,
    code_line: []const u8,
) !void {
    const spec = catalog.byId(hold.id) orelse return error.UnknownProvider;
    const kind = switch (spec.login) {
        .pkce => |p| p,
        else => return error.UnknownProvider,
    };
    const flow = oauth.pkceFlow(kind);
    const code = oauth.codeFromInput(code_line);
    if (code.len == 0) return error.Canceled;
    const http = oauth.Http{ .allocator = allocator, .io = io };
    var tok = try oauth.exchangePkce(http, flow, code, hold.verifier, hold.state);
    defer tok.deinit(allocator);
    try saveToken(allocator, io, home, stdout, spec, tok);
}

pub fn runDevice(allocator: std.mem.Allocator, io: Io, home: []const u8, stdout: *Io.Writer, spec: catalog.Spec) !void {
    const kind = switch (spec.login) {
        .device => |d| d,
        else => return error.UnknownProvider,
    };
    const http = oauth.Http{ .allocator = allocator, .io = io };
    var tok = try oauth.loginDevice(http, kind);
    defer tok.deinit(allocator);
    try saveToken(allocator, io, home, stdout, spec, tok);
}

test "login list mentions xai-oauth and anthropic" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try printList(&aw.writer);
    const text = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "xai-oauth") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "anthropic") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "groq") != null);
}

test "formatMenu lists every catalog row and picks by id" {
    const text = try formatMenu(std.testing.allocator, "");
    defer std.testing.allocator.free(text);
    for (catalog.all) |spec| {
        try std.testing.expect(std.mem.indexOf(u8, text, spec.id) != null);
    }
    try std.testing.expectEqualStrings("openai", pick("openai").?.id);
    // A vendor short name reaches its subscription row.
    try std.testing.expectEqualStrings("xai-oauth", pick("xai").?.id);
}
