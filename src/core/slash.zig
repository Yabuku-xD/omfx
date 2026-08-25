const std = @import("std");

pub const Name = enum {
    help,
    shortcuts,
    login,
    web,
    browser,
    reload,
    @"resume",
    yolo,
    effort,
    peers,
    clear,
    reset,
    @"continue",
    rename,
    compact,
    quit,
    logout,
    models,
    fast,
    permissions,
    allowlist,
    sandbox,
    status,
    stats,
    usage,
    context,
    settings,
    appearance,
    statusline,
    sound,
    thinking,
    version,
    background,
    mcp,
    workspace,
    undo,
    copy,
    diagram,
    feedback,
    trace,
    plan,
    init,
    rewind,
    fork,
    handoff,
    spec,
    checkpoint,
    sleep,
    wake,
    ide,
    plugin,
    files,

    pub fn fromToken(token: []const u8) ?Name {
        if (token.len < 2 or token[0] != '/') return null;
        const rest = token[1..];
        const aliases = [_]struct { from: []const u8, to: Name }{
            .{ .from = "peer", .to = .peers },
            .{ .from = "new", .to = .clear },
            .{ .from = "exit", .to = .quit },
            .{ .from = "setup", .to = .login },
            .{ .from = "cost", .to = .usage },
            // One command for models. `/model` was a second door onto the same
            // list, and a picker and a setter that disagreed about defaults.
            .{ .from = "model", .to = .models },
        };
        for (aliases) |a| {
            if (std.mem.eql(u8, rest, a.from)) return a.to;
        }
        return std.meta.stringToEnum(Name, rest);
    }
};

pub const Spec = struct {
    name: []const u8,
    help: []const u8,
    /// What follows the command, shown as a ghost in the composer once the
    /// name is complete. A command whose arguments you have to remember is a
    /// command you go to `/help` for instead of using.
    args: []const u8 = "",
    /// Draw `help` in the left column and `name` in the right. True for rows
    /// whose id is machinery and whose description is the thing you read --
    /// a provider is "Anthropic (Claude Pro/Max)", not "anthropic".
    flip: bool = false,
};

/// The argument hint for a completed command name, or "" when it takes none.
pub fn argsFor(name: []const u8) []const u8 {
    for (builtin) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec.args;
    }
    return "";
}

pub const builtin = [_]Spec{
    .{ .name = "/help", .help = "list slash commands" },
    .{ .name = "/shortcuts", .help = "every keyboard shortcut, searchable" },
    .{ .name = "/clear", .help = "start a fresh chat; keeps background work (/new)" },
    .{ .name = "/reset", .help = "start a fresh chat and stop background work" },
    .{ .name = "/resume", .help = "open a saved chat" },
    .{ .name = "/continue", .help = "pick a chat to continue, or retry the last turn" },
    .{ .name = "/rename", .help = "rename this chat", .args = "[title]" },
    .{ .name = "/compact", .help = "shorten older parts of this chat", .args = "[focus]" },
    .{ .name = "/rewind", .help = "go back to an earlier message, or trim from one", .args = "[list|<n>|<n> from|<n> upto]" },
    .{ .name = "/fork", .help = "copy this session to a new id; keep working here" },
    .{ .name = "/handoff", .help = "new session from a thin packet (no transcript dump)", .args = "[goal]" },
    .{ .name = "/spec", .help = "spec-first: disk docs + phase postcard; next/run", .args = "[new <name>|<name>|next|run|list]" },
    .{ .name = "/checkpoint", .help = "park pointers under .omfx/runs/ (no transcript dump)", .args = "[note]" },
    .{ .name = "/sleep", .help = "checkpoint + mark sleeping (zero compute until /wake)", .args = "[note]" },
    .{ .name = "/wake", .help = "resume a run from a thin stub", .args = "[id|list]" },
    .{ .name = "/quit", .help = "exit (/exit)" },
    .{ .name = "/login", .help = "sign in to model providers (/setup)", .args = "[provider]" },
    .{ .name = "/logout", .help = "remove a stored provider key" },
    .{ .name = "/models", .help = "models from the provider you are signed in to", .args = "[id|refresh]" },
    .{ .name = "/fast", .help = "toggle effort=none", .args = "[on|off]" },
    .{ .name = "/permissions", .help = "inspect or set ask|auto|yolo", .args = "[ask|auto|yolo]" },
    .{ .name = "/allowlist", .help = "permission DSL; session rules shrink only", .args = "[session] <pattern> allow|ask|deny" },
    .{ .name = "/sandbox", .help = "inspect or set command sandbox on|off", .args = "[on|off]" },
    .{ .name = "/yolo", .help = "allow writes this session" },
    .{ .name = "/effort", .help = "reasoning level; auto picks one per prompt", .args = "[auto|<level>]  ctrl-t cycles" },
    .{ .name = "/plan", .help = "plan first (no changes); /plan go carries it out", .args = "[go|off|<goal>]" },
    .{ .name = "/status", .help = "model, workspace, permissions, session" },
    .{ .name = "/stats", .help = "current-session statistics" },
    .{ .name = "/context", .help = "where the context window has gone" },
    .{ .name = "/usage", .help = "local usage (/cost)" },
    .{ .name = "/settings", .help = "show settings.json", .args = "[key=value]" },
    .{ .name = "/appearance", .help = "input presentation" },
    .{ .name = "/statusline", .help = "toggle footer fields", .args = "[on|off]" },
    .{ .name = "/sound", .help = "toggle launch and completion chimes", .args = "[on|off]" },
    .{ .name = "/thinking", .help = "toggle thinking text in the tui", .args = "[on|off]" },
    .{ .name = "/version", .help = "show installed version" },
    .{ .name = "/web", .help = "web search backends and order", .args = "" },
    .{ .name = "/browser", .help = "install Chrome relay extension (existing tabs)" },
    .{ .name = "/reload", .help = "reload settings, auth, reads, relay" },
    .{ .name = "/background", .help = "see work running in the background", .args = "[id]" },
    .{ .name = "/mcp", .help = "list MCP servers", .args = "[name]" },
    .{ .name = "/ide", .help = "open workspace in your IDE", .args = "[open|<ide>]" },
    .{ .name = "/plugin", .help = "plugin marketplaces (.claude-plugin / .omfx-plugin)", .args = "[list|marketplace add|install]" },
    .{ .name = "/init", .help = "scaffold AGENTS.md from the repo", .args = "[path]" },
    .{ .name = "/workspace", .help = "show workspace; add extra dirs", .args = "[path]" },
    .{ .name = "/undo", .help = "undo the most recent tracked file change" },
    .{ .name = "/copy", .help = "copy the latest assistant reply" },
    .{ .name = "/diagram", .help = "save mermaid fences from the last reply", .args = "[path]" },
    .{ .name = "/feedback", .help = "where to send a bug report" },
    .{ .name = "/trace", .help = "write a private diagnostic trace" },
    .{ .name = "/peers", .help = "ask a teammate to work on a goal", .args = "[goal]" },
    .{ .name = "/files", .help = "pick a file to mention in what you type" },
};

const rank_count: usize = 3;

fn matchRank(command: []const u8, prefix: []const u8) ?usize {
    if (std.mem.eql(u8, command, prefix)) return 0;
    if (std.mem.startsWith(u8, command, prefix)) return 1;
    if (prefix.len <= 1 or command.len <= 1) return null;
    if (std.mem.indexOf(u8, command[1..], prefix[1..]) != null) return 2;
    return null;
}

pub fn nth(specs: []const Spec, prefix: []const u8, n: usize) ?Spec {
    if (prefix.len == 0 or prefix[0] != '/') return null;
    var idx: usize = 0;
    var rank: usize = 0;
    while (rank < rank_count) : (rank += 1) {
        for (specs) |spec| {
            const r = matchRank(spec.name, prefix) orelse continue;
            if (r != rank) continue;
            if (idx == n) return spec;
            idx += 1;
        }
    }
    return null;
}

pub fn count(specs: []const Spec, prefix: []const u8) usize {
    var n: usize = 0;
    while (nth(specs, prefix, n)) |_| n += 1;
    return n;
}

const Group = struct { title: []const u8, names: []const []const u8 };

/// The spec for a command name, or null. Used by the help panel, which shows
/// the same list and help text the transcript form printed.
pub fn find(name: []const u8) ?Spec {
    for (builtin) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

pub const groups = [_]Group{
    .{ .title = "Session", .names = &.{ "/help", "/clear", "/reset", "/resume", "/continue", "/rename", "/compact", "/rewind", "/fork", "/handoff", "/spec", "/checkpoint", "/sleep", "/wake", "/quit" } },
    .{ .title = "Account / model", .names = &.{ "/login", "/logout", "/models", "/fast", "/permissions", "/allowlist", "/sandbox", "/yolo", "/effort", "/plan" } },
    .{ .title = "Inspect", .names = &.{ "/status", "/stats", "/usage", "/context", "/shortcuts", "/settings", "/appearance", "/statusline", "/sound", "/thinking", "/version" } },
    .{ .title = "Tools", .names = &.{ "/web", "/browser", "/reload", "/background", "/mcp", "/ide", "/plugin", "/init", "/workspace", "/undo", "/copy", "/diagram", "/feedback", "/trace", "/peers", "/files" } },
};

fn specNamed(specs: []const Spec, name: []const u8) ?Spec {
    for (specs) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

pub fn helpFor(allocator: std.mem.Allocator, specs: []const Spec, token: []const u8) ![]u8 {
    var buf: [48]u8 = undefined;
    const name = if (token.len > 0 and token[0] == '/')
        token
    else
        std.fmt.bufPrint(&buf, "/{s}", .{token}) catch token;
    if (specNamed(specs, name)) |spec| {
        return std.fmt.allocPrint(allocator, "{s}  {s}\n", .{ spec.name, spec.help });
    }
    return std.fmt.allocPrint(allocator, "unknown command {s}\n", .{token});
}

pub fn helpText(allocator: std.mem.Allocator, specs: []const Spec) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var written: usize = 0;
    for (groups) |g| {
        try out.appendSlice(allocator, g.title);
        try out.appendSlice(allocator, ":\n");
        for (g.names) |name| {
            const spec = specNamed(specs, name) orelse continue;
            try out.appendSlice(allocator, "  ");
            try out.appendSlice(allocator, spec.name);
            try out.appendSlice(allocator, "  ");
            try out.appendSlice(allocator, spec.help);
            try out.append(allocator, '\n');
            written += 1;
        }
    }
    if (written < specs.len) {
        try out.appendSlice(allocator, "Other:\n");
        for (specs) |spec| {
            var grouped = false;
            for (groups) |g| {
                for (g.names) |n| {
                    if (std.mem.eql(u8, n, spec.name)) grouped = true;
                }
            }
            if (grouped) continue;
            try out.appendSlice(allocator, "  ");
            try out.appendSlice(allocator, spec.name);
            try out.appendSlice(allocator, "  ");
            try out.appendSlice(allocator, spec.help);
            try out.append(allocator, '\n');
        }
    }
    return out.toOwnedSlice(allocator);
}

test "slash Name fromToken is exact" {
    try std.testing.expectEqual(Name.help, Name.fromToken("/help").?);
    try std.testing.expectEqual(Name.browser, Name.fromToken("/browser").?);
    try std.testing.expectEqual(Name.peers, Name.fromToken("/peers").?);
    try std.testing.expectEqual(Name.peers, Name.fromToken("/peer").?);
    try std.testing.expect(Name.fromToken("/hel") == null);
}

test "plan init rewind fork are exact names" {
    try std.testing.expectEqual(Name.plan, Name.fromToken("/plan").?);
    try std.testing.expectEqual(Name.init, Name.fromToken("/init").?);
    try std.testing.expectEqual(Name.rewind, Name.fromToken("/rewind").?);
    try std.testing.expectEqual(Name.fork, Name.fromToken("/fork").?);
    try std.testing.expectEqual(Name.handoff, Name.fromToken("/handoff").?);
    try std.testing.expectEqual(Name.thinking, Name.fromToken("/thinking").?);
    try std.testing.expectEqual(Name.diagram, Name.fromToken("/diagram").?);
}

test "fx aliases map onto existing names" {
    try std.testing.expectEqual(Name.clear, Name.fromToken("/clear").?);
    try std.testing.expectEqual(Name.clear, Name.fromToken("/new").?);
    try std.testing.expectEqual(Name.quit, Name.fromToken("/quit").?);
    try std.testing.expectEqual(Name.quit, Name.fromToken("/exit").?);
    try std.testing.expectEqual(Name.login, Name.fromToken("/setup").?);
    try std.testing.expectEqual(Name.usage, Name.fromToken("/cost").?);
    try std.testing.expect(Name.fromToken("/credits") == null);
    try std.testing.expect(Name.fromToken("/balance") == null);
    try std.testing.expectEqual(Name.@"continue", Name.fromToken("/continue").?);
    try std.testing.expectEqual(Name.@"resume", Name.fromToken("/resume").?);
}

test "slash ranks exact prefix then substring" {
    const specs = [_]Spec{
        .{ .name = "/models", .help = "browse models" },
        .{ .name = "/rename", .help = "rename session" },
        .{ .name = "/model", .help = "choose model" },
    };
    try std.testing.expectEqual(@as(usize, 2), count(&specs, "/model"));
    try std.testing.expectEqualStrings("/model", nth(&specs, "/model", 0).?.name);
    try std.testing.expectEqualStrings("choose model", nth(&specs, "/model", 0).?.help);
    try std.testing.expectEqualStrings("/models", nth(&specs, "/model", 1).?.name);

    try std.testing.expectEqualStrings("/models", nth(&specs, "/mo", 0).?.name);
    try std.testing.expectEqualStrings("/model", nth(&specs, "/mo", 1).?.name);

    try std.testing.expectEqual(@as(usize, 1), count(&specs, "/name"));
    try std.testing.expectEqualStrings("/rename", nth(&specs, "/name", 0).?.name);
    try std.testing.expectEqual(@as(usize, 0), count(&specs, "/missing"));
}

test "help is grouped and helpFor is exact" {
    const text = try helpText(std.testing.allocator, &builtin);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Session:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Account / model:") != null);
    const one = try helpFor(std.testing.allocator, &builtin, "compact");
    defer std.testing.allocator.free(one);
    try std.testing.expect(std.mem.indexOf(u8, one, "/compact") != null);
}

test "builtin help lists resume login web peers and reload everything" {
    const text = try helpText(std.testing.allocator, &builtin);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "/resume") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/reload") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "settings") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/login") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/web") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/browser") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/peers") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/clear") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/undo") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/init") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/rewind") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/fork") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "playbook") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/credits") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/balance") == null);
}

test "image paste are not slash commands" {
    try std.testing.expect(Name.fromToken("/image") == null);
    try std.testing.expect(Name.fromToken("/images") == null);
    try std.testing.expect(Name.fromToken("/img") == null);
    try std.testing.expect(Name.fromToken("/paste") == null);
    const text = try helpText(std.testing.allocator, &builtin);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "/image") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/paste") == null);
}

test "builtin names are unique" {
    for (builtin, 0..) |a, i| {
        for (builtin[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}
