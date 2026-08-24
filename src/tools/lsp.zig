//! One-shot Language Server Protocol diagnostics.
//!
//! Spawn the language's stdio server, open the file, collect diagnostics, exit.
//! No daemon, no long-lived process, no bundled servers — only what is already
//! on PATH. Cold start is paid once per write; missing binaries are silent.
//!
//! Prefix is `lsp:` so the parse gate (`diagnostics: findings`) never undoes
//! an edit for a type error the model is still fixing.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const langs = @import("../core/langs.zig");
const deadline = @import("deadline.zig");

const log = std.log.scoped(.lsp);

/// Cold rust-analyzer can take several seconds; longer than this and the write
/// loop feels hung. A miss names itself once, then the parse note stands alone.
pub const lsp_secs: u32 = 12;
pub const max_findings: usize = 24;
pub const max_msg_bytes: usize = 160;

pub fn diagnose(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    dir: Io.Dir,
    rel: []const u8,
) !?[]u8 {
    const l = langs.byPath(rel) orelse return null;
    if (l.language_id.len == 0) return null;
    const argv = pickArgv(io, l) orelse return null;

    const abs = try absPath(allocator, workspace, rel);
    defer allocator.free(abs);
    const uri = try fileUri(allocator, abs);
    defer allocator.free(uri);

    const src = dir.readFileAlloc(io, rel, allocator, .limited(2 * 1024 * 1024)) catch return null;
    defer allocator.free(src);

    const escaped = try escapeJson(allocator, src);
    defer allocator.free(escaped);

    var cap: deadline.Capped = undefined;
    cap.init(argv, lsp_secs);
    var child = std.process.spawn(io, .{
        .argv = cap.slice(),
        .cwd = .{ .path = workspace },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    defer {
        child.kill(io);
        _ = child.wait(io) catch |err| {
            log.debug("wait: {s}", .{@errorName(err)});
        };
    }

    const root_uri = try fileUri(allocator, workspace);
    defer allocator.free(root_uri);

    const init = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":1,"method":"initialize","params":{{"processId":null,"rootUri":"{s}","capabilities":{{"textDocument":{{"publishDiagnostics":{{}},"diagnostic":{{}}}}}},"clientInfo":{{"name":"omfx","version":"0.0.1"}}}}}}
    , .{root_uri});
    defer allocator.free(init);
    try writeMsg(io, child.stdin, init);
    const init_reply = try readMsg(allocator, io, child.stdout);
    defer allocator.free(init_reply);
    if (std.mem.indexOf(u8, init_reply, "\"error\"") != null and std.mem.indexOf(u8, init_reply, "\"result\"") == null) {
        return null;
    }

    try writeMsg(io, child.stdin, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");

    const open = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":"{s}","languageId":"{s}","version":1,"text":"{s}"}}}}}}
    , .{ uri, l.language_id, escaped });
    defer allocator.free(open);
    try writeMsg(io, child.stdin, open);

    const pull = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":2,"method":"textDocument/diagnostic","params":{{"textDocument":{{"uri":"{s}"}}}}}}
    , .{uri});
    defer allocator.free(pull);
    try writeMsg(io, child.stdin, pull);

    var diags_json: ?[]u8 = null;
    defer if (diags_json) |d| allocator.free(d);

    var n: usize = 0;
    while (n < 48) : (n += 1) {
        const msg = readMsg(allocator, io, child.stdout) catch break;
        defer allocator.free(msg);
        if (extractDiagnostics(msg, uri)) |blob| {
            if (diags_json) |old| allocator.free(old);
            diags_json = try allocator.dupe(u8, blob);
            break;
        }
        if (std.mem.indexOf(u8, msg, "\"id\":2") != null) {
            if (extractPullResult(msg)) |blob| {
                if (diags_json) |old| allocator.free(old);
                diags_json = try allocator.dupe(u8, blob);
                break;
            }
            // Pull unsupported or empty — keep reading for push.
            continue;
        }
    }

    writeMsg(io, child.stdin, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"shutdown\",\"params\":null}") catch {};
    writeMsg(io, child.stdin, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}") catch {};

    const raw = diags_json orelse {
        return try std.fmt.allocPrint(allocator, "lsp: clean ({s})\n", .{argv[0]});
    };
    return try formatFindings(allocator, argv[0], rel, raw);
}

fn pickArgv(io: Io, l: *const langs.Lang) ?[]const []const u8 {
    if (l.lsp.len > 0 and onPath(io, l.lsp[0])) return l.lsp;
    if (l.lsp_alt.len > 0 and onPath(io, l.lsp_alt[0])) return l.lsp_alt;
    return null;
}

fn onPath(io: Io, bin: []const u8) bool {
    if (std.mem.indexOfScalar(u8, bin, '/') != null) {
        var f = Io.Dir.cwd().openFile(io, bin, .{ .mode = .read_only }) catch return false;
        f.close(io);
        return true;
    }
    const path = std.c.getenv("PATH") orelse return false;
    const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var it = std.mem.splitScalar(u8, std.mem.span(path), sep);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = if (builtin.os.tag == .windows)
            std.fmt.bufPrint(&buf, "{s}/{s}.exe", .{ dir, bin }) catch continue
        else
            std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, bin }) catch continue;
        var f = Io.Dir.cwd().openFile(io, full, .{ .mode = .read_only }) catch continue;
        f.close(io);
        return true;
    }
    return false;
}

fn absPath(allocator: std.mem.Allocator, workspace: []const u8, rel: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(rel)) return allocator.dupe(u8, rel);
    return std.fs.path.join(allocator, &.{ workspace, rel });
}

fn fileUri(allocator: std.mem.Allocator, abs: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "file://");
    for (abs) |c| {
        if (c == ' ') {
            try out.appendSlice(allocator, "%20");
        } else if (c == '\\') {
            try out.append(allocator, '/');
        } else {
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn escapeJson(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (src) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    const s = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c});
                    try out.appendSlice(allocator, s);
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

fn writeMsg(io: Io, file: ?Io.File, body: []const u8) !void {
    const f = file orelse return error.LspStdin;
    var buf: [512]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try w.interface.writeAll(body);
    try w.interface.flush();
}

fn readMsg(allocator: std.mem.Allocator, io: Io, file: ?Io.File) ![]u8 {
    const f = file orelse return error.LspStdout;
    var buf: [8192]u8 = undefined;
    var reader = Io.File.Reader.initStreaming(f, io, &buf);
    var content_len: ?usize = null;
    while (true) {
        const line = reader.interface.takeDelimiterExclusive('\n') catch return error.LspEof;
        const t = std.mem.trim(u8, line, " \r");
        if (t.len == 0) break;
        if (std.mem.startsWith(u8, t, "Content-Length:")) {
            const n = std.mem.trim(u8, t["Content-Length:".len..], " \t");
            content_len = try std.fmt.parseInt(usize, n, 10);
        }
    }
    const len = content_len orelse return error.LspNoLength;
    if (len == 0 or len > 4 * 1024 * 1024) return error.LspBadLength;
    const body = try allocator.alloc(u8, len);
    errdefer allocator.free(body);
    var got: usize = 0;
    while (got < len) {
        const n = reader.interface.readSliceShort(body[got..]) catch |err| switch (err) {
            error.ReadFailed => return error.LspEof,
        };
        if (n == 0) return error.LspEof;
        got += n;
    }
    return body;
}

fn extractDiagnostics(msg: []const u8, uri: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, msg, "publishDiagnostics") == null) return null;
    if (std.mem.indexOf(u8, msg, uri) == null) return null;
    const key = "\"diagnostics\":";
    const start = std.mem.indexOf(u8, msg, key) orelse return null;
    return sliceJsonArray(msg[start + key.len ..]);
}

fn extractPullResult(msg: []const u8) ?[]const u8 {
    // textDocument/diagnostic result: { "kind":"full", "items":[...]} or a bare array.
    if (std.mem.indexOf(u8, msg, "\"items\"")) |at| {
        const colon = std.mem.indexOfScalarPos(u8, msg, at, ':') orelse return null;
        return sliceJsonArray(msg[colon + 1 ..]);
    }
    if (std.mem.indexOf(u8, msg, "\"result\":")) |at| {
        return sliceJsonArray(msg[at + "\"result\":".len ..]);
    }
    return null;
}

fn sliceJsonArray(s: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\n' or s[i] == '\t')) i += 1;
    if (i >= s.len or s[i] != '[') return null;
    var depth: i32 = 0;
    var j = i;
    while (j < s.len) : (j += 1) {
        if (s[j] == '[') depth += 1;
        if (s[j] == ']') {
            depth -= 1;
            if (depth == 0) return s[i .. j + 1];
        }
    }
    return null;
}

fn formatFindings(allocator: std.mem.Allocator, server: []const u8, rel: []const u8, arr: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var n: usize = 0;
    var i: usize = 0;
    while (i < arr.len and n < max_findings) {
        const obj_start = std.mem.indexOfScalarPos(u8, arr, i, '{') orelse break;
        const obj_end = matchingBrace(arr, obj_start) orelse break;
        const obj = arr[obj_start .. obj_end + 1];
        i = obj_end + 1;
        const severity = jsonInt(obj, "severity") orelse 1;
        // 1=error 2=warning 3=info 4=hint — keep errors and warnings only.
        if (severity > 2) continue;
        const line = (jsonInt(obj, "line") orelse jsonNestedLine(obj) orelse 0) + 1;
        const col = (jsonInt(obj, "character") orelse jsonNestedChar(obj) orelse 0) + 1;
        const msg = jsonString(obj, "message") orelse continue;
        const sev = if (severity == 1) "error" else "warning";
        const clip = if (msg.len > max_msg_bytes) msg[0..max_msg_bytes] else msg;
        if (n == 0) try out.print(allocator, "lsp: findings ({s})\n", .{server});
        try out.print(allocator, "{s}:{d}:{d}: {s}: {s}\n", .{ rel, line, col, sev, clip });
        n += 1;
    }
    if (n == 0) return std.fmt.allocPrint(allocator, "lsp: clean ({s})\n", .{server});
    return out.toOwnedSlice(allocator);
}

fn matchingBrace(s: []const u8, start: usize) ?usize {
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    var i = start;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn jsonInt(obj: []const u8, key: []const u8) ?u32 {
    var needle_buf: [48]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, obj, needle) orelse return null;
    var i = start + needle.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t')) i += 1;
    var j = i;
    while (j < obj.len and obj[j] >= '0' and obj[j] <= '9') j += 1;
    if (j == i) return null;
    return std.fmt.parseInt(u32, obj[i..j], 10) catch null;
}

fn jsonString(obj: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [48]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, obj, needle) orelse return null;
    var i = start + needle.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t')) i += 1;
    if (i >= obj.len or obj[i] != '"') return null;
    i += 1;
    const from = i;
    while (i < obj.len) : (i += 1) {
        if (obj[i] == '\\') {
            i += 1;
            continue;
        }
        if (obj[i] == '"') return obj[from..i];
    }
    return null;
}

fn jsonNestedLine(obj: []const u8) ?u32 {
    const range = std.mem.indexOf(u8, obj, "\"range\"") orelse return null;
    const rest = obj[range..];
    return jsonInt(rest, "line");
}

fn jsonNestedChar(obj: []const u8) ?u32 {
    const range = std.mem.indexOf(u8, obj, "\"range\"") orelse return null;
    const rest = obj[range..];
    return jsonInt(rest, "character");
}

test "fileUri escapes spaces" {
    const u = try fileUri(std.testing.allocator, "/tmp/my file.zig");
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings("file:///tmp/my%20file.zig", u);
}

test "escapeJson quotes newlines" {
    const s = try escapeJson(std.testing.allocator, "a\"b\nc");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("a\\\"b\\nc", s);
}

test "formatFindings reads severity and range" {
    const arr =
        \\[{"severity":1,"range":{"start":{"line":2,"character":4}},"message":"expected type"}]
    ;
    const out = try formatFindings(std.testing.allocator, "zls", "main.zig", arr);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "lsp: findings (zls)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "main.zig:3:5: error: expected type") != null);
}
