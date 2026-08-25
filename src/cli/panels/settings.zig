const std = @import("std");
const Io = std.Io;

const panel_mod = @import("../panel.zig");
const statusline_mod = @import("../statusline.zig");
const tty = @import("../tty.zig");
const tui = @import("../tui.zig");
const cmds = @import("../cmds.zig");
const settings = @import("../../core/settings.zig");
const headless = @import("../../core/headless.zig");

const session_mod = @import("../repl/session.zig");
const Session = session_mod.Session;

const known_editors = [_][]const u8{
    "code", "cursor", "zed", "subl",  "windsurf",
    "hx",   "nvim",   "vim", "emacs", "nano",
    "vi",
};

pub const max_editors: usize = known_editors.len + 1;

pub fn detectEditors(sess: *Session, out: [][]const u8) usize {
    out[0] = "auto";
    var n: usize = 1;
    const path = sess.lookup.get("PATH") orelse return n;
    for (known_editors) |name| {
        if (n == out.len) break;
        if (onPath(sess, path, name)) {
            out[n] = name;
            n += 1;
        }
    }
    return n;
}

fn onPath(sess: *Session, path: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        const st = Io.Dir.cwd().statFile(sess.io, full, .{}) catch continue;
        if (st.kind == .file) return true;
    }
    return false;
}

pub fn settingsPanel(sess: *Session) panel_mod.Panel {
    var cfg = settings.load(sess.gpa, sess.io, sess.home);
    defer cfg.deinit(sess.gpa);
    var p = panel_mod.Panel{ .title = "Settings" };
    p.add(.{
        .key = "sound",
        .label = "Sound",
        .kind = .toggle,
        .value = if (sess.state.sound) "on" else "off",
        .help = "chime on launch and when a turn finishes",
    });
    p.add(.{
        .key = "thinking",
        .label = "Show thinking",
        .kind = .toggle,
        .value = if (sess.state.thinking) "on" else "off",
        .help = "show the assistant's thinking while it works",
    });
    p.add(.{
        .key = "telemetry",
        .label = "Telemetry",
        .kind = .toggle,
        .value = if (sess.state.telemetry) "on" else "off",
        .help = "only says which app is talking; off keeps you anonymous",
    });
    p.add(.{
        .key = "peer",
        .label = "Auto teammates",
        .kind = .toggle,
        .value = if (settings.peerAutoOn(cfg)) "on" else "off",
        .help = "lets the assistant ask a teammate on its own; /peers still works anytime",
    });
    p.add(.{
        .key = "statusline",
        .label = "Status line",
        .kind = .toggle,
        .value = if (sess.state.statusline) "on" else "off",
        .help = "model and mode under the composer",
    });
    p.add(.{
        .key = "mode",
        .label = "Permissions",
        .kind = .{ .choice = &.{ "normal", "plan", "yolo" } },
        .value = cmds.footerPerm(&sess.state),
        .help = "normal prompts, plan is read-only, yolo allows writes",
    });
    p.add(.{
        .key = "sandbox",
        .label = "Sandbox",
        .kind = .{ .choice = &.{ "on", "off" } },
        .value = if (settings.sandboxOff(cfg)) "off" else "on",
        .help = "OS sandbox on bash, network denied",
    });
    var editors: [max_editors][]const u8 = undefined;
    const found = detectEditors(sess, &editors);
    p.add(.{
        .key = "editor",
        .label = "Editor",
        .kind = .{ .choice = editors[0..found] },
        .value = if (cfg.editor.len == 0) editors[0] else sess.arena.dupe(u8, cfg.editor) catch editors[0],
        .help = "ctrl-g opens this; auto follows $VISUAL then $EDITOR",
    });
    p.add(.{
        .key = "bash_timeout",
        .label = "Command timeout",
        .kind = .{ .number = .{ .min = 0, .max = 3600, .step = 30 } },
        .value = std.fmt.allocPrint(sess.arena, "{d}", .{cfg.bash_timeout}) catch "0",
        .help = "seconds a bash command may run; 0 is the default 120",
    });
    p.add(.{
        .key = "keep_sessions",
        .label = "Keep sessions",
        .kind = .{ .number = .{ .min = 0, .max = 1000, .step = 10 } },
        .value = std.fmt.allocPrint(sess.arena, "{d}", .{cfg.keep_sessions}) catch "0",
        .help = "saved sessions kept on disk; 0 keeps every one",
    });
    p.add(.{
        .key = "max_peer_depth",
        .label = "Peer depth",
        .kind = .{ .number = .{ .min = 0, .max = 8 } },
        .value = std.fmt.allocPrint(sess.arena, "{d}", .{cfg.max_peer_depth}) catch "1",
        .help = "how many levels of teammate a peer may spawn",
    });
    const path = settings.path(sess.arena, sess.home) catch "";
    p.add(.{ .key = "path", .label = "File", .kind = .info, .value = path });
    return p;
}

pub fn applyPanelField(sess: *Session, p: panel_mod.Panel, value: []const u8) void {
    const f = p.current() orelse return;
    var ctx = sess.cmdCtx();

    if (std.mem.startsWith(u8, f.key, "field:")) {
        var cfg = settings.load(sess.gpa, sess.io, sess.home);
        defer cfg.deinit(sess.gpa);
        var sl = statusline_mod.parse(cfg.statusline_place, cfg.statusline_fields);
        const name = f.key["field:".len..];
        if (statusline_mod.Field.fromSlice(name)) |fld| {
            if (std.mem.eql(u8, value, "on")) sl.add(fld) else sl.remove(fld);
        }
        var buf: [160]u8 = undefined;
        const encoded = sl.encode(&buf);
        const line2 = std.fmt.allocPrint(sess.arena, "statusline_fields={s}", .{encoded}) catch return;
        _ = cmds.applySetting(&ctx, line2) catch {};
        const sel2 = p.sel;
        var next2 = statuslinePanel(sess);
        next2.sel = sel2;
        next2.elapsed_ms = panel_mod.open_ms;
        sess.panel = next2;
        return;
    }
    const is_statusline = std.mem.eql(u8, f.key, "statusline_place");
    const line = std.fmt.allocPrint(sess.arena, "{s}={s}", .{ f.key, value }) catch return;
    _ = cmds.applySetting(&ctx, line) catch {};
    const sel = p.sel;
    var next = if (is_statusline) statuslinePanel(sess) else settingsPanel(sess);
    next.sel = sel;
    next.elapsed_ms = panel_mod.open_ms;
    sess.panel = next;
}

pub fn togglePanelField(sess: *Session) void {
    const p = sess.panel orelse return;
    const f = p.current() orelse return;
    if (f.kind != .toggle) return;
    applyPanelField(sess, p, if (std.mem.eql(u8, f.value, "on")) "off" else "on");
}

pub fn stepPanelValue(sess: *Session, forward: bool) void {
    const p = sess.panel orelse return;
    const f = p.current() orelse return;
    switch (f.kind) {
        .choice => |opts| {
            if (opts.len == 0) return;
            var at: usize = 0;
            for (opts, 0..) |o, i| {
                if (std.mem.eql(u8, o, f.value)) at = i;
            }
            const n: i32 = @intCast(opts.len);
            const next = @mod(@as(i32, @intCast(at)) + (if (forward) @as(i32, 1) else -1) + n, n);
            applyPanelField(sess, p, opts[@intCast(next)]);
        },
        .number => |b| {
            const cur = std.fmt.parseInt(u32, f.value, 10) catch b.min;
            const stepped: u32 = if (forward)
                @min(b.max, cur +| b.step)
            else if (cur <= b.step) b.min else @max(b.min, cur - b.step);
            const text = std.fmt.allocPrint(sess.arena, "{d}", .{stepped}) catch return;
            applyPanelField(sess, p, text);
        },
        .toggle => togglePanelField(sess),
        .text, .info, .pick, .heading, .entry => {},
    }
}

pub fn editDraftExternally(sess: *Session) !void {
    if (headless.guiBlocked()) return;
    const editor = if (sess.state.editor.len != 0)
        sess.state.editor
    else
        sess.lookup.get("VISUAL") orelse sess.lookup.get("EDITOR") orelse "vi";
    const path = try std.fmt.allocPrint(sess.arena, "{s}/.omfx/draft.txt", .{sess.workspace});
    const dir = try std.fmt.allocPrint(sess.arena, "{s}/.omfx", .{sess.workspace});
    Io.Dir.cwd().createDirPath(sess.io, dir) catch return;
    {
        var f = Io.Dir.cwd().createFile(sess.io, path, .{ .truncate = true }) catch return;
        defer f.close(sess.io);
        var buf: [512]u8 = undefined;
        var w = f.writer(sess.io, &buf);
        w.interface.writeAll(sess.draft.items()) catch {};
        w.interface.flush() catch {};
    }

    sess.stdout.writeAll(tui.restoreSequence()) catch {};
    sess.stdout.flush() catch {};
    tty.restore();

    var child = std.process.spawn(sess.io, .{
        .argv = &.{ editor, path },
        .cwd = .{ .path = sess.workspace },
    }) catch {
        _ = tty.Raw.enter();
        return;
    };
    _ = child.wait(sess.io) catch {};

    _ = tty.Raw.enter();
    sess.stdout.writeAll(tui.enter_alt) catch {};
    sess.stdout.flush() catch {};

    const body = Io.Dir.cwd().readFileAlloc(sess.io, path, sess.arena, .limited(256 * 1024)) catch return;
    try sess.draft.replace(sess.gpa, std.mem.trimEnd(u8, body, "\n\r"));
    Io.Dir.cwd().deleteFile(sess.io, path) catch {};
}

pub fn statuslinePanel(sess: *Session) panel_mod.Panel {
    var cfg = settings.load(sess.gpa, sess.io, sess.home);
    defer cfg.deinit(sess.gpa);
    const sl = statusline_mod.parse(cfg.statusline_place, cfg.statusline_fields);

    var p = panel_mod.Panel{ .title = "Status line" };
    p.add(.{
        .key = "statusline_place",
        .label = "Show in",
        .kind = .{ .choice = &.{ "footer", "header", "both" } },
        .value = sl.place.asSlice(),
        .help = "footer sits by the composer, header across the top",
    });
    p.add(.{ .key = "", .label = "Fields", .kind = .heading });
    inline for (comptime std.meta.tags(statusline_mod.Field)) |f| {
        p.add(.{
            .key = "field:" ++ @tagName(f),
            .label = @tagName(f),
            .kind = .toggle,
            .value = if (sl.has(f)) "on" else "off",
            .help = fieldHelp(f),
        });
    }
    p.selectFirst();
    return p;
}

pub fn fieldHelp(f: statusline_mod.Field) []const u8 {
    return switch (f) {
        .model => "the model answering this turn",
        .mode => "normal, plan, or yolo",
        .workspace => "the directory omfx is rooted at",
        .branch => "current git branch, when the workspace is a repo",
        .tokens => "tokens spent in this session",
        .session => "session id, for /resume",
        .peers => "how many teammates are running",
        .jobs => "how many background commands are alive",
    };
}
