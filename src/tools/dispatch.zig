const std = @import("std");
const Io = std.Io;
const fs = @import("fs.zig");
const pathing = @import("pathing.zig");
const tool = @import("../core/tool.zig");
const fs_dispatch = @import("dispatch/fs.zig");
const shell_dispatch = @import("dispatch/shell.zig");
const web_dispatch = @import("dispatch/web.zig");
const misc_dispatch = @import("dispatch/misc.zig");

pub const Args = @import("dispatch/args.zig").Args;

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
        .read, .write, .edit, .glob, .grep, .delete, .rename, .list, .copy, .mkdir, .file_info => fs_dispatch.run(kind, dir, io, allocator, workspace, home, args, args_json),
        .bash, .job, .read_result => shell_dispatch.run(kind, dir, io, allocator, workspace, home, args),
        .web_fetch, .web_scrape, .web_search, .browser => web_dispatch.run(kind, io, allocator, home, args, args_json),
        .semantic_search, .open_file, .memory, .ask_user, .peer, .board, .todo, .patch, .mcp, .compact => misc_dispatch.run(kind, dir, io, allocator, workspace, home, args, args_json),
    };
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

test "dispatch read on a directory soft-hints list" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try fs.mkdir(tmp.dir, io, "ws", "docs");
    try fs.write(tmp.dir, io, std.testing.allocator, "ws", "docs/a.txt", "x");
    const out = try run(tmp.dir, io, std.testing.allocator, "ws", "read", "{\"path\":\"docs\"}", "");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "is a folder") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "list") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "NotAFile") == null);
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
    const jobs = @import("jobs.zig");
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
    const jobs = @import("jobs.zig");
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
    const jobs = @import("jobs.zig");
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
    const ws = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(ws);

    // --- write / mkdir / copy / rename / delete / file_info / list ---
    {
        const out = try run(tmp.dir, io, a, ws, "mkdir",
            \\{"path":"src"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "mkdir") != null);
    }
    {
        const out = try run(tmp.dir, io, a, ws, "write",
            \\{"path":"src/lib.zig","contents":"pub fn MarkerSymbol() void {}\n"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "wrote") != null);
    }
    {
        const out = try run(tmp.dir, io, a, ws, "mkdir",
            \\{"path":"src/nested"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "mkdir") != null);
    }
    {
        const out = try run(tmp.dir, io, a, ws, "copy",
            \\{"from":"src/lib.zig","to":"src/nested/lib2.zig"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "copied") != null);
        const got = try wrote(tmp, io, a, "src/nested/lib2.zig");
        defer a.free(got);
        try std.testing.expect(std.mem.indexOf(u8, got, "MarkerSymbol") != null);
    }
    {
        const out = try run(tmp.dir, io, a, ws, "rename",
            \\{"from":"src/nested/lib2.zig","to":"src/nested/lib_renamed.zig"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "renamed") != null);
    }
    {
        const out = try run(tmp.dir, io, a, ws, "file_info",
            \\{"path":"src/lib.zig"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "bytes") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "size=") != null);
    }
    {
        const out = try run(tmp.dir, io, a, ws, "list",
            \\{"path":"src"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "lib.zig") != null);
    }
    {
        const out = try run(tmp.dir, io, a, ws, "grep",
            \\{"pattern":"MarkerSymbol","path":"src"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "lib.zig") != null);
    }
    {
        const out = try run(tmp.dir, io, a, ws, "glob",
            \\{"pattern":"**/*renamed.zig"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "lib_renamed.zig") != null);
    }
    {
        const out = try run(tmp.dir, io, a, ws, "semantic_search",
            \\{"query":"MarkerSymbol"}
        , "");
        defer a.free(out);
        try std.testing.expect(out.len > 0);
    }
    {
        const out = try run(tmp.dir, io, a, ws, "delete",
            \\{"path":"src/nested/lib_renamed.zig"}
        , "");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "deleted") != null);
    }

    // --- empty path fail-closed ---
    try std.testing.expectError(error.MissingPath, run(tmp.dir, io, a, ws, "copy",
        \\{"from":"","to":"x"}
    , ""));
    try std.testing.expectError(error.MissingPath, run(tmp.dir, io, a, ws, "rename",
        \\{"from":"src/lib.zig","to":""}
    , ""));

    // --- board FACT requires path= (docs) ---
    {
        const bad = try run(tmp.dir, io, a, ws, "board",
            \\{"action":"post","line":"FACT orphan claim without path"}
        , "");
        defer a.free(bad);
        try std.testing.expect(std.mem.indexOf(u8, bad, "rejected") != null);
        const good = try run(tmp.dir, io, a, ws, "board",
            \\{"action":"post","line":"FACT path=src/lib.zig MarkerSymbol exists"}
        , "");
        defer a.free(good);
        try std.testing.expect(std.mem.indexOf(u8, good, "FACT") != null);
        const read = try run(tmp.dir, io, a, ws, "board",
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

        const saved = try run(tmp.dir, io, a, ws, "memory",
            \\{"action":"save","fact":"e2e-catalog-marker=1"}
        , home_abs);
        defer a.free(saved);
        const listed = try run(tmp.dir, io, a, ws, "memory",
            \\{"action":"list"}
        , home_abs);
        defer a.free(listed);
        try std.testing.expect(std.mem.indexOf(u8, listed, "e2e-catalog-marker") != null);
    }

    // --- mcp list / compact / peer / ask_user stubs ---
    {
        const mcp_out = try run(tmp.dir, io, a, ws, "mcp",
            \\{"action":"list"}
        , "");
        defer a.free(mcp_out);
        try std.testing.expect(mcp_out.len > 0);
    }
    {
        const c = try run(tmp.dir, io, a, ws, "compact", "{}", "");
        defer a.free(c);
        try std.testing.expect(std.mem.indexOf(u8, c, "ARC") != null);
    }
    {
        const p = try run(tmp.dir, io, a, ws, "peer",
            \\{"goal":"noop"}
        , "");
        defer a.free(p);
        try std.testing.expect(std.mem.indexOf(u8, p, "harness") != null);
    }
    {
        const u = try run(tmp.dir, io, a, ws, "ask_user",
            \\{"question":"ok?"}
        , "");
        defer a.free(u);
        try std.testing.expect(std.mem.indexOf(u8, u, "TTY") != null);
    }

    // --- open_file receipt ---
    {
        const o = try run(tmp.dir, io, a, ws, "open_file",
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
        const search_out = try run(tmp.dir, io, a, ws, "web_search",
            \\{"query":"bread coding agent"}
        , home_abs);
        defer a.free(search_out);
        try std.testing.expect(search_out.len > 0);
    }
}
