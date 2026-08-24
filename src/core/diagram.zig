const std = @import("std");
const deadline = @import("../tools/deadline.zig");

/// mermaid renders in seconds or it is stuck on something.
pub const render_secs: u32 = 30;
const Io = std.Io;

const log = std.log.scoped(.diagram);

pub const max_fences: usize = 8;
pub const max_fence_bytes: usize = 16_000;
pub const max_ids: u16 = 256;
pub const dir_name = ".omfx/diagrams";

comptime {
    if (max_fences == 0) @compileError("max_fences must keep at least one mermaid block");
    if (max_fence_bytes == 0) @compileError("max_fence_bytes must hold one mermaid block");
    if (max_ids == 0) @compileError("max_ids must name at least one saved diagram");
}

pub const Id = enum(u16) { _ };

pub const Fence = struct {
    body: []const u8,
};

pub const Lang = enum { mermaid, other };

pub const Render = enum { svg, skipped };

pub const Result = union(enum) {
    none,
    report: []u8,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        switch (self) {
            .none => {},
            .report => |s| allocator.free(s),
        }
    }
};

fn classifyLang(lang: []const u8) Lang {
    const t = std.mem.trim(u8, lang, " \t");
    if (std.ascii.eqlIgnoreCase(t, "mermaid")) return .mermaid;
    return .other;
}

const Scan = union(enum) {
    mermaid: []const u8,
    skip,
    done,
};

fn nextFence(text: []const u8, i: *usize) Scan {
    if (i.* + 3 >= text.len) return .done;
    const at = std.mem.indexOfPos(u8, text, i.*, "```") orelse return .done;
    var j = at + 3;
    while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
    const lang_from = j;
    while (j < text.len and text[j] != '\n' and text[j] != '\r' and text[j] != ' ') j += 1;
    const lang = text[lang_from..j];
    while (j < text.len and text[j] != '\n') j += 1;
    if (j < text.len and text[j] == '\n') j += 1;
    const close = std.mem.indexOfPos(u8, text, j, "```") orelse {
        i.* = text.len;
        return .done;
    };
    const body = std.mem.trim(u8, text[j..close], " \t\r\n");
    i.* = close + 3;
    return switch (classifyLang(lang)) {
        .mermaid => if (body.len == 0) .skip else .{
            .mermaid = if (body.len > max_fence_bytes) body[0..max_fence_bytes] else body,
        },
        .other => .skip,
    };
}

pub fn extract(text: []const u8, out: *[max_fences]Fence) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (n < out.len) {
        switch (nextFence(text, &i)) {
            .done => break,
            .skip => {},
            .mermaid => |body| {
                out[n] = .{ .body = body };
                n += 1;
            },
        }
    }
    return n;
}

fn exists(dir: Io.Dir, io: Io, name: []const u8) bool {
    const f = dir.openFile(io, name, .{ .mode = .read_only }) catch return false;
    f.close(io);
    return true;
}

fn fileName(buf: *[72]u8, id: Id, ext: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/d{d}.{s}", .{ dir_name, @intFromEnum(id), ext }) catch dir_name;
}

fn nextId(dir: Io.Dir, io: Io) Id {
    var n: u16 = 1;
    while (n <= max_ids) : (n += 1) {
        var buf: [72]u8 = undefined;
        const name = fileName(&buf, @enumFromInt(n), "mmd");
        if (!exists(dir, io, name)) return @enumFromInt(n);
    }
    return @enumFromInt(1);
}

const WriteError = error{WriteFailed};

fn writeMmd(dir: Io.Dir, io: Io, name: []const u8, body: []const u8) WriteError!void {
    var file = dir.createFile(io, name, .{ .truncate = true }) catch return error.WriteFailed;
    defer file.close(io);
    var wbuf: [1024]u8 = undefined;
    var w = file.writer(io, &wbuf);
    w.interface.writeAll(body) catch return error.WriteFailed;
    if (body.len == 0 or body[body.len - 1] != '\n') w.interface.writeByte('\n') catch return error.WriteFailed;
    w.interface.flush() catch return error.WriteFailed;
}

fn renderSvg(io: Io, mmd: []const u8, svg: []const u8) Render {
    var cap: deadline.Capped = undefined;
    cap.init(&.{ "mmdc", "-i", mmd, "-o", svg, "-q" }, render_secs);
    var child = std.process.spawn(io, .{
        .argv = cap.slice(),
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return .skipped;
    const term = child.wait(io) catch {
        child.kill(io);
        return .skipped;
    };
    const ok = switch (term) {
        .exited => |code| code == 0,
        .stopped, .signal, .unknown => false,
    };
    return if (ok) .svg else .skipped;
}

pub fn save(
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    io: Io,
    text: []const u8,
) !Result {
    var fences: [max_fences]Fence = undefined;
    const n = extract(text, &fences);
    if (n == 0) return .none;
    dir.createDirPath(io, dir_name) catch |err| {
        log.warn("mkdir {s}: {s}", .{ dir_name, @errorName(err) });
        return .{ .report = try std.fmt.allocPrint(allocator, "Could not create {s}, so the diagram was not saved.\n", .{dir_name}) };
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "diagrams\n");
    for (fences[0..n]) |fence| {
        const id = nextId(dir, io);
        var mmd_buf: [72]u8 = undefined;
        var svg_buf: [72]u8 = undefined;
        const mmd = fileName(&mmd_buf, id, "mmd");
        const svg = fileName(&svg_buf, id, "svg");
        writeMmd(dir, io, mmd, fence.body) catch |err| {
            log.warn("write {s}: {s}", .{ mmd, @errorName(err) });
            continue;
        };
        const rendered: Render = switch (renderSvg(io, mmd, svg)) {
            .svg => if (exists(dir, io, svg)) .svg else .skipped,
            .skipped => .skipped,
        };
        const line = switch (rendered) {
            .svg => try std.fmt.allocPrint(allocator, "Saved the diagram to {s}, rendered from {s}.\n", .{ svg, mmd }),
            .skipped => try std.fmt.allocPrint(allocator, "Wrote {s}. There is no mmdc on PATH, so no image was rendered.\n", .{mmd}),
        };
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }
    return .{ .report = try out.toOwnedSlice(allocator) };
}

test "extract skips non-mermaid fences" {
    const text =
        \\before
        \\```zig
        \\const x = 1;
        \\```
        \\```mermaid
        \\graph TD
        \\  A-->B
        \\```
        \\after
        \\```MERMAID
        \\sequenceDiagram
        \\  A->>B: hi
        \\```
        \\
    ;
    var buf: [max_fences]Fence = undefined;
    const n = extract(text, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expect(std.mem.indexOf(u8, buf[0].body, "A-->B") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[1].body, "sequenceDiagram") != null);
}

test "extract none" {
    var buf: [max_fences]Fence = undefined;
    try std.testing.expectEqual(@as(usize, 0), extract("no fences", &buf));
    try std.testing.expectEqual(@as(usize, 0), extract("```json\n{}\n```", &buf));
}

test "save none is exclusive of report" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const got = try save(std.testing.allocator, tmp.dir, io, "plain text");
    defer got.deinit(std.testing.allocator);
    try std.testing.expect(got == .none);
}

test "save writes mmd" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text =
        \\```mermaid
        \\graph LR
        \\  X-->Y
        \\```
        \\
    ;
    const got = try save(std.testing.allocator, tmp.dir, io, text);
    defer got.deinit(std.testing.allocator);
    const msg = got.report;
    try std.testing.expect(std.mem.indexOf(u8, msg, "d1.mmd") != null);
    const body = try tmp.dir.readFileAlloc(io, ".omfx/diagrams/d1.mmd", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "X-->Y") != null);
}
