const std = @import("std");
const Io = std.Io;
const fs = @import("fs.zig");
const undo = @import("undo.zig");
const git_work = @import("git_work.zig");
const bash = @import("bash.zig");
const search = @import("search.zig");
const web = @import("web.zig");
const sse = @import("../providers/sse.zig");
const pathing = @import("pathing.zig");
const settings = @import("../core/settings.zig");
const cdp = @import("cdp.zig");
const tool = @import("../core/tool.zig");
const deadline = @import("deadline.zig");
const jobs = @import("jobs.zig");
const recall = @import("../core/recall.zig");
const hooks = @import("../core/hooks.zig");

/// Tool arguments arrive as JSON *string values*: after the provider layer
/// decodes the arguments-as-a-string envelope, `\n` inside a value is still two
/// characters. Decoding it is this type's whole job, and it happens once per
/// argument read so no call site can forget.
///
/// Backed by a scratch arena that dies with the call, so reads stay `?[]const u8`
/// and nothing here has to be freed by hand.
const Args = struct {
    arena: std.mem.Allocator,
    json: []const u8,

    fn str(self: Args, key: []const u8) ?[]const u8 {
        return sse.argString(self.arena, self.json, key);
    }

    fn usize_(self: Args, key: []const u8) ?usize {
        return sse.jsonUsize(self.json, key);
    }

    /// Models send booleans as `true`, `"true"`, or `1`; take all three.
    ///
    /// Scanned here rather than via `jsonAtom`, which only understands quoted
    /// strings and numbers -- a bare `false` came back null, so an explicit
    /// `background: false` silently fell through to the default and detached
    /// the command the model was waiting on.
    fn flag(self: Args, key: []const u8) ?bool {
        if (self.str(key)) |quoted| return wordFlag(quoted);
        var needle_buf: [80]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
        const at = std.mem.indexOf(u8, self.json, needle) orelse return null;
        var i = at + needle.len;
        while (i < self.json.len and self.json[i] == ' ') i += 1;
        const rest = self.json[i..];
        return wordFlag(rest);
    }

    fn wordFlag(v: []const u8) ?bool {
        if (std.mem.startsWith(u8, v, "true") or std.mem.startsWith(u8, v, "1")) return true;
        if (std.mem.startsWith(u8, v, "false") or std.mem.startsWith(u8, v, "0")) return false;
        return null;
    }
};

pub fn run(
    dir: Io.Dir,
    io: Io,
    allocator: std.mem.Allocator,
    workspace: []const u8,
    name: []const u8,
    args_json: []const u8,
    home: []const u8,
) ![]u8 {
    var args_arena = std.heap.ArenaAllocator.init(allocator);
    defer args_arena.deinit();
    const args = Args{ .arena = args_arena.allocator(), .json = args_json };

    if (args.str("path")) |p| {
        if (pathing.isSecret(p)) {
            return std.fmt.allocPrint(allocator, "blocked: secret path ({s}); not a clean result\n", .{p});
        }
    }
    if (args.str("from")) |p| {
        if (pathing.isSecret(p)) {
            return std.fmt.allocPrint(allocator, "blocked: secret path ({s}); not a clean result\n", .{p});
        }
    }
    if (args.str("to")) |p| {
        if (pathing.isSecret(p)) {
            return std.fmt.allocPrint(allocator, "blocked: secret path ({s}); not a clean result\n", .{p});
        }
    }
    const kind = tool.Name.fromSlice(name) orelse return error.UnknownTool;
    return switch (kind) {
        .read => blk: {
            const path = args.str("path") orelse return error.MissingPath;
            const offset = args.usize_("offset") orelse 0;
            const limit = args.usize_("limit") orelse 0;
            const raw = try fs.read(dir, io, allocator, workspace, path);
            defer allocator.free(raw);
            const body = try fs.numberLines(allocator, path, raw, offset, limit);
            errdefer allocator.free(body);
            const symbols = @import("symbols.zig");
            // Outline the file itself, not the numbered view of it.
            const prefix = try symbols.outlinePrefix(allocator, path, raw);
            if (prefix.len == 0) break :blk body;
            defer allocator.free(prefix);
            const joined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, body });
            allocator.free(body);
            break :blk joined;
        },
        .write => blk: {
            const path = args.str("path") orelse return error.MissingPath;
            const contents = args.str("contents") orelse "";
            git_work.beforeMutate(allocator, io, workspace, home);
            undo.recordWrite(allocator, dir, io, workspace, path);
            try fs.write(dir, io, allocator, workspace, path, contents);
            git_work.afterMutate(allocator, io, workspace, home, path);
            break :blk try std.fmt.allocPrint(allocator, "wrote {s}", .{path});
        },
        .edit => blk: {
            const path = args.str("path") orelse return error.MissingPath;
            git_work.beforeMutate(allocator, io, workspace, home);
            if (std.mem.indexOf(u8, args_json, "\"edits\"") != null) {
                const out = try editsFromJson(allocator, dir, io, workspace, path, args_json);
                git_work.afterMutate(allocator, io, workspace, home, path);
                break :blk out;
            }
            undo.recordWrite(allocator, dir, io, workspace, path);
            if (args.str("symbol")) |symbol| {
                const symbols = @import("symbols.zig");
                const action = symbols.parseAction(args.str("action") orelse "replace") orelse return error.MissingOld;
                const text = args.str("text") orelse args.str("new_string") orelse "";
                try symbols.splice(dir, io, allocator, workspace, path, symbol, action, text);
                git_work.afterMutate(allocator, io, workspace, home, path);
                break :blk try std.fmt.allocPrint(allocator, "edited {s} ({s} {s})", .{ path, @tagName(action), symbol });
            }
            const old = args.str("old_string") orelse return error.MissingOld;
            const new = args.str("new_string") orelse "";
            try fs.edit(dir, io, allocator, workspace, path, old, new);
            git_work.afterMutate(allocator, io, workspace, home, path);
            break :blk try std.fmt.allocPrint(allocator, "edited {s}", .{path});
        },
        .bash => blk: {
            const command = args.str("command") orelse return error.EmptyCommand;
            // Detached by default for anything that does not end: a dev server
            // or a watcher would otherwise burn the whole budget and return
            // nothing. The model can force either mode.
            if (args.flag("background") orelse bash.looksUnbounded(command)) {
                break :blk try bash.runBackground(allocator, io, workspace, command);
            }
            var cfg = settings.load(allocator, io, home);
            defer cfg.deinit(allocator);
            const secs: u32 = if (args.usize_("timeout")) |t| @intCast(@min(t, 100_000)) else deadline.default_secs;
            break :blk try bash.runFor(allocator, io, workspace, command, !settings.sandboxOff(cfg), secs);
        },
        .job => blk: {
            const id = args.usize_("id") orelse return error.MissingPath;
            if (args.flag("kill") orelse false) {
                break :blk try std.fmt.allocPrint(allocator, "{s}\n", .{
                    if (jobs.kill(id)) "killed" else "no such job",
                });
            }
            break :blk try jobs.poll(allocator, io, workspace, id);
        },
        .read_result => blk: {
            // id forms: "r3" / "3" (recall), "job:5" (background log).
            const id_s = args.str("id") orelse return error.MissingPath;
            if (std.mem.startsWith(u8, id_s, "job:")) {
                const n = std.fmt.parseInt(usize, id_s["job:".len..], 10) catch
                    break :blk try allocator.dupe(u8, "read_result: bad job id\n");
                const path = try jobs.logRel(allocator, n);
                defer allocator.free(path);
                const raw = fs.read(dir, io, allocator, workspace, path) catch
                    break :blk try std.fmt.allocPrint(allocator, "read_result: no job log for {d}\n", .{n});
                defer allocator.free(raw);
                if (hooks.hasSecret(raw)) {
                    break :blk try allocator.dupe(u8, "read_result: sensitive; not shown\n");
                }
                break :blk try hooks.mask(allocator, raw);
            }
            var digits = id_s;
            if (digits.len > 0 and (digits[0] == 'r' or digits[0] == 'R')) digits = digits[1..];
            const n = std.fmt.parseInt(u16, digits, 10) catch
                break :blk try allocator.dupe(u8, "read_result: id is rN or job:N\n");
            const body = recall.load(allocator, dir, io, @enumFromInt(n)) catch
                break :blk try std.fmt.allocPrint(allocator, "read_result: no archive r{d}\n", .{n});
            defer allocator.free(body);
            // Hand-edited archives can still hold secrets; never replay them.
            if (hooks.hasSecret(body)) {
                break :blk try allocator.dupe(u8, "read_result: sensitive; not shown\n");
            }
            break :blk try hooks.mask(allocator, body);
        },
        .glob => search.glob(
            dir,
            io,
            allocator,
            workspace,
            args.str("pattern") orelse "*",
            args.str("path") orelse "",
        ),
        .grep => blk: {
            const needle = args.str("pattern") orelse args.str("needle") orelse return error.EmptyNeedle;
            const g = args.str("glob") orelse "*";
            const root = args.str("path") orelse "";
            break :blk try search.grep(dir, io, allocator, workspace, needle, g, root);
        },
        .delete => blk: {
            const path = args.str("path") orelse return error.MissingPath;
            if (path.len == 0) return error.MissingPath;
            try pathing.assertInside(workspace, path);
            git_work.beforeMutate(allocator, io, workspace, home);
            undo.recordDelete(allocator, dir, io, workspace, path);
            dir.deleteFile(io, path) catch try dir.deleteDir(io, path);
            git_work.afterMutate(allocator, io, workspace, home, path);
            break :blk try std.fmt.allocPrint(allocator, "deleted {s}", .{path});
        },
        .rename => blk: {
            const from = args.str("from") orelse args.str("path") orelse return error.MissingPath;
            const to = args.str("to") orelse return error.MissingPath;
            if (from.len == 0 or to.len == 0) return error.MissingPath;
            git_work.beforeMutate(allocator, io, workspace, home);
            undo.recordRename(allocator, dir, io, workspace, from, to);
            try search.rename(dir, io, workspace, from, to);
            git_work.afterMutate(allocator, io, workspace, home, to);
            break :blk try std.fmt.allocPrint(allocator, "renamed {s} -> {s}", .{ from, to });
        },
        .list => fs.list(dir, io, allocator, workspace, args.str("path") orelse "."),
        .copy => blk: {
            const from = args.str("from") orelse args.str("path") orelse return error.MissingPath;
            const to = args.str("to") orelse return error.MissingPath;
            if (from.len == 0 or to.len == 0) return error.MissingPath;
            git_work.beforeMutate(allocator, io, workspace, home);
            undo.recordWrite(allocator, dir, io, workspace, to);
            try fs.copy(dir, io, workspace, from, to);
            git_work.afterMutate(allocator, io, workspace, home, to);
            break :blk try std.fmt.allocPrint(allocator, "copied {s} -> {s}", .{ from, to });
        },
        .mkdir => blk: {
            const path = args.str("path") orelse return error.MissingPath;
            if (path.len == 0) return error.MissingPath;
            try fs.mkdir(dir, io, workspace, path);
            break :blk try std.fmt.allocPrint(allocator, "mkdir {s}", .{path});
        },
        .file_info => blk: {
            const path = args.str("path") orelse return error.MissingPath;
            if (path.len == 0) return error.MissingPath;
            break :blk try fs.info(dir, io, allocator, workspace, path);
        },
        .semantic_search => blk: {
            const q = args.str("query") orelse args.str("q") orelse return error.EmptyNeedle;
            if (q.len == 0) return error.EmptyNeedle;
            break :blk try search.semanticSearch(dir, io, allocator, workspace, q);
        },
        .open_file => blk: {
            const path = args.str("path") orelse return error.MissingPath;
            if (path.len == 0) return error.MissingPath;
            try pathing.assertInside(workspace, path);
            const abs = try pathing.joinWorkspace(allocator, workspace, path);
            defer allocator.free(abs);
            fs.openPath(io, abs);
            break :blk try std.fmt.allocPrint(allocator, "opened {s}", .{path});
        },
        .memory => blk: {
            const action = args.str("action") orelse "list";
            const fact = args.str("fact") orelse args.str("text") orelse "";
            const memory = @import("memory.zig");
            break :blk try memory.run(allocator, io, home, action, fact);
        },
        .web_fetch => blk: {
            const url = args.str("url") orelse return error.InvalidUrl;
            if (url.len == 0) return error.InvalidUrl;
            break :blk try web.fetch(allocator, io, url);
        },
        .web_scrape => blk: {
            const url = args.str("url") orelse return error.InvalidUrl;
            if (url.len == 0) return error.InvalidUrl;
            break :blk try web.scrape(allocator, io, url);
        },
        .web_search => blk: {
            const q = args.str("query") orelse args.str("q") orelse return error.EmptyQuery;
            if (q.len == 0) return error.EmptyQuery;
            const web_search = @import("web_search.zig");
            break :blk try web_search.searchFromHome(allocator, io, home, q);
        },
        .browser => blk: {
            var cfg = settings.load(allocator, io, home);
            defer cfg.deinit(allocator);
            break :blk try cdp.run(allocator, io, args_json, settings.cdpPort(cfg));
        },
        .ask_user => allocator.dupe(u8, "ask_user: harness waits on the TTY; not available via dispatch\n"),
        .peer => allocator.dupe(u8, "peer: harness spawns the teammate; not available via dispatch\n"),
        .board => blk: {
            const action = args.str("action") orelse "read";
            const line = args.str("line") orelse args.str("text") orelse "";
            const b = @import("../core/board.zig");
            break :blk try b.run(allocator, io, workspace, action, line);
        },
        .todo => blk: {
            const todos = @import("../core/todos.zig");
            break :blk try todos.set(allocator, args_json);
        },
        .patch => blk: {
            const spec = args.str("patch") orelse args.str("spec") orelse return error.EmptyPatch;
            const patch = @import("patch.zig");
            git_work.beforeMutate(allocator, io, workspace, home);
            const out = try patch.apply(allocator, dir, io, workspace, spec);
            git_work.afterMutate(allocator, io, workspace, home, "patch");
            break :blk out;
        },
        .mcp => blk: {
            const action = args.str("action") orelse "list";
            const n = args.str("name") orelse "";
            const arguments = args.str("arguments") orelse "{}";
            const mcp = @import("mcp.zig");
            break :blk try mcp.run(allocator, io, home, action, n, arguments);
        },
        .compact => allocator.dupe(u8, "compact: harness ARC; cites at .omfx/recall; never encrypted\n"),
    };
}

/// `edits: [{old_string, new_string}, ...]`. The scanner elsewhere in this file
/// finds one key at a time and cannot walk an array, so this is the one place
/// that needs a real parser.
///
/// Parsing and applying share a scope on purpose: the edit strings are owned by
/// the parse tree, so the apply has to finish before it is torn down.
fn editsFromJson(
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    io: Io,
    workspace: []const u8,
    path: []const u8,
    args_json: []const u8,
) ![]u8 {
    const patch = @import("patch.zig");
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch
        return error.BadEdits;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadEdits,
    };
    const arr = switch (root.get("edits") orelse return error.BadEdits) {
        .array => |a| a,
        else => return error.BadEdits,
    };
    if (arr.items.len == 0) return error.BadEdits;
    if (arr.items.len > patch.max_ops) return error.TooManyEdits;

    var list: [patch.max_ops]patch.Edit = undefined;
    for (arr.items, 0..) |item, i| {
        const obj = switch (item) {
            .object => |o| o,
            else => return error.BadEdits,
        };
        const old = switch (obj.get("old_string") orelse obj.get("old") orelse return error.BadEdits) {
            .string => |v| v,
            else => return error.BadEdits,
        };
        const new = switch (obj.get("new_string") orelse obj.get("new") orelse std.json.Value{ .string = "" }) {
            .string => |v| v,
            else => return error.BadEdits,
        };
        list[i] = .{ .old = old, .new = new };
    }
    return patch.applyEdits(allocator, dir, io, workspace, path, list[0..arr.items.len]);
}

test "dispatch read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", "a.txt", "hello");
    const out = try run(tmp.dir, io, std.testing.allocator, "ws", "read", "{\"path\":\"a.txt\"}", "");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("     1\thello\n", out);
}

test "read_result redacts secret-shaped recall bodies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try tmp.dir.createDirPath(io, ".omfx/recall");
    {
        var f = try tmp.dir.createFile(io, ".omfx/recall/r1.txt", .{ .truncate = true });
        defer f.close(io);
        var buf: [128]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("tool=bash path= chars=40\napi_key=sk-secret-e2e-not-for-disk\n");
        try w.interface.flush();
    }
    const out = try run(tmp.dir, io, a, "ws", "read_result", "{\"id\":\"r1\"}", "");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "sensitive") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sk-secret-e2e") == null);
}

test "read_result returns a non-secret recall body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try tmp.dir.createDirPath(io, ".omfx/recall");
    {
        var f = try tmp.dir.createFile(io, ".omfx/recall/r1.txt", .{ .truncate = true });
        defer f.close(io);
        var buf: [128]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("tool=bash path= chars=12\nE2E_RECALL_OK\n");
        try w.interface.flush();
    }
    const out = try run(tmp.dir, io, a, "ws", "read_result", "{\"id\":\"r1\"}", "");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "E2E_RECALL_OK") != null);
}

test "dispatch read pages with offset and limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", "a.txt", "one\ntwo\nthree\nfour\n");
    const out = try run(tmp.dir, io, std.testing.allocator, "ws", "read", "{\"path\":\"a.txt\",\"offset\":2,\"limit\":2}", "");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "     2\ttwo") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "     3\tthree") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "one") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "offset=4") != null);

    const past = try run(tmp.dir, io, std.testing.allocator, "ws", "read", "{\"path\":\"a.txt\",\"offset\":99}", "");
    defer std.testing.allocator.free(past);
    try std.testing.expect(std.mem.indexOf(u8, past, "has 4 lines") != null);
}

test "dispatch glob" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", "a.zig", "x");
    const out = try run(tmp.dir, io, std.testing.allocator, "ws", "glob", "{\"pattern\":\"*.zig\"}", "");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "a.zig") != null);
}

test "read prefixes outline without a second tool" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", "a.zig", "pub fn foo() void {}\n");
    const out = try run(tmp.dir, io, std.testing.allocator, "ws", "read", "{\"path\":\"a.zig\"}", "");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "[outline") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "fn foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn foo") != null);
}

test "edit splices a symbol" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", "a.zig", "pub fn foo() void {\n    return;\n}\n");
    const out = try run(tmp.dir, io, std.testing.allocator, "ws", "edit", "{\"path\":\"a.zig\",\"symbol\":\"foo\",\"action\":\"inside\",\"text\":\"    bar();\\n\"}", "");
    defer std.testing.allocator.free(out);
    const got = try fs.read(tmp.dir, io, std.testing.allocator, "ws", "a.zig");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "bar();") != null);
}

test "dispatch list and copy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", "a.txt", "x");
    const listing = try run(tmp.dir, io, std.testing.allocator, "ws", "list", "{\"path\":\".\"}", "");
    defer std.testing.allocator.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "a.txt") != null);
    const copied = try run(tmp.dir, io, std.testing.allocator, "ws", "copy", "{\"from\":\"a.txt\",\"to\":\"b.txt\"}", "");
    defer std.testing.allocator.free(copied);
    const got = try fs.read(tmp.dir, io, std.testing.allocator, "ws", "b.txt");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("x", got);
}

test "dispatch denies .env" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", ".env", "SECRET=1");
    const out = try run(tmp.dir, io, std.testing.allocator, "ws", "read", "{\"path\":\".env\"}", "");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "blocked: secret path") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SECRET") == null);
}

test "edit applies a batch of edits in one call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try fs.write(tmp.dir, io, a, "ws", "a.txt", "one\ntwo\nthree\n");
    const args =
        \\{"path":"a.txt","edits":[{"old_string":"one","new_string":"1"},{"old_string":"three","new_string":"3"}]}
    ;
    const out = try run(tmp.dir, io, a, "ws", "edit", args, "");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "2 hunks") != null);
    const got = try fs.read(tmp.dir, io, a, "ws", "a.txt");
    defer a.free(got);
    try std.testing.expectEqualStrings("1\ntwo\n3\n", got);
}

test "a failed batch leaves the file untouched" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try fs.write(tmp.dir, io, a, "ws", "a.txt", "one\ntwo\n");
    const args =
        \\{"path":"a.txt","edits":[{"old_string":"one","new_string":"1"},{"old_string":"gone","new_string":"x"}]}
    ;
    try std.testing.expectError(error.OldStringNotFound, run(tmp.dir, io, a, "ws", "edit", args, ""));
    const got = try fs.read(tmp.dir, io, a, "ws", "a.txt");
    defer a.free(got);
    try std.testing.expectEqualStrings("one\ntwo\n", got);
}

test "single-string edit still works alongside batches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try fs.write(tmp.dir, io, a, "ws", "a.txt", "hello\n");
    const out = try run(tmp.dir, io, a, "ws", "edit", "{\"path\":\"a.txt\",\"old_string\":\"hello\",\"new_string\":\"bye\"}", "");
    defer a.free(out);
    const got = try fs.read(tmp.dir, io, a, "ws", "a.txt");
    defer a.free(got);
    try std.testing.expectEqualStrings("bye\n", got);
}

test "todo returns the rendered card" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const args =
        \\{"todos":[{"content":"read the parser","status":"completed"},{"content":"add the flag","status":"in_progress"}]}
    ;
    const out = try run(tmp.dir, std.testing.io, a, "ws", "todo", args, "");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Tasks 1/2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "add the flag") != null);
}

// End-to-end argument decoding. Every case here is bytes a model actually sends
// -- JSON string values with escapes -- asserted against bytes on disk. The
// whole class of "the tool fired but the file is wrong" lives in this gap, and
// it stayed open because every other test in this file used escape-free args.

fn wrote(tmp: std.testing.TmpDir, io: Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    return fs.read(tmp.dir, io, a, "ws", path);
}

test "e2e write decodes newlines instead of writing backslash-n" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    const out = try run(tmp.dir, io, a, "ws", "write",
        \\{"path":"m.py","contents":"def f():\n    return 1\n"}
    , "");
    defer a.free(out);
    const got = try wrote(tmp, io, a, "m.py");
    defer a.free(got);
    try std.testing.expectEqualStrings("def f():\n    return 1\n", got);
}

test "e2e write decodes quotes, tabs, and backslashes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    const out = try run(tmp.dir, io, a, "ws", "write",
        \\{"path":"q.py","contents":"s = \"hi\"\n\tt = 'a\\b'\n"}
    , "");
    defer a.free(out);
    const got = try wrote(tmp, io, a, "q.py");
    defer a.free(got);
    try std.testing.expectEqualStrings("s = \"hi\"\n\tt = 'a\\b'\n", got);
}

test "e2e edit matches a multi-line old_string" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try fs.write(tmp.dir, io, a, "ws", "calc.py", "def div(a, b):\n    return a / b\n");
    // The exact shape that returned OldStringNotFound for every real edit.
    const out = try run(tmp.dir, io, a, "ws", "edit",
        \\{"path":"calc.py","old_string":"def div(a, b):\n    return a / b","new_string":"def div(a, b):\n    if b == 0:\n        return None\n    return a / b"}
    , "");
    defer a.free(out);
    const got = try wrote(tmp, io, a, "calc.py");
    defer a.free(got);
    try std.testing.expectEqualStrings(
        "def div(a, b):\n    if b == 0:\n        return None\n    return a / b\n",
        got,
    );
}

test "e2e batch edit decodes every hunk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try fs.write(tmp.dir, io, a, "ws", "t.py", "import os\n\ndef a():\n    pass\n");
    const out = try run(tmp.dir, io, a, "ws", "edit",
        \\{"path":"t.py","edits":[{"old_string":"import os\n","new_string":"import os\nimport sys\n"},{"old_string":"def a():\n    pass","new_string":"def a():\n    return sys.argv"}]}
    , "");
    defer a.free(out);
    const got = try wrote(tmp, io, a, "t.py");
    defer a.free(got);
    try std.testing.expectEqualStrings("import os\nimport sys\n\ndef a():\n    return sys.argv\n", got);
}

test "e2e bash keeps quotes and newlines in the command" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    // bash runs in the workspace, not the tmp dir, so the decode is asserted on
    // what the command printed rather than on a file it wrote.
    const out = try run(Io.Dir.cwd(), io, a, ".", "bash",
        \\{"command":"printf 'one\ntwo\n'; echo \"quoted ok\""}
    , "");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "one\ntwo\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "quoted ok") != null);
    // A literal backslash-n reaching the shell is the bug this guards.
    try std.testing.expect(std.mem.indexOf(u8, out, "\\n") == null);
}

test "e2e patch decodes its whole spec" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try fs.write(tmp.dir, io, a, "ws", "p.py", "x = 1\ny = 2\n");
    const out = try run(tmp.dir, io, a, "ws", "patch",
        \\{"patch":"*** Update File: p.py\nx = 1\n*** To\nx = 42\n"}
    , "");
    defer a.free(out);
    const got = try wrote(tmp, io, a, "p.py");
    defer a.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "x = 42") != null);
}

test "e2e a decoded path is still checked for escape and secrets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    // Decoding must not become a way to smuggle a path past the guard.
    const esc = run(tmp.dir, io, a, "ws", "write",
        \\{"path":"..\/..\/escaped.txt","contents":"x"}
    , "");
    if (esc) |ok| {
        defer a.free(ok);
        return error.TestUnexpectedResult;
    } else |_| {}

    const sec = try run(tmp.dir, io, a, "ws", "write",
        \\{"path":".env","contents":"SECRET=1"}
    , "");
    defer a.free(sec);
    try std.testing.expect(std.mem.indexOf(u8, sec, "blocked") != null);
}

test "e2e round trip: write a file, edit it, read it back numbered" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;

    const w = try run(tmp.dir, io, a, "ws", "write",
        \\{"path":"r.py","contents":"a = 1\nb = 2\n"}
    , "");
    a.free(w);
    const e = try run(tmp.dir, io, a, "ws", "edit",
        \\{"path":"r.py","old_string":"b = 2","new_string":"b = 3"}
    , "");
    a.free(e);
    const r = try run(tmp.dir, io, a, "ws", "read", "{\"path\":\"r.py\"}", "");
    defer a.free(r);
    // Numbered for display; the bytes underneath are the real ones.
    try std.testing.expect(std.mem.indexOf(u8, r, "     1\ta = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "     2\tb = 3") != null);
    const raw = try wrote(tmp, io, a, "r.py");
    defer a.free(raw);
    try std.testing.expectEqualStrings("a = 1\nb = 3\n", raw);
}

test "a dev server detaches instead of burning the budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const ws = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(ws);
    _ = jobs.killAll();
    defer _ = jobs.killAll();

    // Without the default this waits out the whole timeout and returns nothing.
    const out = try run(tmp.dir, std.testing.io, a, ws, "bash",
        \\{"command":"npm run dev"}
    , "");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "started job") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".omfx/jobs/") != null);
}

test "an ordinary command still runs in the foreground" {
    const a = std.testing.allocator;
    const out = try run(Io.Dir.cwd(), std.testing.io, a, ".", "bash",
        \\{"command":"echo foreground-ok"}
    , "");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "foreground-ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "started job") == null);
}

test "background can be forced and refused explicitly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const ws = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(ws);
    _ = jobs.killAll();
    defer _ = jobs.killAll();

    const forced = try run(tmp.dir, std.testing.io, a, ws, "bash",
        \\{"command":"echo hi","background":true}
    , "");
    defer a.free(forced);
    try std.testing.expect(std.mem.indexOf(u8, forced, "started job") != null);

    // An explicit false must beat the default, or the model never sees output.
    // `tail -f` is on the detach list, so this proves the override, and the
    // short timeout keeps a foreground never-ending command from stalling.
    const held = try run(Io.Dir.cwd(), std.testing.io, a, ".", "bash",
        \\{"command":"tail -f /dev/null","background":false,"timeout":2}
    , "");
    defer a.free(held);
    try std.testing.expect(std.mem.indexOf(u8, held, "started job") == null);
}

test "flag reads bare, quoted, and numeric booleans" {
    // Args.str decodes into the scratch arena, so the test needs a real one.
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const a = Args{ .arena = scratch.allocator(), .json =
        \\{"a":true,"b":false,"c":"true","d":0,"e":1}
    };
    try std.testing.expectEqual(@as(?bool, true), a.flag("a"));
    try std.testing.expectEqual(@as(?bool, false), a.flag("b"));
    try std.testing.expectEqual(@as(?bool, true), a.flag("c"));
    try std.testing.expectEqual(@as(?bool, false), a.flag("d"));
    try std.testing.expectEqual(@as(?bool, true), a.flag("e"));
    try std.testing.expectEqual(@as(?bool, null), a.flag("missing"));
}

test "a model-set timeout bounds a runaway command" {
    const a = std.testing.allocator;
    // Without the cap this blocks for 400 seconds.
    const out = try run(Io.Dir.cwd(), std.testing.io, a, ".", "bash",
        \\{"command":"sleep 400","timeout":2}
    , "");
    defer a.free(out);
    try std.testing.expect(out.len > 0);
}

test "job polls and kills a running command" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const ws = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(ws);
    _ = jobs.killAll();
    defer _ = jobs.killAll();

    const started = try run(tmp.dir, std.testing.io, a, ws, "bash",
        \\{"command":"sleep 400","background":true}
    , "");
    a.free(started);
    try std.testing.expectEqual(@as(usize, 1), jobs.count());
    var snap: [jobs.max_jobs]jobs.Job = undefined;
    const id = jobs.snapshot(&snap)[0].id;

    var poll_buf: [64]u8 = undefined;
    const poll_args = try std.fmt.bufPrint(&poll_buf, "{{\"id\":{d}}}", .{id});
    const status = try run(tmp.dir, std.testing.io, a, ws, "job", poll_args, "");
    defer a.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "running") != null);

    var kill_buf: [64]u8 = undefined;
    const kill_args = try std.fmt.bufPrint(&kill_buf, "{{\"id\":{d},\"kill\":true}}", .{id});
    const killed = try run(tmp.dir, std.testing.io, a, ws, "job", kill_args, "");
    defer a.free(killed);
    try std.testing.expect(std.mem.indexOf(u8, killed, "killed") != null);
    try std.testing.expectEqual(@as(usize, 0), jobs.count());
}

// Every dispatch-routed tool, model-shaped JSON, asserted on receipts / disk.
// peer and ask_user stay harness-owned (see executeAdmitted); their dispatch
// stubs must still return a clear string, never UnknownTool.
test "e2e catalog coverage for fs search board memory mcp compact" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;

    // --- write / mkdir / copy / rename / delete / file_info / list ---
    {
        const out = try run(tmp.dir, io, a, "ws", "mkdir",
            \\{"path":"src"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "mkdir") != null);
    }
    {
        const out = try run(tmp.dir, io, a, "ws", "write",
            \\{"path":"src/lib.zig","contents":"pub fn MarkerSymbol() void {}\n"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "wrote") != null);
    }
    {
        const out = try run(tmp.dir, io, a, "ws", "mkdir",
            \\{"path":"src/nested"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "mkdir") != null);
    }
    {
        const out = try run(tmp.dir, io, a, "ws", "copy",
            \\{"from":"src/lib.zig","to":"src/nested/lib2.zig"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "copied") != null);
        const got = try wrote(tmp, io, a, "src/nested/lib2.zig");
        defer a.free(got);
        try std.testing.expect(std.mem.indexOf(u8, got, "MarkerSymbol") != null);
    }
    {
        const out = try run(tmp.dir, io, a, "ws", "rename",
            \\{"from":"src/nested/lib2.zig","to":"src/nested/lib_renamed.zig"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "renamed") != null);
    }
    {
        const out = try run(tmp.dir, io, a, "ws", "file_info",
            \\{"path":"src/lib.zig"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "bytes") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "size=") != null);
    }
    {
        const out = try run(tmp.dir, io, a, "ws", "list",
            \\{"path":"src"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "lib.zig") != null);
    }
    {
        const out = try run(tmp.dir, io, a, "ws", "grep",
            \\{"pattern":"MarkerSymbol","path":"src"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "lib.zig") != null);
    }
    {
        const out = try run(tmp.dir, io, a, "ws", "glob",
            \\{"pattern":"**/*renamed.zig"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "lib_renamed.zig") != null);
    }
    {
        const out = try run(tmp.dir, io, a, "ws", "semantic_search",
            \\{"query":"MarkerSymbol"}
        , "");
        defer a.free(out);
        try std.testing.expect(out.len > 0);
    }
    {
        const out = try run(tmp.dir, io, a, "ws", "delete",
            \\{"path":"src/nested/lib_renamed.zig"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "deleted") != null);
    }

    // --- empty path fail-closed ---
    try std.testing.expectError(error.MissingPath, run(tmp.dir, io, a, "ws", "copy",
        \\{"from":"","to":"x"}
    , ""));
    try std.testing.expectError(error.MissingPath, run(tmp.dir, io, a, "ws", "rename",
        \\{"from":"src/lib.zig","to":""}
    , ""));

    // --- board FACT requires path= (docs) ---
    {
        const bad = try run(tmp.dir, io, a, "ws", "board",
            \\{"action":"post","line":"FACT orphan claim without path"}
        , "");
        defer a.free(bad);
        try std.testing.expect(std.mem.indexOf(u8, bad, "rejected") != null);
        const good = try run(tmp.dir, io, a, "ws", "board",
            \\{"action":"post","line":"FACT path=src/lib.zig MarkerSymbol exists"}
        , "");
        defer a.free(good);
        try std.testing.expect(std.mem.indexOf(u8, good, "FACT") != null);
        const read = try run(tmp.dir, io, a, "ws", "board",
            \\{"action":"read"}
        , "");
        defer a.free(read);
        try std.testing.expect(std.mem.indexOf(u8, read, "MarkerSymbol") != null);
    }

    // --- memory save/list against a temp home ---
    {
        var home_tmp = std.testing.tmpDir(.{});
        defer home_tmp.cleanup();
        // memory.path joins home/.omfx/memory.jsonl — home is the parent of .omfx.
        const home_abs = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &home_tmp.sub_path });
        defer a.free(home_abs);
        const omfx_dir = try std.fs.path.join(a, &.{ home_abs, ".omfx" });
        defer a.free(omfx_dir);
        Io.Dir.cwd().createDirPath(io, omfx_dir) catch {};

        const saved = try run(tmp.dir, io, a, "ws", "memory",
            \\{"action":"save","fact":"e2e-catalog-marker=1"}
        , home_abs);
        defer a.free(saved);
        const listed = try run(tmp.dir, io, a, "ws", "memory",
            \\{"action":"list"}
        , home_abs);
        defer a.free(listed);
        try std.testing.expect(std.mem.indexOf(u8, listed, "e2e-catalog-marker") != null);
    }

    // --- mcp list / compact / peer / ask_user stubs ---
    {
        const mcp_out = try run(tmp.dir, io, a, "ws", "mcp",
            \\{"action":"list"}
        , "");
        defer a.free(mcp_out);
        try std.testing.expect(mcp_out.len > 0);
    }
    {
        const c = try run(tmp.dir, io, a, "ws", "compact", "{}", "");
        defer a.free(c);
        try std.testing.expect(std.mem.indexOf(u8, c, "ARC") != null);
    }
    {
        const p = try run(tmp.dir, io, a, "ws", "peer",
            \\{"goal":"noop"}
        , "");
        defer a.free(p);
        try std.testing.expect(std.mem.indexOf(u8, p, "harness") != null);
    }
    {
        const u = try run(tmp.dir, io, a, "ws", "ask_user",
            \\{"question":"ok?"}
        , "");
        defer a.free(u);
        try std.testing.expect(std.mem.indexOf(u8, u, "TTY") != null);
    }

    // --- open_file receipt ---
    {
        const o = try run(tmp.dir, io, a, "ws", "open_file",
            \\{"path":"src/lib.zig"}
        , "");
        defer a.free(o);
        try std.testing.expect(std.mem.indexOf(u8, o, "opened") != null);
    }

    // --- web_search with empty backends: honest unavailable ---
    {
        var home_tmp = std.testing.tmpDir(.{});
        defer home_tmp.cleanup();
        const home_abs = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &home_tmp.sub_path });
        defer a.free(home_abs);
        Io.Dir.cwd().createDirPath(io, home_abs) catch {};
        const ws = try run(tmp.dir, io, a, "ws", "web_search",
            \\{"query":"bread coding agent"}
        , home_abs);
        defer a.free(ws);
        try std.testing.expect(ws.len > 0);
    }
}
