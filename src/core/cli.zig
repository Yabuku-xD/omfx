const std = @import("std");
const Io = std.Io;

pub const bin = "omfx";
pub const title = "Oh My Fx";
pub const version = "0.0.1";

pub const Command = enum {
    interactive,
    ask,
    doctor,
    login,
    session,
    browser_relay,
    update,
    version,
    help,
};

pub const Spec = struct {
    name: []const u8,
    tag: Command,
    summary: []const u8,
    usage: []const u8,
};

pub const commands = [_]Spec{
    .{ .name = "ask", .tag = .ask, .summary = "One-shot request (no alt screen)", .usage = "Examples:\n  omfx ask \"what does src/main.zig do?\"\n  omfx ask --json --provider groq \"summarize this repo\"\n\nUsage:\n  omfx ask [--provider <id>] [--model <name>] [--auto|--yolo] [--prompt-permissions] [--effort <none|low|medium|high>] [--resume last|<id>] [--json] <prompt>" },
    .{ .name = "login", .tag = .login, .summary = "Prefer /login inside a session", .usage = "Prefer `/login` inside an interactive session.\n\nAlso: omfx login [provider]\n  omfx login                 List providers\n  omfx login xai-oauth       SuperGrok / X Premium+ (device code)\n  omfx login anthropic       Claude Pro/Max (browser PKCE)\n  omfx login openai-codex    ChatGPT Plus/Pro\n  omfx login github-copilot  GitHub Copilot (device code)\n  omfx login groq            Paste an API key" },
    .{ .name = "session", .tag = .session, .summary = "Prefer /session inside a session", .usage = "Prefer `/session` or `/resume` inside an interactive session.\n\nAlso:\n  omfx session\n  omfx session resume last\n  omfx session <id>" },
    .{ .name = "browser-relay", .tag = .browser_relay, .summary = "Prefer /browser inside a session", .usage = "Prefer `/browser` inside an interactive session.\n\nAlso: omfx browser-relay [install]\n  omfx browser-relay          Listen on 127.0.0.1:9224 (Chrome extension dials /ext)\n  omfx browser-relay install  Write ~/.omfx/browser-relay/extension for Load unpacked" },
    .{ .name = "doctor", .tag = .doctor, .summary = "Print runtime status", .usage = "omfx doctor" },
    .{ .name = "update", .tag = .update, .summary = "Check for and install updates", .usage = "omfx update [--check] [--force]\n\n  omfx update         Install the latest GitHub release\n  omfx update --check  Report whether a newer release exists\n  omfx update --force  Reinstall even when already current\n\nUses the same install.sh path as a fresh install (SHA256 verified).\nIf GitHub rate-limits release metadata, set GITHUB_TOKEN or GH_TOKEN." },
    .{ .name = "version", .tag = .version, .summary = "Print version", .usage = "omfx version" },
    .{ .name = "help", .tag = .help, .summary = "Show this help", .usage = "omfx help [command]" },
};

pub const ParseError = error{
    UnknownCommand,
    UnknownFlag,
    MissingValue,
    OutOfMemory,
};

pub const Parsed = struct {
    command: Command = .interactive,
    rest: []const []const u8 = &.{},
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    yolo: bool = false,
    auto: bool = false,
    prompt_permissions: bool = false,
    effort: ?[]const u8 = null,
    resume_id: ?[]const u8 = null,
    want_help: bool = false,
    help_topic: ?[]const u8 = null,
    json: bool = false,
    check: bool = false,
    force: bool = false,
};

const Flag = enum {
    help,
    version,
    yolo,
    auto,
    prompt_permissions,
    effort,
    effort_eq,
    @"resume",
    resume_eq,
    provider,
    provider_eq,
    model,
    model_eq,
    json,
    check,
    force,
    end_opts,
    positional,
    unknown,
};

fn classify(a: []const u8) Flag {
    if (std.mem.eql(u8, a, "--")) return .end_opts;
    if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return .help;
    if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) return .version;
    if (std.mem.eql(u8, a, "--yolo")) return .yolo;
    if (std.mem.eql(u8, a, "--auto")) return .auto;
    if (std.mem.eql(u8, a, "--prompt-permissions")) return .prompt_permissions;
    if (std.mem.eql(u8, a, "--effort")) return .effort;
    if (std.mem.startsWith(u8, a, "--effort=")) return .effort_eq;
    if (std.mem.eql(u8, a, "--resume")) return .@"resume";
    if (std.mem.startsWith(u8, a, "--resume=")) return .resume_eq;
    if (std.mem.eql(u8, a, "--provider")) return .provider;
    if (std.mem.startsWith(u8, a, "--provider=")) return .provider_eq;
    if (std.mem.eql(u8, a, "--model")) return .model;
    if (std.mem.startsWith(u8, a, "--model=")) return .model_eq;
    if (std.mem.eql(u8, a, "--json")) return .json;
    if (std.mem.eql(u8, a, "--check")) return .check;
    if (std.mem.eql(u8, a, "--force")) return .force;
    if (a.len > 0 and a[0] == '-') return .unknown;
    return .positional;
}

fn takeValue(args: []const []const u8, i: *usize) ParseError![]const u8 {
    i.* += 1;
    if (i.* >= args.len) return error.MissingValue;
    return args[i.*];
}

pub fn commandFromName(name: []const u8) ?Command {
    for (commands) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec.tag;
    }
    return null;
}

pub fn specByTag(tag: Command) ?Spec {
    for (commands) |spec| {
        if (spec.tag == tag) return spec;
    }
    return null;
}

/// Global flags may appear before or after the subcommand. kebab-case only.
pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) ParseError!Parsed {
    var parsed: Parsed = .{};
    var positionals: std.ArrayList([]const u8) = .empty;
    errdefer positionals.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        switch (classify(args[i])) {
            .end_opts => {
                try positionals.appendSlice(allocator, args[i + 1 ..]);
                break;
            },
            .help => parsed.want_help = true,
            .version => parsed.command = .version,
            .yolo => parsed.yolo = true,
            .auto => parsed.auto = true,
            .prompt_permissions => parsed.prompt_permissions = true,
            .effort => parsed.effort = try takeValue(args, &i),
            .effort_eq => parsed.effort = args[i]["--effort=".len..],
            .@"resume" => {
                if (i + 1 < args.len and args[i + 1].len > 0 and args[i + 1][0] != '-') {
                    i += 1;
                    parsed.resume_id = args[i];
                } else {
                    parsed.resume_id = "last";
                }
            },
            .resume_eq => parsed.resume_id = args[i]["--resume=".len..],
            .provider => parsed.provider = try takeValue(args, &i),
            .provider_eq => parsed.provider = args[i]["--provider=".len..],
            .model => parsed.model = try takeValue(args, &i),
            .model_eq => parsed.model = args[i]["--model=".len..],
            .json => parsed.json = true,
            .check => parsed.check = true,
            .force => parsed.force = true,
            .positional => try positionals.append(allocator, args[i]),
            .unknown => return error.UnknownFlag,
        }
    }

    if (positionals.items.len > 0) {
        const name = positionals.items[0];
        if (commandFromName(name)) |tag| {
            parsed.command = tag;
            const rest = if (tag == .help and positionals.items.len > 1) blk: {
                parsed.help_topic = positionals.items[1];
                break :blk positionals.items[1..];
            } else positionals.items[1..];
            parsed.rest = try allocator.dupe([]const u8, rest);
        } else {
            return error.UnknownCommand;
        }
    } else if (parsed.want_help and parsed.command == .interactive) {
        parsed.command = .help;
    }

    positionals.deinit(allocator);
    return parsed;
}

pub const help_text =
    \\omfx - Oh My Fx, a unix-like coding agent
    \\
    \\Examples:
    \\  omfx
    \\  omfx ask "what does src/main.zig do?"
    \\  omfx login
    \\
    \\Usage:
    \\  omfx [flags]                 Interactive full-screen session
    \\  omfx ask [flags] <prompt>    One-shot request (no alt screen)
    \\
    \\Inside a session (type /help for all):
    \\  /login    sign in to model providers
    \\  /web      web search keys and fallback order
    \\  /browser  install the Chrome relay extension
    \\  /peers    run a teammate: /peers <goal>
    \\  /session  list or resume saved sessions
    \\
    \\CLI:
    \\  ask            One-shot request (no alt screen)
    \\  browser-relay  Chrome extension relay (existing tabs)
    \\  doctor         Print runtime status
    \\  update         Check for and install updates
    \\  version        Print version
    \\  help           Show this help
    \\
    \\Flags:
    \\  -h, --help                Show help
    \\  -V, --version             Print version
    \\      --provider <id>       Provider (groq, anthropic, ollama, ...)
    \\      --model <name>        Model id
    \\      --effort <level>      Reasoning effort (none|low|medium|high)
    \\      --auto                Allow routine reversible tools without a prompt
    \\      --yolo                Allow writes without a TTY prompt
    \\      --prompt-permissions  Y/N on stderr for `omfx ask` when stdin is a TTY
    \\      --json                omfx ask emits JSONL events
    \\      --resume [last|id]    Continue a saved session
    \\      --check               With update: report only, do not install
    \\      --force               With update: reinstall even if current
    \\
    \\Exit:
    \\  0   ok
    \\  2   bad usage (unknown command, flag, or missing prompt)
    \\  78  no provider configured
    \\
    \\Run `omfx help <command>` for command usage.
    \\
;

const paint = @import("ansi.zig");

/// Paint a plain help block: `Section:` headings bold, the term column accent,
/// its description muted. Off when stdout is not a terminal, so pipes stay clean.
pub fn writeHelp(w: *Io.Writer, text: []const u8, color: bool) !void {
    if (!color) return w.writeAll(text);
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try w.writeAll("\n");
        first = false;
        if (line.len == 0) continue;
        if (line[0] != ' ' and std.mem.endsWith(u8, line, ":")) {
            try w.print("{s}{s}{s}", .{ paint.bold, line, paint.reset });
            continue;
        }
        if (!std.mem.startsWith(u8, line, "  ")) {
            try w.writeAll(line);
            continue;
        }
        const body = std.mem.trimStart(u8, line, " ");
        const indent = line[0 .. line.len - body.len];
        const split = std.mem.indexOf(u8, body, "  ") orelse {
            try w.print("{s}{s}{s}{s}", .{ indent, paint.accent, body, paint.reset });
            continue;
        };
        const rest = body[split..];
        const desc = std.mem.trimStart(u8, rest, " ");
        try w.print("{s}{s}{s}{s}{s}{s}{s}{s}", .{
            indent,                         paint.accent, body[0..split], paint.reset,
            rest[0 .. rest.len - desc.len], paint.muted,  desc,           paint.reset,
        });
    }
}

pub fn commandHelp(tag: Command) []const u8 {
    const spec = specByTag(tag) orelse return help_text;
    return spec.usage;
}

pub const exit_ok: u8 = 0;
pub const exit_fail: u8 = 1;
pub const exit_usage: u8 = 2;
pub const exit_config: u8 = 78;

pub const Fail = struct {
    code: []const u8,
    message: []const u8,
    fix: []const u8,
    transient: bool = false,
};

fn writeEscaped(w: *Io.Writer, s: []const u8) void {
    for (s) |c| switch (c) {
        '"' => w.writeAll("\\\"") catch return,
        '\\' => w.writeAll("\\\\") catch return,
        '\n' => w.writeAll("\\n") catch return,
        '\r' => {},
        else => w.writeByte(c) catch return,
    };
}

pub fn writeFail(w: *Io.Writer, json: bool, fail: Fail) void {
    if (json) {
        w.writeAll("{\"ok\":false,\"error\":{\"code\":\"") catch return;
        w.writeAll(fail.code) catch return;
        w.writeAll("\",\"message\":\"") catch return;
        writeEscaped(w, fail.message);
        w.writeAll("\",\"fix\":\"") catch return;
        writeEscaped(w, fail.fix);
        w.writeAll("\",\"transient\":") catch return;
        w.writeAll(if (fail.transient) "true" else "false") catch return;
        w.writeAll("}}\n") catch return;
        return;
    }
    w.print("Error: {s}: {s}\n\nFix: {s}\n", .{ fail.code, fail.message, fail.fix }) catch {};
}

fn editDistance(a: []const u8, b: []const u8) usize {
    const n = a.len;
    const m = b.len;
    if (n == 0) return m;
    if (m == 0) return n;
    if (n >= 32 or m >= 32) return std.math.maxInt(usize);
    var prev: [32]usize = undefined;
    var curr: [32]usize = undefined;
    var j: usize = 0;
    while (j <= m) : (j += 1) prev[j] = j;
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        curr[0] = i;
        j = 1;
        while (j <= m) : (j += 1) {
            const cost: usize = if (std.ascii.toLower(a[i - 1]) == std.ascii.toLower(b[j - 1])) 0 else 1;
            curr[j] = @min(prev[j] + 1, @min(curr[j - 1] + 1, prev[j - 1] + cost));
        }
        @memcpy(prev[0 .. m + 1], curr[0 .. m + 1]);
    }
    return prev[m];
}

/// Nearest command name, or null if nothing is close enough to suggest.
pub fn closestCommand(name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_d: usize = 3;
    for (commands) |spec| {
        var d = editDistance(name, spec.name);
        if (name.len >= 2 and std.ascii.startsWithIgnoreCase(spec.name, name)) d = @min(d, 1);
        if (d < best_d) {
            best_d = d;
            best = spec.name;
        }
    }
    return best;
}

test "no args is interactive" {
    const args = [_][]const u8{"omfx"};
    const parsed = try parseArgs(std.testing.allocator, &args);
    try std.testing.expectEqual(Command.interactive, parsed.command);
}

test "help flags" {
    const a = [_][]const u8{ "omfx", "--help" };
    try std.testing.expectEqual(Command.help, (try parseArgs(std.testing.allocator, &a)).command);
    const b = [_][]const u8{ "omfx", "-h" };
    try std.testing.expectEqual(Command.help, (try parseArgs(std.testing.allocator, &b)).command);
}

test "subcommand list is complete" {
    try std.testing.expectEqual(@as(usize, 8), commands.len);
    try std.testing.expectEqualStrings("ask", commands[0].name);
}

test "update flags" {
    const a = [_][]const u8{ "omfx", "update", "--check" };
    const p = try parseArgs(std.testing.allocator, &a);
    defer std.testing.allocator.free(p.rest);
    try std.testing.expectEqual(Command.update, p.command);
    try std.testing.expect(p.check);
    try std.testing.expect(!p.force);

    const b = [_][]const u8{ "omfx", "update", "--force" };
    const q = try parseArgs(std.testing.allocator, &b);
    defer std.testing.allocator.free(q.rest);
    try std.testing.expectEqual(Command.update, q.command);
    try std.testing.expect(q.force);
}

test "known subcommands and flags" {
    const ask = [_][]const u8{ "omfx", "ask", "hello" };
    const p = try parseArgs(std.testing.allocator, &ask);
    defer std.testing.allocator.free(p.rest);
    try std.testing.expectEqual(Command.ask, p.command);
    try std.testing.expectEqual(@as(usize, 1), p.rest.len);
    try std.testing.expectEqualStrings("hello", p.rest[0]);

    const flagged = [_][]const u8{ "omfx", "--provider", "groq", "ask", "--yolo", "hi" };
    const q = try parseArgs(std.testing.allocator, &flagged);
    defer std.testing.allocator.free(q.rest);
    try std.testing.expectEqual(Command.ask, q.command);
    try std.testing.expectEqualStrings("groq", q.provider.?);
    try std.testing.expect(q.yolo);
    try std.testing.expectEqualStrings("hi", q.rest[0]);

    const login = [_][]const u8{ "omfx", "login", "groq" };
    const l = try parseArgs(std.testing.allocator, &login);
    defer std.testing.allocator.free(l.rest);
    try std.testing.expectEqual(Command.login, l.command);
}

test "unknown subcommand errors" {
    const args = [_][]const u8{ "omfx", "not-a-command" };
    try std.testing.expectError(error.UnknownCommand, parseArgs(std.testing.allocator, &args));
}

test "unknown flag errors" {
    const args = [_][]const u8{ "omfx", "--nope" };
    try std.testing.expectError(error.UnknownFlag, parseArgs(std.testing.allocator, &args));
}

test "help text is a command list" {
    try std.testing.expect(std.mem.indexOf(u8, help_text, "CLI:") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "  ask") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "/login") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "/web") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "/browser") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "/peers") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "Flags:") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "Examples:") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "Exit:") != null);
}

test "closestCommand suggests typos" {
    try std.testing.expectEqualStrings("doctor", closestCommand("doktor").?);
    try std.testing.expectEqualStrings("ask", closestCommand("as").?);
    try std.testing.expect(closestCommand("zzzzzzzz") == null);
}

test "writeFail human and json" {
    const fail = Fail{ .code = "MISSING_PROMPT", .message = "omfx ask needs a prompt", .fix = "omfx ask \"hello\"" };
    {
        var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        writeFail(&aw.writer, false, fail);
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Error: MISSING_PROMPT") != null);
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Fix: omfx ask") != null);
    }
    {
        var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        writeFail(&aw.writer, true, fail);
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"ok\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "MISSING_PROMPT") != null);
    }
}

test "session usage does not say ffx" {
    const usage = commandHelp(.session);
    try std.testing.expect(std.mem.indexOf(u8, usage, "ffx") == null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "omfx session") != null);
}

test "auto prompt-permissions effort and resume flags" {
    const a = [_][]const u8{ "omfx", "ask", "--auto", "--prompt-permissions", "--effort", "low", "--resume", "last", "hi" };
    const p = try parseArgs(std.testing.allocator, &a);
    defer std.testing.allocator.free(p.rest);
    try std.testing.expect(p.auto);
    try std.testing.expect(p.prompt_permissions);
    try std.testing.expectEqualStrings("low", p.effort.?);
    try std.testing.expectEqualStrings("last", p.resume_id.?);
    try std.testing.expectEqualStrings("hi", p.rest[0]);
}

test "session resume is a command" {
    const a = [_][]const u8{ "omfx", "session", "resume", "last" };
    const p = try parseArgs(std.testing.allocator, &a);
    defer std.testing.allocator.free(p.rest);
    try std.testing.expectEqual(Command.session, p.command);
    try std.testing.expectEqualStrings("resume", p.rest[0]);
}

test "omfx help ask sets topic" {
    const args = [_][]const u8{ "omfx", "help", "ask" };
    const p = try parseArgs(std.testing.allocator, &args);
    defer std.testing.allocator.free(p.rest);
    try std.testing.expectEqual(Command.help, p.command);
    try std.testing.expectEqualStrings("ask", p.help_topic.?);
}
