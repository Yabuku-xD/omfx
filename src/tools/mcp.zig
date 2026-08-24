const std = @import("std");
const Io = std.Io;
const settings = @import("../core/settings.zig");
const sse = @import("../providers/sse.zig");

const deadline = @import("deadline.zig");

const log = std.log.scoped(.mcp);

/// A tool listing or a single call, not a session. A server that needs longer
/// than this to answer one request is not one the loop can wait on.
pub const mcp_secs: u32 = 30;

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    action: []const u8,
    name: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    var cfg = settings.load(allocator, io, home);
    defer cfg.deinit(allocator);
    if (cfg.mcp.len == 0) {
        return allocator.dupe(u8, "mcp: no servers. Add {\"mcp\":[{\"name\":\"fs\",\"command\":\"npx\",\"args\":[\"-y\",\"@modelcontextprotocol/server-filesystem\",\".\"]}]} to ~/.omfx/settings.json\n");
    }
    if (std.mem.eql(u8, action, "list") or action.len == 0) {
        return listAll(allocator, io, cfg.mcp);
    }
    if (std.mem.eql(u8, action, "call")) {
        if (name.len == 0) return allocator.dupe(u8, "mcp: call needs name\n");
        const pair = splitName(name);
        const server = findServer(cfg.mcp, pair.server) orelse {
            if (cfg.mcp.len == 1) return callTool(allocator, io, cfg.mcp[0], pair.tool, arguments_json);
            return std.fmt.allocPrint(allocator, "mcp: unknown server in '{s}'\n", .{name});
        };
        return callTool(allocator, io, server, pair.tool, arguments_json);
    }
    return allocator.dupe(u8, "mcp: action list|call\n");
}

const NamePair = struct { server: []const u8, tool: []const u8 };

fn splitName(name: []const u8) NamePair {
    if (std.mem.indexOfScalar(u8, name, '/')) |i| {
        return .{ .server = name[0..i], .tool = name[i + 1 ..] };
    }
    return .{ .server = "", .tool = name };
}

fn findServer(servers: []const settings.McpServer, id: []const u8) ?settings.McpServer {
    if (id.len == 0) return null;
    for (servers) |s| {
        if (std.mem.eql(u8, s.name, id)) return s;
    }
    return null;
}

fn listAll(allocator: std.mem.Allocator, io: Io, servers: []const settings.McpServer) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "mcp tools (call by server/name; schemas stay off the prompt):\n");
    for (servers) |s| {
        const blob = session(allocator, io, s, "tools/list", "{}") catch |err|
            try std.fmt.allocPrint(allocator, "{s}: {s}\n", .{ s.name, @errorName(err) });
        defer allocator.free(blob);
        try out.appendSlice(allocator, s.name);
        try out.appendSlice(allocator, ": ");
        try out.appendSlice(allocator, blob);
        if (blob.len == 0 or blob[blob.len - 1] != '\n') try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn callTool(
    allocator: std.mem.Allocator,
    io: Io,
    server: settings.McpServer,
    tool_name: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    const args = if (arguments_json.len > 0) arguments_json else "{}";
    const params = try std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\",\"arguments\":{s}}}", .{ tool_name, args });
    defer allocator.free(params);
    return session(allocator, io, server, "tools/call", params);
}

fn session(
    allocator: std.mem.Allocator,
    io: Io,
    server: settings.McpServer,
    method: []const u8,
    params: []const u8,
) ![]u8 {
    var argv_buf: [10][]const u8 = undefined;
    argv_buf[0] = server.command;
    var n: usize = 1;
    var i: usize = 0;
    while (i < server.argv_n and n < argv_buf.len) : (i += 1) {
        argv_buf[n] = server.argv[i];
        n += 1;
    }
    // An MCP server is an arbitrary user-configured command. If it starts but
    // never answers, readJson blocks on takeDelimiterExclusive forever; killing
    // the process closes the pipe and unblocks the read.
    var cap: deadline.Capped = undefined;
    cap.init(argv_buf[0..n], mcp_secs);
    var child = std.process.spawn(io, .{
        .argv = cap.slice(),
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch {
        return std.fmt.allocPrint(allocator, "mcp: spawn failed ({s})", .{server.command});
    };
    defer {
        child.kill(io);
        _ = child.wait(io) catch |err| {
            log.debug("wait: {s}", .{@errorName(err)});
        };
    }

    const init_body =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"omfx","version":"0.0.1"}}}
    ;
    try writeLine(io, child.stdin, init_body);
    const init_reply = try readJson(allocator, io, child.stdout);
    defer allocator.free(init_reply);
    try writeLine(io, child.stdin, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    const req = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"{s}\",\"params\":{s}}}",
        .{ method, params },
    );
    defer allocator.free(req);
    try writeLine(io, child.stdin, req);
    return readJson(allocator, io, child.stdout);
}

fn writeLine(io: Io, file: ?Io.File, line: []const u8) !void {
    const f = file orelse return error.McpStdin;
    var buf: [256]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(line);
    try w.interface.writeByte('\n');
    try w.interface.flush();
}

fn readJson(allocator: std.mem.Allocator, io: Io, file: ?Io.File) ![]u8 {
    const f = file orelse return error.McpStdout;
    var buf: [4096]u8 = undefined;
    var reader = Io.File.Reader.initStreaming(f, io, &buf);
    var collected: std.ArrayList(u8) = .empty;
    errdefer collected.deinit(allocator);
    var n: usize = 0;
    while (n < 32) : (n += 1) {
        const line = reader.interface.takeDelimiterExclusive('\n') catch break;
        const t = std.mem.trim(u8, line, " \r");
        if (t.len == 0) continue;
        if (std.mem.startsWith(u8, t, "Content-Length:")) continue;
        if (t[0] != '{') continue;
        try collected.appendSlice(allocator, t);
        if (std.mem.indexOf(u8, t, "\"result\"") != null or std.mem.indexOf(u8, t, "\"error\"") != null) {
            return collected.toOwnedSlice(allocator);
        }
        collected.clearRetainingCapacity();
    }
    if (collected.items.len == 0) return allocator.dupe(u8, "mcp: empty reply");
    return collected.toOwnedSlice(allocator);
}

test "split server/tool" {
    const p = splitName("fs/read_file");
    try std.testing.expectEqualStrings("fs", p.server);
    try std.testing.expectEqualStrings("read_file", p.tool);
    const q = splitName("read_file");
    try std.testing.expectEqualStrings("", q.server);
    try std.testing.expectEqualStrings("read_file", q.tool);
}
