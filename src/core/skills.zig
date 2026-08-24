const std = @import("std");
const Io = std.Io;
const pathing = @import("../tools/pathing.zig");

const log = std.log.scoped(.skills);

pub fn promptBlock(allocator: std.mem.Allocator, names: []const []const u8) ![]u8 {
    if (names.len == 0) return allocator.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Skills (read SKILL.md when needed): ");
    for (names, 0..) |n, i| {
        if (i != 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, n);
    }
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

pub fn listSkillNames(dir: Io.Dir, io: Io, allocator: std.mem.Allocator) ![][]const u8 {
    var it = dir.iterate();
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var seen: std.AutoHashMap(u64, void) = .init(allocator);
    defer seen.deinit();
    while (it.next(io) catch |err| blk: {
        log.warn("iterate skills: {s}", .{@errorName(err)});
        break :blk null;
    }) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        // A skill is something you call by name. `.DS_Store`, `.hub` and
        // `.system` are bookkeeping the tools leave behind, and a slash
        // command starting with a dot is not a thing anyone means to type.
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        var child = dir.openDir(io, entry.name, .{}) catch continue;
        defer child.close(io);
        const st = child.stat(io) catch continue;
        const key: u64 = st.inode;
        const gop = try seen.getOrPut(key);
        if (gop.found_existing) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    return names.toOwnedSlice(allocator);
}

/// Where a workspace keeps its own skills. Home is not listed here because
/// every agent CLI invents its own directory and they are found rather than
/// enumerated; see `eachHomeRoot`.
pub const roots = [_][]const u8{
    "skills",
    ".agents/skills",
    ".claude/skills",
    ".omfx/skills",
};

/// Where the agent CLIs keep their skills, under `$HOME`.
///
/// A skill is a directory holding a `SKILL.md` with `name` and `description`
/// in YAML front matter -- one format, agreed across tools -- so the only
/// thing that differs is where each CLI looks. Written down rather than only
/// discovered so the common ones are found on the first try and so this file
/// is the place to read the answer.
///
/// Verified 2026-08-23:
///   .agents/skills          the cross-tool convention. Codex documents
///                           `$HOME/.agents/skills` and OpenCode calls it
///                           "global agent-compatible"
///   .claude/skills          Claude Code; OpenCode reads it too, as
///                           "global Claude-compatible"
///   .config/opencode/skills OpenCode's own global path
///   .codex/skills           Codex CLI
///   .grok/skills            Grok Build (and `.grok/bundled/skills`)
///   .hermes/skills          Hermes
///   .commandcode/skills     Command Code
///   .pi/agent/skills        pi, one level deeper
///   .omfx/skills            this one
///
/// Anything not on the list is still found by `eachHomeRoot`, which is what
/// keeps omfx working when the next tool ships next month.
pub const home_roots = [_][]const u8{
    ".agents/skills",
    ".claude/skills",
    ".config/opencode/skills",
    ".codex/skills",
    ".grok/skills",
    ".grok/bundled/skills",
    ".hermes/skills",
    ".commandcode/skills",
    ".pi/agent/skills",
    ".omfx/skills",
};

/// Dot-directories under home to look inside. A skills directory sits either
/// at `~/.tool/skills` or one level further in at `~/.tool/agent/skills`, and
/// both spellings are in use on a machine with several agents installed.
pub const max_home_roots: usize = 64;
/// Depth of the second look. Receipt: `.pi/agent/skills` and
/// `.hermes/hermes-agent/skills` are two levels; nothing observed is three.
pub const home_depth: usize = 2;

/// Every `skills` directory under `home`, found rather than listed.
///
/// A skill is a document shared between agents, and each CLI puts its copy
/// somewhere else -- `.claude`, `.codex`, `.grok`, `.hermes`, `.commandcode`,
/// `.config/opencode`, `.pi/agent`. Enumerating them means omfx stops seeing
/// a tool the moment one is installed, so the directories are discovered.
fn eachHomeRoot(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    out: *std.ArrayList([]u8),
) !void {
    if (home.len == 0) return;
    // The documented ones first, in order, so the common case is a handful of
    // stats rather than a walk of every dot-directory in a home folder.
    for (home_roots) |root| {
        if (out.items.len >= max_home_roots) return;
        const path = try std.fs.path.join(allocator, &.{ home, root });
        errdefer allocator.free(path);
        var probe = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
            allocator.free(path);
            continue;
        };
        probe.close(io);
        try out.append(allocator, path);
    }
    var dir = Io.Dir.cwd().openDir(io, home, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (out.items.len >= max_home_roots) return;
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        // Dot-directories only: a scan of every folder in a home directory is
        // the kind of startup cost people notice.
        if (entry.name.len == 0 or entry.name[0] != '.') continue;
        const base = try std.fs.path.join(allocator, &.{ home, entry.name });
        defer allocator.free(base);
        try appendIfSkills(allocator, io, base, out);
        if (out.items.len >= max_home_roots) return;

        var inner = Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch continue;
        defer inner.close(io);
        var inner_it = inner.iterate();
        while (inner_it.next(io) catch null) |sub| {
            if (out.items.len >= max_home_roots) return;
            if (sub.kind != .directory and sub.kind != .sym_link) continue;
            if (std.mem.eql(u8, sub.name, "skills")) continue;
            const nested = try std.fs.path.join(allocator, &.{ base, sub.name });
            defer allocator.free(nested);
            try appendIfSkills(allocator, io, nested, out);
        }
    }
}

fn appendIfSkills(
    allocator: std.mem.Allocator,
    io: Io,
    base: []const u8,
    out: *std.ArrayList([]u8),
) !void {
    const path = try std.fs.path.join(allocator, &.{ base, "skills" });
    errdefer allocator.free(path);
    var probe = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
        allocator.free(path);
        return;
    };
    probe.close(io);
    // Already on the documented list: adding it twice would make every skill
    // in it a duplicate to filter out later.
    for (out.items) |have| {
        if (std.mem.eql(u8, have, path)) {
            allocator.free(path);
            return;
        }
    }
    try out.append(allocator, path);
}

pub fn listAllNames(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    home: []const u8,
    workspace: []const u8,
) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    try appendFromDir(&names, allocator, io, dir, "skills");
    // The workspace first: a project's own skill of the same name wins,
    // because it was written for this repo.
    for (roots) |root| {
        if (workspace.len == 0) break;
        const path = try std.fs.path.join(allocator, &.{ workspace, root });
        defer allocator.free(path);
        var found = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch continue;
        defer found.close(io);
        try appendUnique(&names, allocator, io, found);
    }
    var found_roots: std.ArrayList([]u8) = .empty;
    defer {
        for (found_roots.items) |r| allocator.free(r);
        found_roots.deinit(allocator);
    }
    try eachHomeRoot(allocator, io, home, &found_roots);
    for (found_roots.items) |path| {
        var found = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch continue;
        defer found.close(io);
        try appendUnique(&names, allocator, io, found);
    }
    return names.toOwnedSlice(allocator);
}

/// A skill's directory, for the prompt that tells the model to read it.
pub fn pathOf(allocator: std.mem.Allocator, io: Io, home: []const u8, workspace: []const u8, name: []const u8) ?[]u8 {
    for (roots) |root| {
        if (workspace.len == 0) break;
        const path = std.fs.path.join(allocator, &.{ workspace, root, name, "SKILL.md" }) catch continue;
        if (Io.Dir.cwd().statFile(io, path, .{})) |_| return path else |_| allocator.free(path);
    }
    var found_roots: std.ArrayList([]u8) = .empty;
    defer {
        for (found_roots.items) |r| allocator.free(r);
        found_roots.deinit(allocator);
    }
    eachHomeRoot(allocator, io, home, &found_roots) catch return null;
    for (found_roots.items) |base| {
        const path = std.fs.path.join(allocator, &.{ base, name, "SKILL.md" }) catch continue;
        if (Io.Dir.cwd().statFile(io, path, .{})) |_| return path else |_| allocator.free(path);
    }
    return null;
}

fn appendFromDir(
    names: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    sub: []const u8,
) !void {
    var child = dir.openDir(io, sub, .{ .iterate = true }) catch return;
    defer child.close(io);
    try appendUnique(names, allocator, io, child);
}

fn appendUnique(
    names: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
) !void {
    const extra = try listSkillNames(dir, io, allocator);
    defer {
        for (extra) |n| allocator.free(n);
        allocator.free(extra);
    }
    for (extra) |n| {
        var seen = false;
        for (names.items) |have| {
            if (std.mem.eql(u8, have, n)) {
                seen = true;
                break;
            }
        }
        if (!seen) try names.append(allocator, try allocator.dupe(u8, n));
    }
}

/// Bytes of a SKILL.md scanned for its front matter. The front matter is the
/// first thing in the file, so nothing past this is read even when the file
/// is much longer.
pub const head_bytes: usize = 4096;
/// Receipt: of the 172 skills on this machine, 135 are over 4 KB and the
/// largest is 11.5 KB. `readFileAlloc` fails rather than truncates when a
/// file passes its limit, so a cap at the scan size meant every long skill
/// silently lost its description. Sized for a document, not for a header.
pub const max_skill_bytes: usize = 256 * 1024;
/// Cells a description is worth in a list. Past this it stops being a label.
pub const max_description: usize = 140;

/// The `description:` line from a SKILL.md's front matter.
///
/// Skills follow one shape -- a `---` fenced YAML head with `name` and
/// `description` -- so this reads that rather than guessing from the body.
/// Returns "" when the file has no front matter, which is a skill someone
/// wrote by hand and is still perfectly usable.
pub fn describe(allocator: std.mem.Allocator, io: Io, path: []const u8) []const u8 {
    const file = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_skill_bytes)) catch return "";
    defer allocator.free(file);
    const head = file[0..@min(file.len, head_bytes)];
    if (!std.mem.startsWith(u8, head, "---")) return "";
    const body_at = std.mem.indexOfPos(u8, head, 3, "\n---") orelse head.len;
    const front = head[0..body_at];
    const at = std.mem.indexOf(u8, front, "\ndescription:") orelse return "";
    var line = front[at + "\ndescription:".len ..];
    if (std.mem.indexOfScalar(u8, line, '\n')) |nl| line = line[0..nl];
    const text = std.mem.trim(u8, line, " \t\"'");
    if (text.len == 0) return "";
    return allocator.dupe(u8, clip(text, max_description)) catch "";
}

/// Cut on a rune boundary, and at a word where one is near the end: a label
/// that stops mid-word reads as corruption rather than as elision.
fn clip(s: []const u8, cap: usize) []const u8 {
    if (s.len <= cap) return s;
    var end = cap;
    while (end > 0 and (s[end] & 0xc0) == 0x80) end -= 1;
    if (std.mem.lastIndexOfScalar(u8, s[0..end], ' ')) |sp| {
        if (sp * 4 > end * 3) end = sp;
    }
    return s[0..end];
}

/// Longest skill list a prompt can call in one go. Receipt: the machine this
/// was written on has 167 skills; naming more than a handful in one prompt is
/// not composition, it is a paste. Matches Claude Code's leading stack
/// (first skill plus up to five more) with room for two inline extras.
pub const max_in_prompt: usize = 8;

/// Rewrite `/skill` tokens into instructions to read those skills.
///
/// Null when the prompt names no known skill, which leaves ordinary text and
/// system commands alone.
///
/// Two shapes, matching what the other CLIs do:
///
/// - **Leading stack** (Claude Code): `/a /b fix @src/foo.zig` peels consecutive
///   known skills at the start; everything after the stack is the shared task
///   for all of them, including `@file` mentions. Stops at the first token that
///   is not a known skill.
/// - **Inline** (omp / mid-prose): `fix @f with /deslop and /tdd` replaces each
///   `/skill` in place and keeps the surrounding words and `@paths`.
///
/// Skills are documents, so stacking them is coherent; system commands are not
/// stacked the same way because their effects would race.
pub fn expand(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    workspace: []const u8,
    text: []const u8,
) !?[]u8 {
    const leading = std.mem.trimStart(u8, text, " \t");
    if (leading.len > 0 and leading[0] == '/') {
        if (try expandLeading(allocator, io, home, workspace, leading)) |out| return out;
    }
    return expandInline(allocator, io, home, workspace, text);
}

/// Peel consecutive `/skill` tokens from the start; remaining text is the task.
fn expandLeading(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    workspace: []const u8,
    text: []const u8,
) !?[]u8 {
    var paths: [max_in_prompt][]u8 = undefined;
    var n: usize = 0;
    var rest = text;
    while (n < max_in_prompt) {
        rest = std.mem.trimStart(u8, rest, " \t");
        if (rest.len == 0 or rest[0] != '/') break;
        const name = tokenAt(rest[1..]);
        if (name.len == 0) break;
        const path = pathOf(allocator, io, home, workspace, name) orelse break;
        paths[n] = path;
        n += 1;
        rest = rest[1 + name.len ..];
    }
    if (n == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (paths[0..n]) |p| {
        defer allocator.free(p);
        try out.print(allocator, "Read {s} and follow it.\n", .{p});
    }
    rest = std.mem.trimStart(u8, rest, " \t");
    // Mid-stack skills in the task text still expand; @paths stay for mention.
    if (try expandInline(allocator, io, home, workspace, rest)) |inner| {
        defer allocator.free(inner);
        try out.appendSlice(allocator, inner);
    } else if (rest.len != 0) {
        try out.appendSlice(allocator, rest);
    }
    return try out.toOwnedSlice(allocator);
}

/// Replace every word-starting `/skill` in place; leave unknown slashes alone.
fn expandInline(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    workspace: []const u8,
    text: []const u8,
) !?[]u8 {
    var found: usize = 0;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var rest = text;
    while (rest.len != 0) {
        const at = std.mem.indexOfScalar(u8, rest, '/') orelse break;
        // A slash only opens a command at the start of a word; `src/main.zig`
        // and `http://x` are paths, not calls.
        const opens = at == 0 or rest[at - 1] == ' ' or rest[at - 1] == '\n';
        const name = tokenAt(rest[at + 1 ..]);
        if (!opens or name.len == 0 or found == max_in_prompt) {
            try out.appendSlice(allocator, rest[0 .. at + 1]);
            rest = rest[at + 1 ..];
            continue;
        }
        const path = pathOf(allocator, io, home, workspace, name) orelse {
            try out.appendSlice(allocator, rest[0 .. at + 1]);
            rest = rest[at + 1 ..];
            continue;
        };
        defer allocator.free(path);
        try out.appendSlice(allocator, rest[0..at]);
        try out.print(allocator, "Read {s} and follow it.", .{path});
        rest = rest[at + 1 + name.len ..];
        found += 1;
    }
    if (found == 0) {
        out.deinit(allocator);
        return null;
    }
    try out.appendSlice(allocator, rest);
    return try out.toOwnedSlice(allocator);
}

/// The skill-name characters at the front of `s`.
fn tokenAt(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == ':';
        if (!ok) break;
    }
    return s[0..i];
}

pub fn countSkills(dir: Io.Dir, io: Io, allocator: std.mem.Allocator) !usize {
    const names = try listSkillNames(dir, io, allocator);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    return names.len;
}

test "a dot-directory is bookkeeping, not a skill" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fake_home = try @import("../tools/pathing.zig").testWorkspace(a, &tmp);
    defer a.free(fake_home);

    for ([_][]const u8{ "real-skill", ".curator_backups", ".hub", ".system" }) |name| {
        const dir = try std.fs.path.join(a, &.{ fake_home, ".claude/skills", name });
        defer a.free(dir);
        try Io.Dir.cwd().createDirPath(io, dir);
    }
    const names = try listAllNames(a, io, tmp.dir, fake_home, "");
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("real-skill", names[0]);
}

test "a long skill still gives up its description" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try @import("../tools/pathing.zig").testWorkspace(a, &tmp);
    defer a.free(ws);
    const path = try std.fs.path.join(a, &.{ ws, "SKILL.md" });
    defer a.free(path);

    // Longer than the scan window, which is the shape that lost every
    // description on a real machine.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try body.appendSlice(a, "---\nname: big\ndescription: Still readable.\n---\n");
    try body.appendNTimes(a, 'x', head_bytes * 3);
    try writeFileForTest(io, path, body.items);

    const got = describe(a, io, path);
    defer a.free(got);
    try std.testing.expectEqualStrings("Still readable.", got);
}

test "a skill in several CLIs is listed once" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fake_home = try @import("../tools/pathing.zig").testWorkspace(a, &tmp);
    defer a.free(fake_home);

    // The same skill filed under three different agents, which is what a
    // machine with several CLIs installed actually looks like.
    for ([_][]const u8{ ".claude/skills", ".codex/skills", ".grok/skills" }) |root| {
        const dir = try std.fs.path.join(a, &.{ fake_home, root, "deslop" });
        defer a.free(dir);
        try Io.Dir.cwd().createDirPath(io, dir);
    }
    const only = try std.fs.path.join(a, &.{ fake_home, ".hermes/skills", "unique-one" });
    defer a.free(only);
    try Io.Dir.cwd().createDirPath(io, only);

    const names = try listAllNames(a, io, tmp.dir, fake_home, "");
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    var deslop: usize = 0;
    var unique: usize = 0;
    for (names) |n| {
        if (std.mem.eql(u8, n, "deslop")) deslop += 1;
        if (std.mem.eql(u8, n, "unique-one")) unique += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), deslop);
    // And a skill only one CLI has is still found.
    try std.testing.expectEqual(@as(usize, 1), unique);
}

test "a CLI nobody has documented yet is still found" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fake_home = try @import("../tools/pathing.zig").testWorkspace(a, &tmp);
    defer a.free(fake_home);

    // Not in `home_roots`: the walk has to find it, one and two levels deep.
    for ([_][]const u8{ ".newtool/skills/from-flat", ".newtool2/agent/skills/from-nested" }) |p| {
        const dir = try std.fs.path.join(a, &.{ fake_home, p });
        defer a.free(dir);
        try Io.Dir.cwd().createDirPath(io, dir);
    }
    const names = try listAllNames(a, io, tmp.dir, fake_home, "");
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    var flat = false;
    var nested = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "from-flat")) flat = true;
        if (std.mem.eql(u8, n, "from-nested")) nested = true;
    }
    try std.testing.expect(flat);
    try std.testing.expect(nested);
}

test "a description comes from the front matter, not the body" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try @import("../tools/pathing.zig").testWorkspace(a, &tmp);
    defer a.free(ws);
    const path = try std.fs.path.join(a, &.{ ws, "SKILL.md" });
    defer a.free(path);

    try writeFileForTest(io, path,
        \\---
        \\name: animate
        \\description: Build an animation from scratch. Use when asked to animate something.
        \\---
        \\
        \\# Body text nobody wants in a list.
    );
    const got = describe(a, io, path);
    defer a.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "Build an animation from scratch."));
    try std.testing.expect(std.mem.indexOf(u8, got, "Body text") == null);

    // A hand-written skill with no front matter is still a usable skill.
    try writeFileForTest(io, path, "# Just a document\n");
    try std.testing.expectEqualStrings("", describe(a, io, path));
}

test "a long description is cut at a word, on a rune boundary" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try @import("../tools/pathing.zig").testWorkspace(a, &tmp);
    defer a.free(ws);
    const path = try std.fs.path.join(a, &.{ ws, "SKILL.md" });
    defer a.free(path);

    try writeFileForTest(io, path, "---\nname: x\ndescription: " ++ ("word " ** 80) ++ "\n---\n");
    const got = describe(a, io, path);
    defer a.free(got);
    try std.testing.expect(got.len <= max_description);
    try std.testing.expect(std.unicode.utf8ValidateSlice(got));
    // Cut between words, so the label does not end mid-token.
    try std.testing.expect(!std.mem.endsWith(u8, got, "wor"));
}

fn writeFileForTest(io: Io, path: []const u8, body: []const u8) !void {
    var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    var buf: [1024]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(body);
    try w.interface.flush();
}

test "a prompt can name several skills at once" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try @import("../tools/pathing.zig").testWorkspace(a, &tmp);
    defer a.free(ws);
    for ([_][]const u8{ "deslop", "tdd" }) |name| {
        const dir = try std.fs.path.join(a, &.{ ws, ".agents", "skills", name });
        defer a.free(dir);
        try Io.Dir.cwd().createDirPath(io, dir);
        const file = try std.fs.path.join(a, &.{ dir, "SKILL.md" });
        defer a.free(file);
        var f = try Io.Dir.cwd().createFile(io, file, .{ .truncate = true });
        f.close(io);
    }

    const both = (try expand(a, io, "", ws, "/deslop and /tdd this module")).?;
    defer a.free(both);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, both, "Read "));
    try std.testing.expect(std.mem.indexOf(u8, both, "deslop/SKILL.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, both, "tdd/SKILL.md") != null);
    // The words around the calls are the task and survive untouched.
    try std.testing.expect(std.mem.indexOf(u8, both, " and ") != null);
    try std.testing.expect(std.mem.indexOf(u8, both, "this module") != null);

    // A path is not a call: a slash mid-word opens nothing.
    try std.testing.expect(try expand(a, io, "", ws, "look at src/tdd for it") == null);
    // Neither is a skill nobody has.
    try std.testing.expect(try expand(a, io, "", ws, "/nope") == null);
}

test "leading skills stack and share the trailing task including @files" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try @import("../tools/pathing.zig").testWorkspace(a, &tmp);
    defer a.free(ws);
    for ([_][]const u8{ "deslop", "tdd" }) |name| {
        const dir = try std.fs.path.join(a, &.{ ws, ".agents", "skills", name });
        defer a.free(dir);
        try Io.Dir.cwd().createDirPath(io, dir);
        const file = try std.fs.path.join(a, &.{ dir, "SKILL.md" });
        defer a.free(file);
        var f = try Io.Dir.cwd().createFile(io, file, .{ .truncate = true });
        f.close(io);
    }

    // Claude Code shape: `/a /b args` — both skills, shared task, @path intact.
    const stacked = (try expand(a, io, "", ws, "/deslop /tdd fix @src/main.zig")).?;
    defer a.free(stacked);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, stacked, "Read "));
    try std.testing.expect(std.mem.indexOf(u8, stacked, "fix @src/main.zig") != null);
    // Stack stops at the first unknown slash token; it becomes part of the task.
    const stop = (try expand(a, io, "", ws, "/deslop /nope keep this")).?;
    defer a.free(stop);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, stop, "Read "));
    try std.testing.expect(std.mem.indexOf(u8, stop, "/nope keep this") != null);
}

test "skills mid-prompt expand without a leading slash" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try @import("../tools/pathing.zig").testWorkspace(a, &tmp);
    defer a.free(ws);
    const dir = try std.fs.path.join(a, &.{ ws, ".agents", "skills", "deslop" });
    defer a.free(dir);
    try Io.Dir.cwd().createDirPath(io, dir);
    const file = try std.fs.path.join(a, &.{ dir, "SKILL.md" });
    defer a.free(file);
    var f = try Io.Dir.cwd().createFile(io, file, .{ .truncate = true });
    f.close(io);

    const mid = (try expand(a, io, "", ws, "please /deslop this @note.txt")).?;
    defer a.free(mid);
    try std.testing.expect(std.mem.indexOf(u8, mid, "Read ") != null);
    try std.testing.expect(std.mem.indexOf(u8, mid, "@note.txt") != null);
    try std.testing.expect(std.mem.startsWith(u8, mid, "please "));
}

test "missing skills dir is zero" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const n = try countSkills(tmp.dir, std.testing.io, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "promptBlock lists names" {
    const names = [_][]const u8{ "hello-omfx", "web" };
    const s = try promptBlock(std.testing.allocator, &names);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "hello-omfx") != null);
}

test "listAllNames includes .omfx/skills" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try pathing.testWorkspace(a, &tmp);
    defer a.free(ws);

    const dirp = try std.fs.path.join(a, &.{ ws, ".omfx", "skills", "from-trace" });
    defer a.free(dirp);
    // `try`, not `catch unreachable`: a filesystem call can fail, and
    // `unreachable` is undefined behaviour in ReleaseFast.
    try Io.Dir.cwd().createDirPath(io, dirp);
    const md = try std.fs.path.join(a, &.{ dirp, "SKILL.md" });
    defer a.free(md);
    var dummy = try Io.Dir.cwd().createFile(io, md, .{});
    dummy.close(io);
    const names = try listAllNames(a, io, tmp.dir, "", ws);
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    var found = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "from-trace")) found = true;
    }
    try std.testing.expect(found);
}
