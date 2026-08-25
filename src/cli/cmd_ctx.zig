const std = @import("std");
const Io = std.Io;

const log = std.log.scoped(.cmd_ctx);

const chat = @import("chat.zig");
const tui = @import("tui.zig");
const menus = @import("menus.zig");
const config = @import("../core/config.zig");
const env = @import("../core/env.zig");
const settings = @import("../core/settings.zig");
const agent = @import("../core/agent.zig");
const catalog = @import("../providers/catalog.zig");
const auth = @import("../providers/auth.zig");
const registry = @import("../providers/registry.zig");
const undo = @import("../tools/undo.zig");
const permissions = @import("../core/permissions.zig");

pub const Flow = union(enum) {
    handled,
    quit,
    fallthrough,
    retry: []const u8,
    /// The command is an editor, not output: the caller opens a full panel.
    /// Named rather than a bool so adding a second panel is one variant.
    panel: PanelKind,
};

pub const PanelKind = enum { settings, help, shortcuts, sessions, statusline, status, jobs, workspace, rewind, context, plan, files, peers };

pub const max_extra: usize = 8;
pub const max_jobs: usize = 8;
pub const max_marks: usize = 16;

comptime {
    if (max_extra == 0) @compileError("max_extra must hold at least one extra dir");
    if (max_jobs == 0) @compileError("max_jobs must hold at least one job");
    if (max_marks == 0) @compileError("max_marks must keep at least one rewind point");
}

/// The whole message, so the "already shown" check is one comparison.
pub const copy_note = "copied last reply\n";

pub const Mark = struct {
    preview: [40]u8 = [_]u8{0} ** 40,
    preview_len: usize = 0,
    lines: usize = 0,
    undo_n: usize = 0,

    /// Pointer, not value: a slice into a by-value `self` points at the
    /// parameter copy and dangles the moment the function returns.
    pub fn previewSlice(self: *const Mark) []const u8 {
        return self.preview[0..self.preview_len];
    }
};

pub const OnOff = enum {
    on,
    off,

    pub fn fromSlice(s: []const u8) ?OnOff {
        return std.meta.stringToEnum(OnOff, s);
    }

    pub fn asSlice(self: OnOff) []const u8 {
        return switch (self) {
            .on => "on",
            .off => "off",
        };
    }

    pub fn fromRest(rest: []const u8, current: bool) ?bool {
        if (rest.len == 0) return !current;
        return switch (fromSlice(rest) orelse return null) {
            .on => true,
            .off => false,
        };
    }
};

pub const BgAction = enum { list, kill };

pub const State = struct {
    mode: config.PermissionMode,
    effort: []const u8 = "",
    effort_prev: []const u8 = "",
    resolved: ?catalog.Resolved = null,
    reads: agent.Reads,
    pending: menus.Pending = .none,
    /// What the menu drew at, and the one-line confirmation it wants the
    /// footer to show. `cols` is refreshed with the rest of the layout.
    menu: menus.Out = .{ .cols = 80 },
    pick: tui.Pick = .{},
    /// The provider list last fetched, and who it belongs to.
    registry: registry.List = .{},
    registry_of: []const u8 = "",
    /// Terminal width, so a command answer wraps where the transcript does.
    cols: u16 = 80,
    /// Set by `/reload`: the session rebuilds its skill list on the next
    /// pass through the loop.
    skills_stale: bool = false,
    /// Editor for ctrl-g, when the user named one.
    editor: []const u8 = "",
    /// Graphical IDE for /ide open.
    ide: []const u8 = "",
    had_turn: bool = false,
    last_goal: []const u8 = "",
    last_prompt: []const u8 = "",
    last_tool: []const u8 = "",
    last_reply: []const u8 = "",
    interrupted: bool = false,
    session_title: []const u8 = "",
    model_override: ?[]const u8 = null,
    sound: bool = false,
    thinking: bool = false,
    telemetry: bool = false,
    statusline: bool = true,
    fast: bool = false,
    composer: []const u8 = "> ",
    extra: [max_extra][]const u8 = undefined,
    extra_n: usize = 0,
    plan: agent.Plan = .off,
    last_plan: []const u8 = "",
    marks: [max_marks]Mark = [_]Mark{.{}} ** max_marks,
    marks_n: usize = 0,
    fork_n: usize = 0,
    /// Ephemeral session rules (ask/deny only). Never enter the system prompt.
    session_rules: [max_session_rules]permissions.Rule = undefined,
    session_rule_n: usize = 0,
    session_pats: [max_session_rules][96]u8 = undefined,

    pub const max_session_rules: usize = 8;

    pub fn sessionRuleSlice(self: *const State) []const permissions.Rule {
        return self.session_rules[0..self.session_rule_n];
    }

    /// Session rules may only shrink privilege (ask|deny). Allow must be persistent.
    pub fn appendSessionRule(self: *State, pattern: []const u8, action: permissions.DslAction) error{Full, Expand}!void {
        if (action == .allow) return error.Expand;
        if (self.session_rule_n >= max_session_rules) return error.Full;
        const parsed = permissions.parsePattern(pattern);
        if (parsed.pattern.len == 0 or parsed.pattern.len > self.session_pats[0].len) return error.Full;
        const i = self.session_rule_n;
        @memcpy(self.session_pats[i][0..parsed.pattern.len], parsed.pattern);
        self.session_rules[i] = .{
            .pattern = self.session_pats[i][0..parsed.pattern.len],
            .action = action,
            .fallback = parsed.fallback,
        };
        self.session_rule_n += 1;
    }

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        self.pending.deinit(gpa);
        self.reads.deinit();
    }

    pub fn extraSlice(self: *const State) []const []const u8 {
        return self.extra[0..self.extra_n];
    }

    pub fn appendExtra(self: *State, dir: []const u8) error{Full}!void {
        if (self.extra_n >= max_extra) return error.Full;
        self.extra[self.extra_n] = dir;
        self.extra_n += 1;
    }

    pub fn removeExtra(self: *State, dir: []const u8) bool {
        var i: usize = 0;
        while (i < self.extra_n) : (i += 1) {
            if (!std.mem.eql(u8, self.extra[i], dir)) continue;
            var j = i;
            while (j + 1 < self.extra_n) : (j += 1) self.extra[j] = self.extra[j + 1];
            self.extra_n -= 1;
            return true;
        }
        return false;
    }

    pub fn pushMark(self: *State, preview: []const u8, lines: usize, undo_n: usize) void {
        if (self.marks_n == max_marks) {
            var i: usize = 0;
            while (i + 1 < max_marks) : (i += 1) self.marks[i] = self.marks[i + 1];
            self.marks_n -= 1;
        }
        var m = Mark{ .lines = lines, .undo_n = undo_n };
        const n = @min(preview.len, m.preview.len);
        @memcpy(m.preview[0..n], preview[0..n]);
        m.preview_len = n;
        self.marks[self.marks_n] = m;
        self.marks_n += 1;
    }

    pub fn rewindMarks(self: *State, n: usize) ?Mark {
        if (n == 0 or self.marks_n == 0) return null;
        const take = @min(n, self.marks_n);
        const idx = self.marks_n - take;
        const mark = self.marks[idx];
        self.marks_n = idx;
        return mark;
    }
};

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    stdout: *Io.Writer,
    home: []const u8,
    workspace: []const u8,
    lookup: env.Lookup,
    to_transcript: []const u8,
    flag_provider: ?[]const u8,
    flag_model: ?[]const u8,
    shown: *tui.Transcript,
    state: *State,
};
pub fn footerPerm(state: *const State) []const u8 {
    return switch (state.plan) {
        .on => "plan",
        .off => state.mode.asSlice(),
    };
}

pub fn cycleSurface(state: *State) []const u8 {
    const next = config.Surface.fromFlags(state.plan == .on, state.mode).cycle();
    state.mode = next.permission();
    state.plan = if (next.planning()) .on else .off;
    return next.hint();
}

pub fn persistChat(ctx: *Ctx) void {
    const provider = if (ctx.state.resolved) |r| r.spec.id else "";
    const model = if (ctx.state.resolved) |r| r.model else "";
    settings.setLastChat(ctx.gpa, ctx.io, ctx.home, provider, model, footerPerm(ctx.state)) catch |err| {
        log.warn("persist last chat: {s}", .{@errorName(err)});
    };
}

pub fn nowSecs(io: Io) i64 {
    return Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
}

pub fn refreshInto(ctx: *Ctx, force: bool) void {
    const r = ctx.state.resolved orelse return;
    ctx.state.resolved = auth.ensureResolved(
        ctx.gpa,
        ctx.arena,
        ctx.io,
        ctx.home,
        ctx.lookup,
        r,
        nowSecs(ctx.io),
        force,
    ) catch |err| {
        log.warn("oauth ensure: {s}", .{@errorName(err)});
        return;
    };
}

pub fn applySurface(state: *State, label: []const u8) void {
    if (label.len == 0) return;
    if (config.Surface.fromSlice(label)) |s| {
        state.mode = s.permission();
        state.plan = if (s.planning()) .on else .off;
        return;
    }
    state.plan = .off;
    if (config.PermissionMode.fromSlice(label)) |m| state.mode = m;
}

pub fn settle(ctx: *Ctx, text: []const u8) void {
    ctx.state.menu.note = std.mem.trimEnd(u8, text, "\n");
}

pub fn emit(ctx: *Ctx, text: []const u8) !void {
    if (text.len == 0) return;
    const styled = chat.formatCommand(ctx.arena, ctx.state.cols, text) catch text;
    try ctx.stdout.writeAll(ctx.to_transcript);
    try ctx.stdout.writeAll(styled);
    if (styled.len == 0 or styled[styled.len - 1] != '\n') try ctx.stdout.writeAll("\n");
    try ctx.stdout.flush();
    try ctx.shown.append(styled);
}

pub fn readAuth(arena: std.mem.Allocator, io: Io, home: []const u8) []const u8 {
    return auth.readJson(arena, io, home);
}
