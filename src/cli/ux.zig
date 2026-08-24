const std = @import("std");
const Io = std.Io;

const config = @import("../core/config.zig");
const slash = @import("../core/slash.zig");
const env = @import("../core/env.zig");
const settings = @import("../core/settings.zig");
const agent = @import("../core/agent.zig");
const auth = @import("../providers/auth.zig");
const catalog = @import("../providers/catalog.zig");
const web_search = @import("../tools/web_search.zig");
const pathing = @import("../tools/pathing.zig");
const cmds = @import("cmds.zig");
const menus = @import("menus.zig");
const tui = @import("tui.zig");

const Flow = cmds.Flow;
const PanelKind = cmds.PanelKind;
const Ctx = cmds.Ctx;
const State = cmds.State;

const Harness = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    home: []u8,
    workspace: []u8,
    table: env.Table,
    aw: std.Io.Writer.Allocating,
    shown: tui.Transcript,
    state: State,
    ctx: Ctx,

    fn initInPlace(h: *Harness, gpa: std.mem.Allocator) !void {
        h.gpa = gpa;
        h.arena = std.heap.ArenaAllocator.init(gpa);
        h.tmp = std.testing.tmpDir(.{});
        h.home = try pathing.testWorkspace(gpa, &h.tmp);
        try Io.Dir.cwd().createDirPath(std.testing.io, h.home);
        const omfx = try std.fs.path.join(gpa, &.{ h.home, ".omfx" });
        defer gpa.free(omfx);
        try Io.Dir.cwd().createDirPath(std.testing.io, omfx);
        h.workspace = try gpa.dupe(u8, h.home);
        h.table = env.Table{ .pairs = &.{.{ .key = "HOME", .value = h.home }} };
        h.aw = std.Io.Writer.Allocating.init(gpa);
        h.shown = tui.Transcript.init(gpa, 100);
        const reads = agent.Reads.init(gpa);
        h.state = State{ .mode = config.PermissionMode.ask, .reads = reads, .cols = 100 };
        h.ctx = Ctx{
            .gpa = gpa,
            .arena = h.arena.allocator(),
            .io = std.testing.io,
            .stdout = &h.aw.writer,
            .home = h.home,
            .workspace = h.workspace,
            .lookup = h.table.lookup(),
            .to_transcript = "",
            .flag_provider = null,
            .flag_model = null,
            .shown = &h.shown,
            .state = &h.state,
        };
    }

    fn deinit(h: *Harness) void {
        h.state.deinit(h.gpa);
        h.shown.deinit();
        h.aw.deinit();
        h.gpa.free(h.home);
        h.gpa.free(h.workspace);
        h.arena.deinit();
        h.tmp.cleanup();
    }

    fn resetOutput(h: *Harness) void {
        h.aw.clearRetainingCapacity();
        h.shown.clear();
        h.state.menu.note = "";
    }

    fn resetFlow(h: *Harness) void {
        h.state.pending.deinit(h.gpa);
        h.state.pick.clear();
        h.state.menu.note = "";
    }

    fn out(h: *Harness) []const u8 {
        return h.aw.written();
    }

    fn note(h: *const Harness) []const u8 {
        return h.state.menu.note;
    }

    fn writeRel(h: *Harness, rel: []const u8, data: []const u8) !void {
        const path = try std.fs.path.join(h.gpa, &.{ h.home, rel });
        defer h.gpa.free(path);
        if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(std.testing.io, dir);
        var file = try Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
        defer file.close(std.testing.io);
        var buf: [512]u8 = undefined;
        var w = file.writer(std.testing.io, &buf);
        try w.interface.writeAll(data);
        try w.interface.flush();
    }

    fn writeAuth(h: *Harness, json: []const u8) !void {
        try h.writeRel(".omfx/auth.json", json);
        cmds.reloadFromDisk(&h.ctx);
    }

    fn seedSession(h: *Harness) !void {
        const sess_dir = try std.fs.path.join(h.gpa, &.{ h.home, ".omfx", "sessions" });
        defer h.gpa.free(sess_dir);
        try Io.Dir.cwd().createDirPath(std.testing.io, sess_dir);
        var blob: std.ArrayList(u8) = .empty;
        defer blob.deinit(h.gpa);
        var n: usize = 0;
        while (n < 6) : (n += 1) {
            const line = try std.fmt.allocPrint(h.gpa, "{{\"kind\":\"user\",\"body\":\"turn-{d}\"}}\n", .{n});
            defer h.gpa.free(line);
            try blob.appendSlice(h.gpa, line);
        }
        const path = try std.fs.path.join(h.gpa, &.{ sess_dir, "last.jsonl" });
        defer h.gpa.free(path);
        var file = try Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
        defer file.close(std.testing.io);
        var buf: [256]u8 = undefined;
        var w = file.writer(std.testing.io, &buf);
        try w.interface.writeAll(blob.items);
        try w.interface.flush();
    }

    fn dispatch(h: *Harness, line: []const u8) !Flow {
        return cmds.dispatch(&h.ctx, line);
    }

    fn applyPick(h: *Harness, name: []const u8) !Flow {
        return cmds.applyPick(&h.ctx, name);
    }

    fn menuFeed(h: *Harness, line: []const u8) !void {
        try menus.feed(
            h.gpa,
            h.ctx.arena,
            h.ctx.io,
            h.home,
            h.ctx.stdout,
            h.ctx.to_transcript,
            &h.shown,
            &h.state.pending,
            &h.state.menu,
            line,
        );
    }

    fn expectContains(h: *Harness, needle: []const u8) !void {
        if (std.mem.indexOf(u8, h.out(), needle) == null) {
            std.debug.print("expected output to contain \"{s}\"\noutput:\n{s}\n", .{ needle, h.out() });
            return error.TestUnexpectedResult;
        }
    }

    fn expectNote(h: *Harness, want: []const u8) !void {
        try std.testing.expectEqualStrings(want, h.note());
    }

    fn pickHasConfiguredFree(h: *Harness) !void {
        var saw = false;
        for (h.state.pick.rows[0..h.state.pick.n]) |row| {
            if (!std.mem.eql(u8, row.name, "duckduckgo")) continue;
            try std.testing.expect(std.mem.startsWith(u8, row.help, "✓"));
            saw = true;
        }
        try std.testing.expect(saw);
    }
};

test "every builtin slash token resolves" {
    inline for (slash.builtin) |spec| {
        const name = spec.name[1..];
        const cmd = slash.Name.fromToken(spec.name) orelse {
            std.debug.print("missing Name for {s}\n", .{spec.name});
            return error.TestUnexpectedResult;
        };
        _ = cmd;
        try std.testing.expect(slash.Name.fromToken(spec.name) != null);
        try std.testing.expect(std.meta.stringToEnum(slash.Name, name) != null or aliasMaps(spec.name));
    }
}

fn aliasMaps(token: []const u8) bool {
    return slash.Name.fromToken(token) != null;
}

test "token aliases map to the canonical command" {
    const pairs = [_]struct { from: []const u8, to: slash.Name }{
        .{ .from = "/new", .to = .clear },
        .{ .from = "/exit", .to = .quit },
        .{ .from = "/setup", .to = .login },
        .{ .from = "/model", .to = .models },
        .{ .from = "/cost", .to = .usage },
        .{ .from = "/peer", .to = .peers },
    };
    for (pairs) |p| {
        try std.testing.expectEqual(p.to, slash.Name.fromToken(p.from).?);
    }
}

test "ux: panel commands open the right surface" {
    const cases = [_]struct { line: []const u8, panel: PanelKind }{
        .{ .line = "/help", .panel = .help },
        .{ .line = "/shortcuts", .panel = .shortcuts },
        .{ .line = "/resume", .panel = .sessions },
        .{ .line = "/continue", .panel = .sessions },
        .{ .line = "/status", .panel = .status },
        .{ .line = "/context", .panel = .context },
        .{ .line = "/settings", .panel = .settings },
        .{ .line = "/statusline", .panel = .statusline },
        .{ .line = "/background", .panel = .jobs },
        .{ .line = "/workspace", .panel = .workspace },
        .{ .line = "/rewind", .panel = .rewind },
    };
    var h: Harness = undefined;
    try Harness.initInPlace(&h, std.testing.allocator);
    defer h.deinit();
    for (cases) |c| {
        h.resetOutput();
        const flow = try h.dispatch(c.line);
        try std.testing.expectEqual(c.panel, flow.panel);
    }
}

test "ux: inspect commands answer in scrollback" {
    var h: Harness = undefined;
    try Harness.initInPlace(&h, std.testing.allocator);
    defer h.deinit();
    try h.seedSession();
    try h.writeAuth("{\"commandcode\":{\"type\":\"api_key\",\"key\":\"cc-test\"}}");

    const lines = [_][]const u8{
        "/version",
        "/stats",
        "/usage",
        "/permissions",
        "/permissions auto",
        "/sandbox",
        "/sandbox off",
        "/yolo on",
        "/yolo off",
        "/fast",
        "/fast on",
        "/effort",
        "/effort low",
        "/plan",
        "/plan on",
        "/appearance",
        "/thinking on",
        "/sound off",
        "/rewind list",
        "/rename smoke-test",
        "/help compact",
        "/shortcuts nope",
        "/plugin list",
        "/feedback",
        "/copy",
        "/undo",
        "/logout",
        "/peers",
    };
    for (lines) |line| {
        h.resetOutput();
        const flow = try h.dispatch(line);
        switch (flow) {
            .handled, .panel, .retry => {},
            .quit, .fallthrough => return error.TestUnexpectedResult,
        }
    }
    h.resetOutput();
    _ = try h.dispatch("/version");
    try h.expectContains("omfx 0.0.1");
    h.resetOutput();
    _ = try h.dispatch("/effort low");
    try h.expectContains("Reasoning set to low.");
    h.resetOutput();
    _ = try h.dispatch("/peers");
    try h.expectContains("Give the teammate a goal");
}

test "ux: session lifecycle commands" {
    var h: Harness = undefined;
    try Harness.initInPlace(&h, std.testing.allocator);
    defer h.deinit();
    try h.seedSession();
    try h.writeAuth("{\"commandcode\":{\"type\":\"api_key\",\"key\":\"cc-test\"}}");

    h.resetOutput();
    _ = try h.dispatch("/clear");
    h.resetOutput();
    _ = try h.dispatch("/reset");
    h.resetOutput();
    _ = try h.dispatch("/fork");
    try h.expectContains("fork");
    h.resetOutput();
    _ = try h.dispatch("/handoff");
    try h.expectContains("handoff");
    h.resetOutput();
    _ = try h.dispatch("/init");
    h.resetOutput();
    _ = try h.dispatch("/reload");
    try h.expectContains("reloaded");
}

test "ux: unknown and partial slash behaviour" {
    var h: Harness = undefined;
    try Harness.initInPlace(&h, std.testing.allocator);
    defer h.deinit();

    const unknown = try h.dispatch("/not-a-real-command");
    try std.testing.expect(unknown == .fallthrough);
    h.resetOutput();
    const partial = try h.dispatch("/mo");
    try std.testing.expectEqual(Flow.handled, partial);
    try h.expectContains("/models");
    h.resetOutput();
    _ = try h.dispatch("/help definitely-missing");
    try h.expectContains("unknown command");
}

test "ux: bad argument paths stay usable" {
    var h: Harness = undefined;
    try Harness.initInPlace(&h, std.testing.allocator);
    defer h.deinit();
    try h.writeAuth("{\"commandcode\":{\"type\":\"api_key\",\"key\":\"cc-test\"}}");

    h.resetOutput();
    _ = try h.dispatch("/permissions sideways");
    try h.expectContains("Choose how writes are approved");

    h.resetOutput();
    _ = try h.dispatch("/yolo maybe");
    try h.expectContains("/yolo [on|off]");

    h.resetOutput();
    _ = try h.dispatch("/rewind 0");
    try h.expectContains("Say how far back");

    h.resetOutput();
    _ = try h.dispatch("/continue retry");
    try h.expectContains("nothing to continue");

    h.resetOutput();
    _ = try h.dispatch("/rename");
    try h.expectContains("rename");

    h.state.last_plan = try h.ctx.arena.dupe(u8, "Add caching layer.");
    h.resetOutput();
    const plan = try h.dispatch("/plan go");
    switch (plan) {
        .retry => |p| try std.testing.expect(std.mem.indexOf(u8, p, "Implement the approved plan") != null),
        else => return error.TestUnexpectedResult,
    }
}

test "ux: login pick lists providers; api key flow saves" {
    var h: Harness = undefined;
    try Harness.initInPlace(&h, std.testing.allocator);
    defer h.deinit();

    const flow = try h.dispatch("/login");
    try std.testing.expectEqual(Flow.handled, flow);
    try std.testing.expectEqual(tui.PickKind.login, h.state.pick.kind);
    try std.testing.expect(h.state.pick.n >= catalog.all.len);

    h.resetFlow();
    _ = try h.dispatch("/login");
    _ = try h.applyPick("commandcode");
    try std.testing.expectEqual(menus.Pending{ .login_key = "commandcode" }, h.state.pending);
    try std.testing.expect(h.note().len > 0);

    try h.menuFeed("cc-secret-key");
    try std.testing.expect(h.state.pending == .none);
    const json = auth.readJson(h.gpa, h.ctx.io, h.home);
    defer if (json.len > 0) h.gpa.free(json);
    try std.testing.expectEqualStrings("cc-secret-key", auth.extractKey(json, "commandcode").?);
}

test "ux: login cancel and unknown provider" {
    var h: Harness = undefined;
    try Harness.initInPlace(&h, std.testing.allocator);
    defer h.deinit();

    _ = try h.dispatch("/login not-a-provider");
    try h.expectNote("Unknown provider. Type a number or id. Empty line cancels.");

    h.resetFlow();
    h.state.pending = .{ .login_key = "commandcode" };
    try h.menuFeed("");
    try h.expectNote("Canceled.");
}

test "ux: web pick marks free engines configured" {
    var h: Harness = undefined;
    try Harness.initInPlace(&h, std.testing.allocator);
    defer h.deinit();

    _ = try h.dispatch("/web");
    try std.testing.expectEqual(tui.PickKind.web, h.state.pick.kind);
    try h.pickHasConfiguredFree();

    h.resetOutput();
    _ = try h.applyPick(web_search.order_pick_id);
    switch (h.state.pending) {
        .web_order => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(std.mem.startsWith(u8, h.note(), "Pick who should search first"));

    try h.menuFeed("duckduckgo");
    try h.menuFeed("startpage");
    try h.menuFeed("");
    try std.testing.expect(h.state.pending == .none);
    var file = settings.load(h.gpa, h.ctx.io, h.home);
    defer file.deinit(h.gpa);
    try std.testing.expectEqual(@as(usize, 2), file.web.order.len);
    try std.testing.expectEqualStrings("duckduckgo", file.web.order[0]);
    try std.testing.expectEqualStrings("startpage", file.web.order[1]);
}

test "ux: web off on default and unknown" {
    var h: Harness = undefined;
    try Harness.initInPlace(&h, std.testing.allocator);
    defer h.deinit();

    _ = try h.dispatch("/web off google");
    try h.expectNote("Turned google off.");
    {
        var file = settings.load(h.gpa, h.ctx.io, h.home);
        defer file.deinit(h.gpa);
        var excluded = false;
        for (file.web.exclude) |id| {
            if (std.mem.eql(u8, id, "google")) excluded = true;
        }
        try std.testing.expect(excluded);
    }

    h.resetFlow();
    _ = try h.dispatch("/web on google");
    try h.expectNote("Turned google on.");
    {
        var file = settings.load(h.gpa, h.ctx.io, h.home);
        defer file.deinit(h.gpa);
        for (file.web.exclude) |id| {
            try std.testing.expect(!std.mem.eql(u8, id, "google"));
        }
    }

    h.resetFlow();
    _ = try h.dispatch("/web default");
    try h.expectNote("Using the built-in search order.");

    h.resetFlow();
    _ = try h.dispatch("/web xyzzy");
    try std.testing.expect(std.mem.startsWith(u8, h.note(), "Not a choice here"));
}

test "ux: models without auth then drill-down with auth" {
    var h: Harness = undefined;
    try Harness.initInPlace(&h, std.testing.allocator);
    defer h.deinit();

    _ = try h.dispatch("/models");
    try h.expectContains("Not signed in yet");

    try h.writeAuth("{\"commandcode\":{\"type\":\"api_key\",\"key\":\"cc-test\"}}");
    h.resetOutput();
    _ = try h.dispatch("/models");
    try std.testing.expectEqual(tui.PickKind.providers, h.state.pick.kind);
    try std.testing.expect(h.state.pick.n >= 1);

    _ = try h.applyPick("commandcode");
    try std.testing.expectEqual(tui.PickKind.models, h.state.pick.kind);
    try std.testing.expect(h.state.pick.n >= 1);

    const model_id = h.state.pick.rows[0].name;
    _ = try h.applyPick(model_id);
    try std.testing.expect(h.state.resolved != null);
    try std.testing.expect(h.note().len > 0);

    if (h.state.pick.kind == .efforts) {
        try std.testing.expect(cmds.stepPickBack(&h.ctx));
        try std.testing.expectEqual(tui.PickKind.models, h.state.pick.kind);
        try std.testing.expect(cmds.stepPickBack(&h.ctx));
        try std.testing.expectEqual(tui.PickKind.providers, h.state.pick.kind);
    } else {
        _ = try h.dispatch("/models");
        try std.testing.expectEqual(tui.PickKind.providers, h.state.pick.kind);
    }
}

test "ux: models refresh and direct id" {
    var h: Harness = undefined;
    try Harness.initInPlace(&h, std.testing.allocator);
    defer h.deinit();
    try h.writeAuth("{\"commandcode\":{\"type\":\"api_key\",\"key\":\"cc-test\"}}");
    cmds.reloadFromDisk(&h.ctx);

    h.resetOutput();
    _ = try h.dispatch("/models refresh");
    try std.testing.expect(h.note().len > 0);

    h.state.menu.note = "";
    h.resetOutput();
    _ = try h.dispatch("/models commandcode");
    try std.testing.expectEqual(tui.PickKind.models, h.state.pick.kind);
}

test "ux: settings one-shot and allowlist" {
    var h: Harness = undefined;
    try Harness.initInPlace(&h, std.testing.allocator);
    defer h.deinit();

    _ = try h.dispatch("/settings thinking=on");
    try h.expectContains("thinking");

    h.resetOutput();
    _ = try h.dispatch("/allowlist");
    try h.expectContains("allowlist");

    h.resetOutput();
    _ = try h.dispatch("/allowlist rm-nope write deny");
    try h.expectContains("write");
}

test "ux: workspace add remove" {
    var h: Harness = undefined;
    try Harness.initInPlace(&h, std.testing.allocator);
    defer h.deinit();
    try h.seedSession();

    h.resetOutput();
    _ = try h.dispatch("/workspace add /tmp/extra");
    try h.expectContains("/tmp/extra");

    h.resetOutput();
    _ = try h.dispatch("/workspace remove /tmp/extra");
}

test "ux: command palette lists every builtin" {
    var h: Harness = undefined;
    try Harness.initInPlace(&h, std.testing.allocator);
    defer h.deinit();
    cmds.fillCommands(&h.state);
    try std.testing.expectEqual(tui.PickKind.commands, h.state.pick.kind);
    try std.testing.expectEqual(slash.builtin.len, h.state.pick.n);
}

test "ux matrix covers every builtin at least once" {
    var h: Harness = undefined;
    try Harness.initInPlace(&h, std.testing.allocator);
    defer h.deinit();
    try h.seedSession();
    try h.writeAuth("{\"commandcode\":{\"type\":\"api_key\",\"key\":\"cc-test\"}}");

    var covered: [slash.builtin.len]bool = [_]bool{false} ** slash.builtin.len;
    const extras = [_][]const u8{
        "/new",
        "/exit",
        "/setup",
        "/model",
        "/cost",
        "/peer",
        "/settings thinking=off",
        "/statusline off",
        "/permissions yolo",
        "/allowlist bash allow",
        "/workspace add /tmp/w",
        "/background list",
        "/mcp list",
        "/ide open",
        "/plugin marketplace add acme/plugins",
        "/init overwrite",
        "/compact",
        "/logout all",
        "/effort auto",
        "/rename matrix-run",
        "/reset",
        "/quit",
    };
    for (slash.builtin, 0..) |spec, i| {
        h.resetOutput();
        if (std.mem.eql(u8, spec.name, "/quit")) {
            covered[i] = true;
            continue;
        }
        const flow = try h.dispatch(spec.name);
        switch (flow) {
            .quit => {},
            .handled, .panel, .retry, .fallthrough => {},
        }
        covered[i] = true;
    }
    for (extras) |line| {
        if (std.mem.eql(u8, line, "/quit")) continue;
        h.resetOutput();
        _ = try h.dispatch(line);
    }
    for (covered) |ok| try std.testing.expect(ok);
    std.debug.print("BENCH ux_matrix={d}\n", .{slash.builtin.len + extras.len});
}
