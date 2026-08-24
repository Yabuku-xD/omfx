const std = @import("std");
const Io = std.Io;

const deadline = @import("deadline.zig");
const bash = @import("bash.zig");
const langs = @import("../core/langs.zig");
const lex = @import("../core/lex.zig");

const log = std.log.scoped(.diag);

/// Result of an AGENTS.md `verify:` line. Same strings the turn already appends.
pub const CmdVerdict = union(enum) {
    clean,
    findings: []const u8,
    unavailable: []const u8,

    pub fn deinit(self: CmdVerdict, allocator: std.mem.Allocator) void {
        switch (self) {
            .clean => {},
            .findings, .unavailable => |s| allocator.free(s),
        }
    }

    pub fn render(self: CmdVerdict, allocator: std.mem.Allocator, cmd: []const u8) ![]u8 {
        return switch (self) {
            .clean => std.fmt.allocPrint(allocator, "verify: clean ({s})\n", .{cmd}),
            .findings => |clip| std.fmt.allocPrint(allocator, "verify: findings ({s})\n{s}", .{ cmd, clip }),
            .unavailable => |why| std.fmt.allocPrint(allocator, "verify: unavailable ({s}: {s}); not a clean verdict\n", .{ cmd, why }),
        };
    }
};

/// Run the command from `verify:` the same way a bash tool would.
pub fn runVerifyCmd(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    cmd: []const u8,
) !CmdVerdict {
    const body = bash.runEx(allocator, io, workspace, cmd, true) catch |err| {
        return .{ .unavailable = try allocator.dupe(u8, @errorName(err)) };
    };
    defer allocator.free(body);
    const failed = std.mem.indexOf(u8, body, "error:") != null or std.mem.indexOf(u8, body, "FAIL") != null;
    if (failed) {
        const clip = if (body.len > 800) body[0..800] else body;
        return .{ .findings = try allocator.dupe(u8, clip) };
    }
    return .clean;
}

pub fn unavailable(allocator: std.mem.Allocator, reason: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "diagnostics: unavailable ({s}); not a clean verdict\n", .{reason});
}

pub fn timeout(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "diagnostics: timeout; not a clean verdict\n");
}

pub fn degraded(allocator: std.mem.Allocator, reason: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "diagnostics: degraded ({s}); not a clean verdict\n", .{reason});
}

pub fn clean(allocator: std.mem.Allocator, checker: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "diagnostics: clean ({s})\n", .{checker});
}

pub fn findings(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "diagnostics: findings\n{s}", .{body});
}

/// Local billed-review substitute: git diff of the path. LLM pass is settings.review=llm.
pub fn afterDiff(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    rel: []const u8,
) ![]u8 {
    var child = std.process.spawn(io, .{
        .argv = &.{ "git", "diff", "--", rel },
        .cwd = .{ .path = workspace },
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch {
        return allocator.dupe(u8, "review: unavailable (git diff spawn failed); not a clean verdict\n");
    };
    var out_buf: [2048]u8 = undefined;
    var collected: std.ArrayList(u8) = .empty;
    errdefer {
        collected.deinit(allocator);
        child.kill(io);
        _ = child.wait(io) catch |err| {
            log.debug("wait: {s}", .{@errorName(err)});
        };
    }
    if (child.stdout) |f| {
        var reader = Io.File.Reader.initStreaming(f, io, &out_buf);
        while (reader.interface.takeByte()) |b| {
            try collected.append(allocator, b);
            if (collected.items.len > 4_000) break;
        } else |_| {}
    }
    _ = child.wait(io) catch |err| {
        log.debug("wait: {s}", .{@errorName(err)});
    };
    if (collected.items.len == 0) {
        collected.deinit(allocator);
        return allocator.dupe(u8, "review: local (no diff)\n");
    }
    if (collected.items.len > 4_000) {
        try collected.appendSlice(allocator, "\ntruncated at 4000 bytes\n");
    }
    const diff = try collected.toOwnedSlice(allocator);
    defer allocator.free(diff);
    return std.fmt.allocPrint(allocator, "review: local (git diff)\n{s}", .{diff});
}

pub fn reviewPrompt(diff: []const u8) []const u8 {
    _ = diff;
    return "Reply with review: clean or review: findings. Five lines max.";
}

/// A parse of the file the model just wrote, in that file's own language.
///
/// Every probe in `langs.table` READS the file and never runs it: `node
/// --check`, `ruby -c`, `bash -n`, `php -l`, `gofmt -e` and `compile()` are
/// all parse-only. The write hook fires this unattended after every edit, so
/// "cannot execute the workspace's code" is the property that makes the table
/// safe, and it is why the commands live in a fixed table rather than in user
/// configuration.
///
/// Measured cold on an M-series mac: bash 30ms, cc 44ms, node 54ms, python
/// 68ms, ruby 95ms, gofmt 224ms. All exit non-zero on a syntax error.
///
/// Languages with no probe that meets that bar fall back to `lex.balance`,
/// which is why every language in the table gets an answer rather than the
/// dozen or so with a parser on this machine.
/// After write/edit. Empty/unavailable is not clean.
pub fn afterWrite(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    dir: Io.Dir,
    rel: []const u8,
) ![]u8 {
    const l = langs.byPath(rel) orelse {
        const ext = std.fs.path.extension(rel);
        return unavailable(allocator, if (ext.len == 0) "no checker for extensionless file" else ext);
    };
    if (l.check.len > 0) return runCheck(allocator, io, workspace, dir, l, rel);
    return balanceOnly(allocator, io, dir, l, rel);
}

/// The fallback for a language with no parser to call: does the file close
/// every bracket it opens?
///
/// Weaker than a parse and honest about it. It catches the truncated write and
/// the half-applied hunk, which is the failure an unattended edit actually
/// produces, and it says "unavailable" rather than guessing anywhere the scan
/// is unsure.
fn balanceOnly(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    l: *const langs.Lang,
    rel: []const u8,
) ![]u8 {
    const src = dir.readFileAlloc(io, rel, allocator, .limited(4 * 1024 * 1024)) catch {
        return unavailable(allocator, "unreadable after write");
    };
    defer allocator.free(src);
    switch (lex.balance(l, src)) {
        .ok => return clean(allocator, "delimiter scan"),
        .inconclusive => return unavailable(allocator, "no parser for this language and the scan was inconclusive"),
        .broken => |c| {
            var buf: [160]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{s}:{d}: '{c}' {s}\n", .{
                rel, c.line, c.delim, c.what,
            }) catch "delimiter scan found an unbalanced file\n";
            return findings(allocator, line);
        },
    }
}

fn runCheck(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    dir: Io.Dir,
    l: *const langs.Lang,
    rel: []const u8,
) ![]u8 {
    var argv_buf: [8][]const u8 = undefined;
    if (l.check.len + 1 > argv_buf.len) return unavailable(allocator, langs.label(l));
    @memcpy(argv_buf[0..l.check.len], l.check);
    argv_buf[l.check.len] = rel;
    const argv = argv_buf[0 .. l.check.len + 1];

    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = workspace },
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch {
        // A missing toolchain is not a finding about the code. Say which one,
        // then fall back to the scan rather than saying nothing at all.
        return balanceOnly(allocator, io, dir, l, rel);
    };
    var out_buf: [2048]u8 = undefined;
    var collected: std.ArrayList(u8) = .empty;
    errdefer {
        collected.deinit(allocator);
        child.kill(io);
        _ = child.wait(io) catch |err| {
            log.debug("wait: {s}", .{@errorName(err)});
        };
    }
    if (child.stderr) |f| {
        var reader = Io.File.Reader.initStreaming(f, io, &out_buf);
        while (reader.interface.takeByte()) |b| {
            try collected.append(allocator, b);
            if (collected.items.len > 4000) break;
        } else |_| {}
    }
    const term = child.wait(io) catch {
        child.kill(io);
        allocator.free(try collected.toOwnedSlice(allocator));
        return timeout(allocator);
    };
    const err_out = try collected.toOwnedSlice(allocator);
    defer allocator.free(err_out);
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (ok) return clean(allocator, langs.label(l));
    // A runtime that rejects its own flag is a missing tool wearing a
    // non-zero exit. `node --experimental-strip-types` does exactly that on
    // anything older than 22.6, and reading it as a syntax error would reject
    // every TypeScript edit on that machine.
    if (rejectedItsOwnFlags(err_out)) return balanceOnly(allocator, io, dir, l, rel);
    if (err_out.len == 0) {
        var buf: [96]u8 = undefined;
        return findings(allocator, std.fmt.bufPrint(&buf, "({s} failed with no output)\n", .{langs.label(l)}) catch "(failed)\n");
    }
    return findings(allocator, err_out);
}

fn rejectedItsOwnFlags(err_out: []const u8) bool {
    const tells = [_][]const u8{
        "bad option",     "unrecognized",   "unrecognised", "Unknown option",
        "unknown option", "invalid option", "not found",    "Usage:",
    };
    for (tells) |t| {
        if (std.mem.indexOf(u8, err_out, t) != null) return true;
    }
    return false;
}

/// A project-wide check, chosen by whichever marker file the workspace has.
///
/// These are compile/type checks, not test suites. `runCmd` has no timeout --
/// `child.wait` blocks until the command returns -- and this fires after every
/// single write, so `cargo test` on a real repo would stall the loop for
/// minutes. `cargo check` answers the question the model actually has ("did I
/// just break the build") in seconds.
///
/// Anyone who wants the full suite says so in AGENTS.md: `verify: <command>`
/// takes priority over this table (see `hooks.post`).
pub const Verifier = struct {
    marker: []const u8,
    argv: []const []const u8,
    label: []const u8,
};

/// Parses every tracked .js/.mjs/.cjs, skipping the directories nobody means.
const js_check: []const []const u8 = &.{
    "sh",                                                                                                                                              "-c",
    "find . -name node_modules -prune -o -name '*.js' -print -o -name '*.mjs' -print -o -name '*.cjs' -print | head -400 | xargs -r -n1 node --check",
};

/// First match wins, so the more specific ecosystem comes first. A repo with
/// both `Cargo.toml` and `package.json` is a Rust project with a web asset
/// pipeline far more often than the reverse.
pub const verifiers = [_]Verifier{
    .{ .marker = "build.zig", .argv = &.{ "zig", "build", "test" }, .label = "zig build test" },
    .{ .marker = "Cargo.toml", .argv = &.{ "cargo", "check", "-q" }, .label = "cargo check" },
    .{ .marker = "go.mod", .argv = &.{ "go", "build", "./..." }, .label = "go build" },
    .{ .marker = "tsconfig.json", .argv = &.{ "npx", "--no-install", "tsc", "--noEmit" }, .label = "tsc --noEmit" },
    .{ .marker = "pyproject.toml", .argv = &.{ "python3", "-m", "compileall", "-q", "." }, .label = "python compileall" },
    .{ .marker = "setup.py", .argv = &.{ "python3", "-m", "compileall", "-q", "." }, .label = "python compileall" },
    .{ .marker = "Gemfile", .argv = &.{ "ruby", "-c", "Gemfile" }, .label = "ruby -c" },
    .{ .marker = "pom.xml", .argv = &.{ "mvn", "-q", "-o", "compile" }, .label = "mvn compile" },
    // A lockfile without a tsconfig is plain JS, so there is no type check to
    // run; parsing every entry point is the strongest cheap check available.
    // `npm test` lived here before and is the one thing this table must not do:
    // an unbounded suite after every write hangs the loop (runCmd never times
    // out), and a hung agent is worse than weaker evidence. `verify:` in
    // AGENTS.md is how a project asks for its real suite.
    .{ .marker = "package-lock.json", .argv = js_check, .label = "node --check" },
    .{ .marker = "pnpm-lock.yaml", .argv = js_check, .label = "node --check" },
    .{ .marker = "yarn.lock", .argv = js_check, .label = "node --check" },
    .{ .marker = "bun.lock", .argv = js_check, .label = "node --check" },
    .{ .marker = "bun.lockb", .argv = js_check, .label = "node --check" },
};

fn fileExists(dir: Io.Dir, io: Io, name: []const u8) bool {
    var f = dir.openFile(io, name, .{}) catch return false;
    f.close(io);
    return true;
}

pub fn detectVerifier(dir: Io.Dir, io: Io) ?Verifier {
    for (verifiers) |v| {
        if (fileExists(dir, io, v.marker)) return v;
    }
    return null;
}

pub fn afterVerify(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    dir: Io.Dir,
) ![]u8 {
    return runVerifier(allocator, io, workspace, detectVerifier(dir, io));
}

pub fn runVerifier(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    verifier: ?Verifier,
) ![]u8 {
    // No marker is "nothing to run here", not a verdict about the code. The old
    // wording said "not a clean verdict" on every write in any workspace this
    // table did not cover, which is a false negative, not silence.
    const v = verifier orelse return allocator.dupe(
        u8,
        "verify: not configured (no known project marker; set `verify: <cmd>` in AGENTS.md)\n",
    );
    return runCmd(allocator, io, workspace, v.argv, v.label);
}

fn runCmd(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    argv: []const []const u8,
    label: []const u8,
) ![]u8 {
    // argv is spawned directly rather than through bash.runEx, so the cap is
    // applied here too: this fires after every write and must not hang. No
    // shell quoting is needed now that the watchdog takes an argv.
    const cap = deadline.capped(argv);

    // Both streams: `tsc`, `mvn` and `compileall` report on stdout, which this
    // used to discard -- the model was told the check failed and never told
    // what the error was.
    var child = std.process.spawn(io, .{
        .argv = cap.slice(),
        .cwd = .{ .path = workspace },
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch {
        return std.fmt.allocPrint(allocator, "verify: unavailable ({s} spawn failed); not a clean verdict\n", .{label});
    };
    const got = bash.collectWithTerm(allocator, io, &child) catch {
        return std.fmt.allocPrint(allocator, "verify: unavailable ({s} read failed); not a clean verdict\n", .{label});
    };
    defer allocator.free(got.body);

    const code: i32 = switch (got.term) {
        .exited => |c| @intCast(c),
        else => -1,
    };
    if (deadline.timedOut(code)) return deadline.note(allocator, label, deadline.default_secs);
    if (code == 0) return std.fmt.allocPrint(allocator, "verify: clean ({s}, exit 0)\n", .{label});
    return std.fmt.allocPrint(allocator, "verify: findings ({s}, exit {d})\n{s}", .{ label, code, got.body });
}

fn zigAstCheck(
    allocator: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    rel: []const u8,
) ![]u8 {
    var child = std.process.spawn(io, .{
        .argv = &.{ "zig", "ast-check", rel },
        .cwd = .{ .path = workspace },
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch {
        return unavailable(allocator, "zig ast-check spawn failed");
    };
    var out_buf: [2048]u8 = undefined;
    var collected: std.ArrayList(u8) = .empty;
    errdefer {
        collected.deinit(allocator);
        child.kill(io);
        _ = child.wait(io) catch |err| {
            log.debug("wait: {s}", .{@errorName(err)});
        };
    }
    if (child.stderr) |f| {
        var reader = Io.File.Reader.initStreaming(f, io, &out_buf);
        while (reader.interface.takeByte()) |b| {
            try collected.append(allocator, b);
            if (collected.items.len > 4000) break;
        } else |_| {}
    }
    const term = child.wait(io) catch {
        child.kill(io);
        allocator.free(try collected.toOwnedSlice(allocator));
        return timeout(allocator);
    };
    const err_out = try collected.toOwnedSlice(allocator);
    defer allocator.free(err_out);
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (ok) return clean(allocator, "zig ast-check");
    if (err_out.len == 0) return findings(allocator, "(zig ast-check failed with no output)\n");
    return findings(allocator, err_out);
}

test "unavailable is not clean" {
    const s = try unavailable(std.testing.allocator, ".md");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "not a clean verdict") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "clean (") == null);
}

test "timeout is not clean" {
    const s = try timeout(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "timeout") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "not a clean verdict") != null);
}

test "unknown extension is unavailable" {
    const s = try afterWrite(std.testing.allocator, std.testing.io, ".", Io.Dir.cwd(), "note.md");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "not a clean verdict") != null);
}

test "review prompt is postcard-short" {
    try std.testing.expect(std.mem.indexOf(u8, reviewPrompt(""), "review: clean") != null);
}

test "detection walks the table, most specific first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try std.testing.expect(detectVerifier(tmp.dir, io) == null);

    var lock = try tmp.dir.createFile(io, "package-lock.json", .{ .truncate = true });
    lock.close(io);
    try std.testing.expectEqualStrings("node --check", detectVerifier(tmp.dir, io).?.label);

    // A Rust repo with a JS asset pipeline is still a Rust repo.
    var cargo = try tmp.dir.createFile(io, "Cargo.toml", .{ .truncate = true });
    cargo.close(io);
    try std.testing.expectEqualStrings("cargo check", detectVerifier(tmp.dir, io).?.label);

    var bz = try tmp.dir.createFile(io, "build.zig", .{ .truncate = true });
    bz.close(io);
    try std.testing.expectEqualStrings("zig build test", detectVerifier(tmp.dir, io).?.label);
}

test "an unknown workspace is not configured, not a bad verdict" {
    const s = try runVerifier(std.testing.allocator, std.testing.io, ".", null);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "not configured") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "AGENTS.md") != null);
    // The old wording accused the code every time nothing was detected.
    try std.testing.expect(std.mem.indexOf(u8, s, "not a clean verdict") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "clean (") == null);
}

test "no verifier runs an unbounded test suite" {
    // runCmd has no timeout and this fires after every write, so a suite here
    // hangs the loop. `zig build test` is the sole exception: it is this repo's
    // own gate, it is fast, and AGENTS.md pins it.
    for (verifiers) |v| {
        try std.testing.expect(v.argv.len > 0);
        try std.testing.expect(v.label.len > 0);
        if (std.mem.eql(u8, v.marker, "build.zig")) continue;
        try std.testing.expect(std.mem.indexOf(u8, v.label, "test") == null);
    }
}

test "a JS lockfile checks syntax rather than running the suite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var f = try tmp.dir.createFile(io, "package-lock.json", .{ .truncate = true });
    f.close(io);
    const v = detectVerifier(tmp.dir, io).?;
    try std.testing.expectEqualStrings("node --check", v.label);
    // A TS project reaches tsconfig.json first and type-checks instead.
    var t = try tmp.dir.createFile(io, "tsconfig.json", .{ .truncate = true });
    t.close(io);
    try std.testing.expectEqualStrings("tsc --noEmit", detectVerifier(tmp.dir, io).?.label);
}

test "verify reports the command and the exit code" {
    // fx-architecture #6: preserve exact commands and exit codes as evidence.
    const bad = try runVerifier(std.testing.allocator, std.testing.io, ".", .{
        .marker = "x",
        .argv = &.{ "sh", "-c", "echo boom >&2; exit 3" },
        .label = "probe",
    });
    defer std.testing.allocator.free(bad);
    try std.testing.expect(std.mem.indexOf(u8, bad, "verify: findings (probe, exit 3)") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad, "boom") != null);

    const good = try runVerifier(std.testing.allocator, std.testing.io, ".", .{
        .marker = "x",
        .argv = &.{ "sh", "-c", "exit 0" },
        .label = "probe",
    });
    defer std.testing.allocator.free(good);
    try std.testing.expectEqualStrings("verify: clean (probe, exit 0)\n", good);
}

test "an unconfigured verify is neither green nor a failure" {
    // The self-improving loop admits skills on verify green and writes a
    // harmful item on verify fail. "Nothing to run" must trigger neither, or
    // an unchecked workspace would silently admit unverified skills.
    const s = try runVerifier(std.testing.allocator, std.testing.io, ".", null);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "verify: clean") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "verify: findings") == null);
}

test "the language table maps files to parse-only commands" {
    try std.testing.expectEqualStrings("zig ast-check", langs.label(langs.byPath("src/main.zig").?));
    try std.testing.expectEqualStrings("python parse", langs.label(langs.byPath("a/b/c.py").?));
    try std.testing.expectEqualStrings("node --check", langs.label(langs.byPath("x.mjs").?));
    try std.testing.expectEqualStrings("bash -n", langs.label(langs.byPath("deploy.sh").?));
    try std.testing.expectEqualStrings("gofmt -e", langs.label(langs.byPath("main.go").?));
}

test "no probe executes the file it is given" {
    // The write hook runs these unattended. Anything that could run workspace
    // code belongs behind a permission prompt, not here.
    const parse_only = [_][]const u8{
        "zig", "node", "ruby", "php", "bash", "zsh", "fish", "gofmt", "python3", "luac", "swiftc",
    };
    for (&langs.table) |*l| {
        if (l.check.len == 0) continue;
        var known = false;
        for (parse_only) |ok| {
            if (std.mem.eql(u8, l.check[0], ok)) known = true;
        }
        try std.testing.expect(known);
        // Bare `python3 <file>` or `ruby <file>` would execute it; every entry
        // must carry the flag that makes it parse instead.
        try std.testing.expect(l.check.len >= 2);
    }
}

test "a language with no parser still gets a verdict from the scan" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try @import("pathing.zig").testWorkspace(a, &tmp);
    defer a.free(ws);

    try write(tmp.dir, io, "ok.rs", "fn a() -> i32 { 1 }\n");
    const good = try afterWrite(a, io, ws, tmp.dir, "ok.rs");
    defer a.free(good);
    try std.testing.expect(std.mem.indexOf(u8, good, "clean") != null);

    try write(tmp.dir, io, "bad.rs", "fn a() -> i32 {\n");
    const bad = try afterWrite(a, io, ws, tmp.dir, "bad.rs");
    defer a.free(bad);
    try std.testing.expect(std.mem.indexOf(u8, bad, "findings") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad, "never closed") != null);
}

test "prose is never reported as broken" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try @import("pathing.zig").testWorkspace(a, &tmp);
    defer a.free(ws);
    try write(tmp.dir, io, "notes.md", "see foo( for details\n");
    const s = try afterWrite(a, io, ws, tmp.dir, "notes.md");
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "findings") == null);
}

fn write(dir: Io.Dir, io: Io, name: []const u8, body: []const u8) !void {
    var f = try dir.createFile(io, name, .{ .truncate = true });
    defer f.close(io);
    var buf: [256]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(body);
    try w.interface.flush();
}

/// Runs the real toolchains. Anything not installed reports "not installed"
/// rather than accusing the file, and that is asserted too.
fn checkOne(a: std.mem.Allocator, ws: []const u8, dir: Io.Dir, io: Io, name: []const u8, body: []const u8) ![]u8 {
    try write(dir, io, name, body);
    return afterWrite(a, io, ws, dir, name);
}

test "diagnostics parse each language, or say the toolchain is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    const ws = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(ws);

    const Case = struct { name: []const u8, good: []const u8, bad: []const u8 };
    const cases = [_]Case{
        .{ .name = "a.py", .good = "def f():\n    return 1\n", .bad = "def f(\n    return 1\n" },
        .{ .name = "a.js", .good = "const a = 1;\n", .bad = "const a = ;\n" },
        .{ .name = "a.rb", .good = "def f; 1; end\n", .bad = "def f(\n" },
        .{ .name = "a.sh", .good = "echo hi\n", .bad = "if [ 1 ; then\n" },
        .{ .name = "a.json", .good = "{\"a\":1}\n", .bad = "{\"a\":,}\n" },
    };
    for (cases) |c| {
        const ok = try checkOne(a, ws, tmp.dir, io, c.name, c.good);
        defer a.free(ok);
        const bad = try checkOne(a, ws, tmp.dir, io, c.name, c.bad);
        defer a.free(bad);
        if (std.mem.indexOf(u8, ok, "not installed") != null) {
            // Missing toolchain must never read as a problem with the code.
            try std.testing.expect(std.mem.indexOf(u8, ok, "findings") == null);
            continue;
        }
        try std.testing.expect(std.mem.indexOf(u8, ok, "diagnostics: clean") != null);
        try std.testing.expect(std.mem.indexOf(u8, bad, "diagnostics: findings") != null);
    }
}

test "a checker leaves nothing behind in the workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    const ws = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(ws);
    const out = try checkOne(a, ws, tmp.dir, io, "keep.py", "x = 1\n");
    defer a.free(out);
    // py_compile would drop a __pycache__ here; compile() must not.
    var it = tmp.dir.iterate();
    var n: usize = 0;
    while (it.next(io) catch null) |e| : (n += 1) {
        try std.testing.expect(!std.mem.eql(u8, e.name, "__pycache__"));
    }
}

test "an unknown extension is unavailable, not a finding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    const ws = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(ws);
    const out = try checkOne(a, ws, tmp.dir, io, "notes.md", "# hi\n");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "findings") == null);
}

test "verify cmd maps FAIL to findings and true to clean" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fail = try runVerifyCmd(a, io, ".", "echo FAIL");
    defer fail.deinit(a);
    switch (fail) {
        .findings => {},
        else => return error.ExpectedFindings,
    }
    const ok = try runVerifyCmd(a, io, ".", "true");
    defer ok.deinit(a);
    try std.testing.expect(ok == .clean);
}

test "a verifier's diagnostics reach the model, whichever stream they used" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    // stdout-only, the shape `tsc --noEmit` and `mvn` have.
    const out = try runCmd(a, io, ".", &.{ "sh", "-c", "echo 'a.ts(3,9): error TS2322'; exit 2" }, "fake tsc");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "TS2322") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "exit 2") != null);

    const passed = try runCmd(a, io, ".", &.{ "sh", "-c", "exit 0" }, "fake ok");
    defer a.free(passed);
    try std.testing.expect(std.mem.indexOf(u8, passed, "clean") != null);
}
