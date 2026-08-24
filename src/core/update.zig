const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");

const log = std.log.scoped(.update);

pub const repo = "Yabuku-xD/omfx";
pub const install_url = "https://raw.githubusercontent.com/" ++ repo ++ "/main/install.sh";
pub const latest_api = "https://api.github.com/repos/" ++ repo ++ "/releases/latest";

pub const Error = error{
    Transport,
    BadRelease,
    NoRelease,
    InstallFailed,
    OutOfMemory,
    WriteFailed,
};

pub const Opts = struct {
    check: bool = false,
    force: bool = false,
};

pub const SemVer = struct {
    major: u32 = 0,
    minor: u32 = 0,
    patch: u32 = 0,

    pub fn parse(raw: []const u8) SemVer {
        var s = std.mem.trim(u8, raw, " \t\r\n");
        if (s.len > 0 and (s[0] == 'v' or s[0] == 'V')) s = s[1..];
        var out: SemVer = .{};
        var it = std.mem.splitScalar(u8, s, '.');
        if (it.next()) |a| out.major = std.fmt.parseInt(u32, a, 10) catch 0;
        if (it.next()) |b| out.minor = std.fmt.parseInt(u32, b, 10) catch 0;
        if (it.next()) |c| {
            const end = std.mem.indexOfAny(u8, c, "-+") orelse c.len;
            out.patch = std.fmt.parseInt(u32, c[0..end], 10) catch 0;
        }
        return out;
    }

    pub fn order(a: SemVer, b: SemVer) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        return std.math.order(a.patch, b.patch);
    }
};

/// Pull `tag_name` from a GitHub releases/latest JSON body.
pub fn tagFromReleaseJson(body: []const u8) ?[]const u8 {
    const key = "\"tag_name\"";
    const at = std.mem.indexOf(u8, body, key) orelse return null;
    const colon = std.mem.indexOfScalar(u8, body[at..], ':') orelse return null;
    var i = at + colon + 1;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) i += 1;
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < body.len and body[i] != '"') i += 1;
    if (i >= body.len) return null;
    return body[start..i];
}

fn fetchLatestBody(allocator: std.mem.Allocator, io: Io) Error![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var auth_buf: [128]u8 = undefined;
    var extra: [2]std.http.Header = undefined;
    var extra_n: usize = 0;
    extra[extra_n] = .{ .name = "user-agent", .value = "omfx-update" };
    extra_n += 1;
    if (std.c.getenv("GITHUB_TOKEN") orelse std.c.getenv("GH_TOKEN")) |tok| {
        const slice = std.mem.span(tok);
        if (slice.len > 0 and slice.len < 100) {
            const v = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{slice}) catch "";
            if (v.len != 0) {
                extra[extra_n] = .{ .name = "authorization", .value = v };
                extra_n += 1;
            }
        }
    }
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const result = client.fetch(.{
        .location = .{ .url = latest_api },
        .method = .GET,
        .response_writer = &aw.writer,
        .extra_headers = extra[0..extra_n],
    }) catch return error.Transport;
    if (@intFromEnum(result.status) == 404) return error.NoRelease;
    if (@intFromEnum(result.status) != 200) return error.BadRelease;
    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

fn binDirHint(allocator: std.mem.Allocator, io: Io) ?[]u8 {
    const exe = std.process.executablePathAlloc(io, allocator) catch return null;
    defer allocator.free(exe);
    const dir = std.fs.path.dirname(exe) orelse return null;
    return allocator.dupe(u8, dir) catch null;
}

fn shellSingleQuote(allocator: std.mem.Allocator, s: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

fn runInstall(allocator: std.mem.Allocator, io: Io, bin_dir: ?[]const u8) Error!void {
    const script = if (bin_dir) |d| blk: {
        const q = try shellSingleQuote(allocator, d);
        defer allocator.free(q);
        break :blk try std.fmt.allocPrint(allocator,
            \\set -eu
            \\export OMFX_BIN_DIR={s}
            \\curl -fsSL '{s}' | sh
        , .{ q, install_url });
    } else try std.fmt.allocPrint(allocator,
        \\set -eu
        \\curl -fsSL '{s}' | sh
    , .{install_url});
    defer allocator.free(script);

    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", script },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return error.InstallFailed;
    const term = child.wait(io) catch return error.InstallFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.InstallFailed,
        else => return error.InstallFailed,
    }
}

/// Check GitHub for a newer release and optionally install it.
pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    stdout: *Io.Writer,
    opts: Opts,
) Error!void {
    try stdout.print("omfx {s}\n", .{cli.version});
    const body = fetchLatestBody(allocator, io) catch |err| {
        log.warn("latest release: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(body);
    const tag = tagFromReleaseJson(body) orelse return error.BadRelease;
    const remote = SemVer.parse(tag);
    const local = SemVer.parse(cli.version);
    const cmp = SemVer.order(remote, local);

    if (cmp == .lt or (cmp == .eq and !opts.force)) {
        try stdout.writeAll("Already up to date.\n");
        return;
    }
    if (cmp == .gt) {
        try stdout.print("New version available: {s}\n", .{tag});
    } else {
        try stdout.print("Forcing reinstall of {s}\n", .{tag});
    }
    if (opts.check) return;

    const hint = binDirHint(allocator, io);
    defer if (hint) |h| allocator.free(h);
    try runInstall(allocator, io, hint);
}

test "semver orders patches" {
    const a = SemVer.parse("0.0.1");
    const b = SemVer.parse("v0.0.2");
    try std.testing.expect(SemVer.order(a, b) == .lt);
    try std.testing.expect(SemVer.order(b, a) == .gt);
    try std.testing.expect(SemVer.order(a, SemVer.parse("0.0.1")) == .eq);
}

test "tagFromReleaseJson reads tag_name" {
    const body = "{\"url\":\"x\",\"tag_name\":\"v1.2.3\",\"name\":\"n\"}";
    try std.testing.expectEqualStrings("v1.2.3", tagFromReleaseJson(body).?);
}

test "shellSingleQuote escapes apostrophes" {
    const q = try shellSingleQuote(std.testing.allocator, "a'b");
    defer std.testing.allocator.free(q);
    try std.testing.expectEqualStrings("'a'\\''b'", q);
}
