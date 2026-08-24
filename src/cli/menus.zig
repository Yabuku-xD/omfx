const std = @import("std");
const tui = @import("tui.zig");
const Io = std.Io;

const log = std.log.scoped(.menus);
const login = @import("../providers/login.zig");
const catalog = @import("../providers/catalog.zig");
const auth = @import("../providers/auth.zig");
const settings = @import("../core/settings.zig");
const web_search = @import("../tools/web_search.zig");
const chat = @import("chat.zig");

pub const Pending = union(enum) {
    none,
    login_pick,
    login_key: []const u8,
    login_pkce: login.PkceHold,
    web_home,
    web_key: []const u8,
    web_endpoint,

    pub fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .login_pkce => |hold| hold.deinit(allocator),
            else => {},
        }
        self.* = .none;
    }
};

/// What a menu hands back to the caller that owns the screen.
///
/// `cols` comes in because a transcript row has to be styled at the width it
/// will be drawn at, and `note` goes out because the last line of a finished
/// flow is a status blip, not conversation.
pub const Out = struct {
    cols: u16,
    /// A one-line confirmation for the footer, which clears itself after a
    /// few seconds. Empty when the flow has nothing to confirm.
    note: []const u8 = "",
};

const Surface = struct {
    stdout: *Io.Writer,
    to_transcript: []const u8,
    shown: *tui.Transcript,
    arena: std.mem.Allocator,
    out: *Out,
};

/// A row that belongs in the transcript: the menu you are reading, the prompt
/// you are answering, the error you need to keep.
///
/// Styled the same way every other command answer is -- two-column gutter,
/// muted -- because nothing writes raw text at column zero.
fn emit(s: Surface, text: []const u8) !void {
    if (text.len == 0) return;
    const styled = chat.formatCommand(s.arena, s.out.cols, text) catch text;
    try s.stdout.writeAll(s.to_transcript);
    try s.stdout.writeAll(styled);
    if (styled.len == 0 or styled[styled.len - 1] != '\n') try s.stdout.writeAll("\n");
    try s.stdout.flush();
    try s.shown.append(styled);
}

/// The last line of a finished flow.
///
/// "Saved the key" answers a question you just asked and is stale a second
/// later, so it goes to the footer and leaves on its own rather than sitting
/// in the scrollback for the rest of the session. Errors are not settled --
/// those you need to still be there when you look back.
fn settle(s: Surface, text: []const u8) !void {
    s.out.note = std.mem.trimEnd(u8, text, "\n");
}

fn readAuth(allocator: std.mem.Allocator, io: Io, home: []const u8) []const u8 {
    return auth.readJson(allocator, io, home);
}

fn emitLoginMenu(allocator: std.mem.Allocator, io: Io, home: []const u8, s: Surface) !void {
    const json = readAuth(allocator, io, home);
    defer if (json.len > 0) allocator.free(json);
    const menu = try login.formatMenu(s.arena, json);
    try emit(s, menu);
}

fn emitWebMenu(allocator: std.mem.Allocator, io: Io, home: []const u8, s: Surface) !void {
    const json = readAuth(allocator, io, home);
    defer if (json.len > 0) allocator.free(json);
    var file = settings.load(allocator, io, home);
    defer file.deinit(allocator);
    const menu = try web_search.formatMenu(s.arena, json, file.web);
    try emit(s, menu);
}

fn persistWeb(
    allocator: std.mem.Allocator,
    io: Io,
    home: []const u8,
    order: []const []const u8,
    exclude: []const []const u8,
    endpoint: []const u8,
) !void {
    try settings.save(allocator, io, home, .{
        .order = order,
        .exclude = exclude,
        .searxng_endpoint = endpoint,
    });
}

fn rememberLogin(allocator: std.mem.Allocator, io: Io, home: []const u8, spec: catalog.Spec) void {
    settings.rememberProvider(allocator, io, home, catalog.storeId(spec), spec.model) catch |err| {
        log.warn("persist last provider: {s}", .{@errorName(err)});
    };
}

pub fn startLogin(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    home: []const u8,
    stdout: *Io.Writer,
    to_transcript: []const u8,
    shown: *tui.Transcript,
    pending: *Pending,
    out: *Out,
    rest: []const u8,
) !void {
    pending.deinit(gpa);
    pending.* = .login_pick;
    const s = Surface{ .stdout = stdout, .to_transcript = to_transcript, .shown = shown, .arena = arena, .out = out };
    if (rest.len == 0) {
        try emitLoginMenu(gpa, io, home, s);
        return;
    }
    try feed(gpa, arena, io, home, stdout, to_transcript, shown, pending, out, rest);
}

pub fn startWeb(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    home: []const u8,
    stdout: *Io.Writer,
    to_transcript: []const u8,
    shown: *tui.Transcript,
    pending: *Pending,
    out: *Out,
    rest: []const u8,
) !void {
    pending.deinit(gpa);
    pending.* = .web_home;
    const s = Surface{ .stdout = stdout, .to_transcript = to_transcript, .shown = shown, .arena = arena, .out = out };
    if (rest.len == 0) {
        try emitWebMenu(gpa, io, home, s);
        return;
    }
    try feed(gpa, arena, io, home, stdout, to_transcript, shown, pending, out, rest);
}

pub fn cancel(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    stdout: *Io.Writer,
    to_transcript: []const u8,
    shown: *tui.Transcript,
    pending: *Pending,
    out: *Out,
) !void {
    pending.deinit(gpa);
    const s = Surface{ .stdout = stdout, .to_transcript = to_transcript, .shown = shown, .arena = arena, .out = out };
    try settle(s, "Canceled.");
}

pub fn feed(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    home: []const u8,
    stdout: *Io.Writer,
    to_transcript: []const u8,
    shown: *tui.Transcript,
    pending: *Pending,
    out: *Out,
    line: []const u8,
) !void {
    const s = Surface{ .stdout = stdout, .to_transcript = to_transcript, .shown = shown, .arena = arena, .out = out };
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) {
        try cancel(gpa, arena, stdout, to_transcript, shown, pending, out);
        return;
    }
    switch (pending.*) {
        .none => {},
        .login_pick => try feedLoginPick(gpa, io, home, s, pending, trimmed),
        .login_key => |id| try feedLoginKey(gpa, io, home, s, pending, id, trimmed),
        .login_pkce => try feedLoginPkce(gpa, io, home, s, pending, trimmed),
        .web_home => try feedWebHome(gpa, io, home, s, pending, trimmed),
        .web_key => |id| try feedWebKey(gpa, io, home, s, pending, id, trimmed),
        .web_endpoint => try feedWebEndpoint(gpa, io, home, s, pending, trimmed),
    }
}

fn feedLoginPick(
    gpa: std.mem.Allocator,
    io: Io,
    home: []const u8,
    s: Surface,
    pending: *Pending,
    line: []const u8,
) !void {
    const spec = login.pick(line) orelse {
        try emit(s, "Unknown provider. Type a number or id. Empty line cancels.\n");
        return;
    };
    switch (spec.login) {
        .api_key => {
            pending.* = .{ .login_key = spec.id };
            const msg = try std.fmt.allocPrint(s.arena, "Paste the {s} API key. Empty line cancels.\n", .{spec.name});
            try emit(s, msg);
        },
        .device => {
            pending.* = .none;
            try emit(s, "Open the URL and enter the code (also printed on stderr).\n");
            login.runDevice(gpa, io, home, s.stdout, spec) catch |err| {
                const msg = try std.fmt.allocPrint(s.arena, "Unable to log in ({s}). Try /login again.\n", .{@errorName(err)});
                try emit(s, msg);
                return;
            };
            rememberLogin(gpa, io, home, spec);
            try settle(s, "Saved. Type /login to review.");
        },
        .pkce => {
            const hold = login.beginPkce(gpa, io, spec) catch |err| {
                const msg = try std.fmt.allocPrint(s.arena, "Unable to log in ({s}). Try /login again.\n", .{@errorName(err)});
                try emit(s, msg);
                return;
            };
            pending.* = .{ .login_pkce = hold };
            const msg = try std.fmt.allocPrint(s.arena, "Open {s}\nComplete login, then paste the redirect URL or code. Empty line cancels.\n", .{hold.url});
            try emit(s, msg);
        },
    }
}

fn feedLoginKey(
    gpa: std.mem.Allocator,
    io: Io,
    home: []const u8,
    s: Surface,
    pending: *Pending,
    id: []const u8,
    key: []const u8,
) !void {
    const spec = catalog.byId(id) orelse {
        pending.* = .none;
        try emit(s, "Unknown provider. Type /login to pick again.\n");
        return;
    };
    const path = login.saveApiKey(gpa, io, home, catalog.storeId(spec), key) catch |err| {
        const msg = try std.fmt.allocPrint(s.arena, "Unable to save ({s}). Check ~/.omfx permissions.\n", .{@errorName(err)});
        try emit(s, msg);
        return;
    };
    defer gpa.free(path);
    pending.* = .none;
    rememberLogin(gpa, io, home, spec);
    const msg = try std.fmt.allocPrint(s.arena, "Saved the {s} key in {s}.", .{ catalog.storeId(spec), path });
    try settle(s, msg);
}

fn feedLoginPkce(
    gpa: std.mem.Allocator,
    io: Io,
    home: []const u8,
    s: Surface,
    pending: *Pending,
    line: []const u8,
) !void {
    const hold = pending.login_pkce;
    pending.* = .none;
    defer hold.deinit(gpa);
    login.finishPkce(gpa, io, home, s.stdout, hold, line) catch |err| {
        const msg = try std.fmt.allocPrint(s.arena, "Unable to log in ({s}). Try /login again.\n", .{@errorName(err)});
        try emit(s, msg);
        return;
    };
    if (catalog.byId(hold.id)) |spec| rememberLogin(gpa, io, home, spec);
    try settle(s, "Saved. Type /login to review.");
}

fn feedWebHome(
    gpa: std.mem.Allocator,
    io: Io,
    home: []const u8,
    s: Surface,
    pending: *Pending,
    line: []const u8,
) !void {
    switch (web_search.parseHome(line)) {
        .cancel => try cancel(gpa, s.arena, s.stdout, s.to_transcript, s.shown, pending, s.out),
        .unknown => try emit(s, "Not a choice here. Type a number or id, `order a,b,c`, `off id`, `on id`, `test <query>`, or an empty line to go back.\n"),
        .test_query => |q| {
            const out = web_search.searchFromHome(gpa, io, home, q) catch |err| {
                const msg = try std.fmt.allocPrint(s.arena, "The search did not run ({s}).\n", .{@errorName(err)});
                try emit(s, msg);
                return;
            };
            defer gpa.free(out);
            try emit(s, out);
            try emitWebMenu(gpa, io, home, s);
        },
        .order => |o| {
            var file = settings.load(gpa, io, home);
            defer file.deinit(gpa);
            persistWeb(gpa, io, home, o.ids[0..o.n], file.web.exclude, file.web.searxng_endpoint) catch |err| {
                const msg = try std.fmt.allocPrint(s.arena, "Nothing was saved ({s}).\n", .{@errorName(err)});
                try emit(s, msg);
                return;
            };
            try settle(s, "Saved the fallback order.");
            try emitWebMenu(gpa, io, home, s);
        },
        .off => |id| {
            var file = settings.load(gpa, io, home);
            defer file.deinit(gpa);
            var buf: [settings.max_ids][]const u8 = undefined;
            const n = web_search.addId(file.web.exclude, id, &buf);
            persistWeb(gpa, io, home, file.web.order, buf[0..n], file.web.searxng_endpoint) catch |err| {
                const msg = try std.fmt.allocPrint(s.arena, "Nothing was saved ({s}).\n", .{@errorName(err)});
                try emit(s, msg);
                return;
            };
            const msg = try std.fmt.allocPrint(s.arena, "Turned {s} off.", .{id});
            try settle(s, msg);
            try emitWebMenu(gpa, io, home, s);
        },
        .on => |id| {
            var file = settings.load(gpa, io, home);
            defer file.deinit(gpa);
            var buf: [settings.max_ids][]const u8 = undefined;
            const n = web_search.dropId(file.web.exclude, id, &buf);
            persistWeb(gpa, io, home, file.web.order, buf[0..n], file.web.searxng_endpoint) catch |err| {
                const msg = try std.fmt.allocPrint(s.arena, "Nothing was saved ({s}).\n", .{@errorName(err)});
                try emit(s, msg);
                return;
            };
            const msg = try std.fmt.allocPrint(s.arena, "Turned {s} on.", .{id});
            try settle(s, msg);
            try emitWebMenu(gpa, io, home, s);
        },
        .pick => |spec| try pickWeb(gpa, io, home, s, pending, spec),
    }
}

fn pickWeb(
    gpa: std.mem.Allocator,
    io: Io,
    home: []const u8,
    s: Surface,
    pending: *Pending,
    spec: web_search.Spec,
) !void {
    const json = readAuth(gpa, io, home);
    defer if (json.len > 0) gpa.free(json);
    var file = settings.load(gpa, io, home);
    defer file.deinit(gpa);
    const has_cred = web_search.credential(json, spec) != null;
    if (spec.kind == .endpoint and !web_search.isAvailable(spec, json, file.web, true)) {
        pending.* = .web_endpoint;
        try emit(s, "Paste the SearXNG URL (http://127.0.0.1:8888). Empty line cancels.\n");
        return;
    }
    if ((spec.kind == .api_key or spec.kind == .chat_login) and !has_cred and !spec.keyless_explicit) {
        pending.* = .{ .web_key = spec.id };
        const extra: []const u8 = if (spec.kind == .chat_login) " (or type /login first)" else "";
        const msg = try std.fmt.allocPrint(s.arena, "Paste the {s} API key{s}. Empty line cancels.\n", .{ spec.name, extra });
        try emit(s, msg);
        return;
    }
    var order_buf: [settings.max_ids][]const u8 = undefined;
    const n = web_search.prependOrder(file.web, spec.id, &order_buf);
    var exclude_buf: [settings.max_ids][]const u8 = undefined;
    const en = web_search.dropId(file.web.exclude, spec.id, &exclude_buf);
    persistWeb(gpa, io, home, order_buf[0..n], exclude_buf[0..en], file.web.searxng_endpoint) catch |err| {
        const msg = try std.fmt.allocPrint(s.arena, "Nothing was saved ({s}).\n", .{@errorName(err)});
        try emit(s, msg);
        return;
    };
    const msg = try std.fmt.allocPrint(s.arena, "Put {s} first in the fallback order.", .{spec.id});
    try settle(s, msg);
    try emitWebMenu(gpa, io, home, s);
}

fn feedWebKey(
    gpa: std.mem.Allocator,
    io: Io,
    home: []const u8,
    s: Surface,
    pending: *Pending,
    id: []const u8,
    key: []const u8,
) !void {
    var buf: [48]u8 = undefined;
    const store = web_search.storeKey(id, &buf);
    const path = login.saveApiKey(gpa, io, home, store, key) catch |err| {
        const msg = try std.fmt.allocPrint(s.arena, "Nothing was saved ({s}).\n", .{@errorName(err)});
        try emit(s, msg);
        return;
    };
    defer gpa.free(path);
    var file = settings.load(gpa, io, home);
    defer file.deinit(gpa);
    var order_buf: [settings.max_ids][]const u8 = undefined;
    const n = web_search.prependOrder(file.web, id, &order_buf);
    var exclude_buf: [settings.max_ids][]const u8 = undefined;
    const en = web_search.dropId(file.web.exclude, id, &exclude_buf);
    persistWeb(gpa, io, home, order_buf[0..n], exclude_buf[0..en], file.web.searxng_endpoint) catch |err| {
        log.warn("persist web: {s}", .{@errorName(err)});
    };
    pending.* = .web_home;
    const msg = try std.fmt.allocPrint(s.arena, "Saved {s} and put it first in the fallback order.", .{id});
    try settle(s, msg);
    try emitWebMenu(gpa, io, home, s);
}

fn feedWebEndpoint(
    gpa: std.mem.Allocator,
    io: Io,
    home: []const u8,
    s: Surface,
    pending: *Pending,
    url: []const u8,
) !void {
    var file = settings.load(gpa, io, home);
    defer file.deinit(gpa);
    var order_buf: [settings.max_ids][]const u8 = undefined;
    const n = web_search.prependOrder(file.web, "searxng", &order_buf);
    persistWeb(gpa, io, home, order_buf[0..n], file.web.exclude, url) catch |err| {
        const msg = try std.fmt.allocPrint(s.arena, "Nothing was saved ({s}).\n", .{@errorName(err)});
        try emit(s, msg);
        return;
    };
    pending.* = .web_home;
    try emit(s, "saved SearXNG endpoint and put it first\n");
    try emitWebMenu(gpa, io, home, s);
}

test "pending starts none" {
    var p: Pending = .none;
    p.deinit(std.testing.allocator);
    try std.testing.expect(p == .none);
}

test "menu rows are styled, never raw at column zero" {
    const a = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    var shown = tui.Transcript.init(a, 80);
    defer shown.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    var out = Out{ .cols = 80 };
    const s = Surface{ .stdout = &w, .to_transcript = "", .shown = &shown, .arena = scratch.allocator(), .out = &out };

    try emit(s, "Paste the Command Code API key. Empty line cancels.\n");
    const drawn = shown.bytes();
    try std.testing.expect(std.mem.startsWith(u8, drawn, "  "));
    try std.testing.expect(std.mem.indexOf(u8, drawn, "Paste the Command Code API key.") != null);
}

test "a finished step confirms in the footer, not the scrollback" {
    const a = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    var shown = tui.Transcript.init(a, 80);
    defer shown.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    var out = Out{ .cols = 80 };
    const s = Surface{ .stdout = &w, .to_transcript = "", .shown = &shown, .arena = scratch.allocator(), .out = &out };

    // "Saved the key" is stale a second later, so it must not become a
    // permanent transcript row.
    try settle(s, "Saved the commandcode key in /home/u/.omfx/auth.json.");
    try std.testing.expectEqualStrings("Saved the commandcode key in /home/u/.omfx/auth.json.", out.note);
    try std.testing.expectEqual(@as(usize, 0), shown.bytes().len);
}

test "an error stays in the transcript where it can still be read" {
    const a = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    var shown = tui.Transcript.init(a, 80);
    defer shown.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    var out = Out{ .cols = 80 };
    const s = Surface{ .stdout = &w, .to_transcript = "", .shown = &shown, .arena = scratch.allocator(), .out = &out };

    try emit(s, "Nothing was saved (AccessDenied).\n");
    try std.testing.expect(std.mem.indexOf(u8, shown.bytes(), "Nothing was saved") != null);
    try std.testing.expectEqual(@as(usize, 0), out.note.len);
}

test "every menu string reads as a sentence, not a field" {
    // The rule is repo-wide: nothing user-facing is `key=value` or a bare
    // lowercase fragment. Checked here because this file is where the last
    // raw rows lived.
    const sentences = [_][]const u8{
        "Saved. Type /login to review.",
        "Canceled.",
        "Not a choice here. Type a number or id, `order a,b,c`, `off id`, `on id`, `test <query>`, or an empty line to go back.",
    };
    for (sentences) |line| {
        try std.testing.expect(line.len > 0);
        // Opens with a capital and closes with punctuation.
        try std.testing.expect(line[0] >= 'A' and line[0] <= 'Z');
        const last = line[line.len - 1];
        try std.testing.expect(last == '.' or last == '?');
        try std.testing.expect(std.mem.indexOfScalar(u8, line, '=') == null);
    }
}
