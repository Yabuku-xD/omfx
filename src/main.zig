const std = @import("std");
const Io = std.Io;
const omfx = @import("omfx");

const log = std.log.scoped(.omfx);

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;
    const env = init.environ_map;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const parsed = omfx.cli.parseArgs(arena, args) catch |err| switch (err) {
        error.UnknownCommand => {
            const name = firstNonFlag(args);
            var msg_buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "unknown command '{s}'", .{name}) catch "unknown command";
            var fix_buf: [160]u8 = undefined;
            const fix = if (omfx.cli.closestCommand(name)) |hint|
                std.fmt.bufPrint(&fix_buf, "omfx {s}    (or omfx help)", .{hint}) catch "omfx help"
            else
                @as([]const u8, "omfx help");
            die(stderr, wantsJson(args), omfx.cli.exit_usage, .{
                .code = "UNKNOWN_COMMAND",
                .message = msg,
                .fix = fix,
            });
        },
        error.UnknownFlag => {
            const flag = firstUnknownFlag(args);
            var msg_buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "unknown flag '{s}'", .{flag}) catch "unknown flag";
            die(stderr, wantsJson(args), omfx.cli.exit_usage, .{
                .code = "UNKNOWN_FLAG",
                .message = msg,
                .fix = "omfx help",
            });
        },
        error.MissingValue => die(stderr, wantsJson(args), omfx.cli.exit_usage, .{
            .code = "MISSING_VALUE",
            .message = "flag requires a value",
            .fix = "omfx help",
        }),
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (parsed.want_help and parsed.command != .help and parsed.command != .interactive) {
        try stdout.print("{s}\n", .{omfx.cli.commandHelp(parsed.command)});
        try stdout.flush();
        return;
    }

    const lookup = omfx.env.Lookup.fromProcess(env);
    const home = lookup.get("HOME") orelse "/tmp";
    var prefs = omfx.settings.load(gpa, io, home);
    defer prefs.deinit(gpa);
    // A persisted mode is a convenience for the interactive session that set
    // it. Carrying it into `omfx ask` disarms every headless run from a choice
    // made in a different session with a human watching -- so one-shot mode
    // elevates only on an explicit flag or an explicit env var.
    const remembered = parsed.command == .interactive;
    const mode: omfx.config.PermissionMode = if (parsed.yolo) .yolo else if (parsed.auto) .auto else blk: {
        if (remembered and prefs.last_mode.len > 0) {
            if (omfx.config.PermissionMode.fromSlice(prefs.last_mode)) |m| break :blk m;
        }
        break :blk modeFromEnv(lookup);
    };
    const want_provider = parsed.provider orelse (if (prefs.last_provider.len > 0) prefs.last_provider else null);
    const want_model = parsed.model orelse (if (prefs.last_model.len > 0) prefs.last_model else null);
    const auth_json = readAuth(arena, io, home);
    const resolved = omfx.providers.auth.resolveStored(lookup, auth_json, want_provider, want_model);
    const model_name = parsed.model orelse lookup.get("OMFX_MODEL") orelse if (resolved) |r| r.model else "(unset)";
    const provider_id = parsed.provider orelse if (resolved) |r| r.spec.id else "(unset)";
    const cwd_z = std.process.currentPathAlloc(io, arena) catch try arena.dupeZ(u8, ".");
    const workspace = std.mem.sliceTo(cwd_z, 0);

    switch (parsed.command) {
        .help => {
            const help_color = Io.File.stdout().isTty(io) catch false;
            if (parsed.help_topic) |topic| {
                if (omfx.cli.commandFromName(topic)) |tag| {
                    try omfx.cli.writeHelp(stdout, omfx.cli.commandHelp(tag), help_color);
                    try stdout.writeAll("\n");
                } else {
                    var msg_buf: [160]u8 = undefined;
                    const msg = std.fmt.bufPrint(&msg_buf, "unknown command '{s}'", .{topic}) catch "unknown command";
                    var fix_buf: [160]u8 = undefined;
                    const fix = if (omfx.cli.closestCommand(topic)) |hint|
                        std.fmt.bufPrint(&fix_buf, "omfx help {s}", .{hint}) catch "omfx help"
                    else
                        @as([]const u8, "omfx help");
                    die(stderr, parsed.json, omfx.cli.exit_usage, .{
                        .code = "UNKNOWN_COMMAND",
                        .message = msg,
                        .fix = fix,
                    });
                }
            } else {
                try omfx.cli.writeHelp(stdout, omfx.cli.help_text, help_color);
            }
            try stdout.flush();
        },
        .version => {
            try stdout.print("omfx {s}\n", .{omfx.cli.version});
            try stdout.flush();
        },
        .update => {
            omfx.update.run(gpa, io, stdout, .{
                .check = parsed.check,
                .force = parsed.force,
            }) catch |err| switch (err) {
                error.NoRelease => die(stderr, parsed.json, omfx.cli.exit_fail, .{
                    .code = "NO_RELEASE",
                    .message = "no GitHub release published yet",
                    .fix = "publish a release, or curl install.sh when one exists",
                }),
                else => {
                    var msg_buf: [80]u8 = undefined;
                    const msg = std.fmt.bufPrint(&msg_buf, "update failed ({s})", .{@errorName(err)}) catch "update failed";
                    die(stderr, parsed.json, omfx.cli.exit_fail, .{
                        .code = "UPDATE_FAILED",
                        .message = msg,
                        .fix = "omfx update --check    (or set GITHUB_TOKEN)",
                    });
                },
            };
            try stdout.flush();
        },
        .doctor => {
            const text = try omfx.run.doctorText(arena, home, model_name, provider_id);
            try stdout.writeAll(text);
            try stdout.flush();
        },
        .ask => {
            const now = Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
            const live_resolved = if (resolved) |r|
                omfx.providers.auth.ensureResolved(gpa, arena, io, home, lookup, r, now, false) catch |err| blk: {
                    log.warn("oauth ensure: {s}", .{@errorName(err)});
                    break :blk r;
                }
            else
                null;
            var endpoint = endpointFromResolved(arena, live_resolved) orelse {
                if (parsed.json) die(stderr, true, omfx.cli.exit_config, .{
                    .code = "NO_PROVIDER",
                    .message = "no provider configured",
                    .fix = "omfx login",
                });
                try stderr.writeAll(omfx.run.missing_key_text);
                try stderr.flush();
                std.process.exit(omfx.cli.exit_config);
            };
            applyEffort(&endpoint, parsed.effort);
            var prompt_text = try omfx.run.joinPrompt(arena, parsed.rest);
            if (prompt_text.len == 0) {
                die(stderr, parsed.json, omfx.cli.exit_usage, .{
                    .code = "MISSING_PROMPT",
                    .message = "omfx ask needs a prompt",
                    .fix = "omfx ask \"what does src/main.zig do?\"",
                });
            }
            const skills_expanded = try omfx.skills.expand(arena, io, home, workspace, prompt_text);
            if (skills_expanded) |expanded| {
                prompt_text = expanded;
            }
            prompt_text = try omfx.mention.expand(arena, Io.Dir.cwd(), io, workspace, prompt_text);
            const skill_roots = try omfx.skills.readAccessRoots(arena, io, home, workspace);
            omfx.tools.pathing.setAccess(.{ .workspace = workspace, .read_extra = skill_roots });
            defer omfx.tools.pathing.setAccess(.{ .workspace = "" });
            const stdin_tty = Io.File.stdin().isTty(io) catch false;
            const can_prompt = parsed.prompt_permissions and stdin_tty;
            var cfg = omfx.settings.load(gpa, io, home);
            defer cfg.deinit(gpa);
            omfx.tools.relay.ensure(gpa, io, omfx.settings.cdpPort(cfg));
            var reads = omfx.agent.Reads.init(gpa);
            defer reads.deinit();
            var trace = omfx.agent.Trace{};
            var cancel: std.atomic.Value(bool) = .init(false);
            const out_tty = Io.File.stdout().isTty(io) catch false;
            const paint = out_tty and omfx.env.colorOn(lookup);
            var live: omfx.live.Live = if (parsed.json)
                omfx.live.json(stdout, &cancel)
            else
                omfx.live.stream(stdout, &cancel, gpa, omfx.tui.ThinkView.init(omfx.settings.thinkingOn(cfg)), paint);
            if (parsed.json) {
                var sess_buf: [320]u8 = undefined;
                const sess_line = std.fmt.bufPrint(&sess_buf, "provider={s} model={s}", .{
                    if (endpoint.id.len > 0) endpoint.id else endpoint.vendor.asSlice(),
                    endpoint.model,
                }) catch "session";
                omfx.live.emitJson(stdout, "session", sess_line);
                // So harnesses can assert expansion without depending on think
                // tokens (cheap models often skip reasoning).
                if (skills_expanded) |expanded| {
                    omfx.live.emitJson(stdout, "skills", expanded);
                }
            }
            const peer_depth = cfg.max_peer_depth;
            const reply = omfx.agent.chatOnce(
                gpa,
                io,
                Io.Dir.cwd(),
                workspace,
                endpoint,
                prompt_text,
                .{
                    .mode = mode,
                    .has_tty = can_prompt,
                    .home = home,
                    .reads = &reads,
                    .trace = &trace,
                    .host = live.host(),
                    .max_peer_depth = peer_depth,
                    .lookup = lookup,
                    .auth_json = auth_json,
                },
            ) catch |err| {
                if (parsed.json) {
                    omfx.live.emitJson(stdout, "error", @errorName(err));
                    try stdout.flush();
                }
                return err;
            };
            defer gpa.free(reply);
            live.closeThink();
            if (!parsed.json) {
                // `.stream` already painted tokens via host.on_text; reprinting
                // the full reply doubled every ask ("The" + "The" → "TheThe").
                if (reply.len == 0 or reply[reply.len - 1] != '\n') try stdout.writeAll("\n");
            } else {
                omfx.live.emitJson(stdout, "result", reply);
            }
            if (omfx.diagram.save(gpa, Io.Dir.cwd(), io, reply)) |saved| {
                defer saved.deinit(gpa);
                switch (saved) {
                    .none => {},
                    .report => |msg| if (parsed.json) omfx.live.emitJson(stdout, "diagram", msg) else try stdout.writeAll(msg),
                }
            } else |err| {
                log.warn("diagram: {s}", .{@errorName(err)});
            }
            try stdout.flush();
        },
        .session => {
            try runSession(gpa, arena, io, stdout, stderr, home, parsed.rest);
        },
        .interactive => {
            const tty = Io.File.stdout().isTty(io) catch false;
            if (!tty) {
                die(stderr, parsed.json, omfx.cli.exit_usage, .{
                    .code = "NOT_A_TTY",
                    .message = "interactive session needs a terminal",
                    .fix = "omfx ask \"your prompt\"",
                });
            }
            try omfx.repl.run(gpa, arena, io, stdout, home, workspace, lookup, model_name, resolved, mode, parsed);
        },
        .browser_relay => {
            if (parsed.rest.len > 0 and std.mem.eql(u8, parsed.rest[0], "install")) {
                const msg = try omfx.tools.relay.install(gpa, io, home);
                defer gpa.free(msg);
                try stdout.writeAll(msg);
                try stdout.flush();
                return;
            }
            var cfg = omfx.settings.load(gpa, io, home);
            defer cfg.deinit(gpa);
            const port = omfx.settings.cdpPort(cfg);
            try stdout.print("omfx browser-relay listening on 127.0.0.1:{d}\n", .{port});
            try stdout.flush();
            try omfx.tools.relay.serve(gpa, io, port, "");
        },
        .login => {
            const provider = if (parsed.rest.len > 0) parsed.rest[0] else null;
            omfx.providers.login.run(gpa, io, home, provider, stdout, stderr) catch |err| switch (err) {
                error.UnknownProvider => die(stderr, parsed.json, omfx.cli.exit_fail, .{
                    .code = "UNKNOWN_PROVIDER",
                    .message = "unknown login provider",
                    .fix = "omfx login",
                }),
                error.Canceled => die(stderr, parsed.json, omfx.cli.exit_fail, .{
                    .code = "LOGIN_CANCELED",
                    .message = "login canceled",
                    .fix = "omfx login",
                }),
                else => {
                    var msg_buf: [80]u8 = undefined;
                    const msg = std.fmt.bufPrint(&msg_buf, "login failed ({s})", .{@errorName(err)}) catch "login failed";
                    die(stderr, parsed.json, omfx.cli.exit_fail, .{
                        .code = "LOGIN_FAILED",
                        .message = msg,
                        .fix = "omfx login",
                    });
                },
            };
            if (provider) |id| {
                if (omfx.providers.catalog.byId(id)) |spec| {
                    omfx.settings.rememberProvider(
                        gpa,
                        io,
                        home,
                        omfx.providers.catalog.storeId(spec),
                        spec.model,
                    ) catch |err| {
                        log.warn("persist last provider: {s}", .{@errorName(err)});
                    };
                }
            }
        },
    }
}

fn wantsJson(args: []const []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, "--json")) return true;
    }
    return false;
}

fn die(stderr: *Io.Writer, json: bool, status: u8, fail: omfx.cli.Fail) noreturn {
    omfx.cli.writeFail(stderr, json, fail);
    stderr.flush() catch {};
    std.process.exit(status);
}

fn firstNonFlag(args: []const []const u8) []const u8 {
    for (args[1..]) |a| {
        if (a.len == 0 or a[0] != '-') return a;
    }
    return "";
}

fn firstUnknownFlag(args: []const []const u8) []const u8 {
    for (args[1..]) |a| {
        if (a.len > 0 and a[0] == '-') return a;
    }
    return "";
}

fn modeFromEnv(lookup: omfx.env.Lookup) omfx.config.PermissionMode {
    if (lookup.get("OMFX_YOLO")) |v| {
        if (v.len > 0) return .yolo;
    }
    if (lookup.get("OMFX_PERMISSION_MODE")) |v| {
        return omfx.config.PermissionMode.fromSlice(v) orelse .ask;
    }
    return .ask;
}

fn readAuth(arena: std.mem.Allocator, io: Io, home: []const u8) []const u8 {
    return omfx.providers.auth.readJson(arena, io, home);
}

fn endpointFromResolved(arena: std.mem.Allocator, resolved_opt: ?omfx.providers.catalog.Resolved) ?omfx.providers.types.Endpoint {
    const resolved = resolved_opt orelse return null;
    return omfx.providers.catalog.ownedEndpoint(arena, resolved);
}

fn applyEffort(endpoint: *omfx.providers.types.Endpoint, effort: ?[]const u8) void {
    if (effort) |e| endpoint.effort = e;
}

fn runSession(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    home: []const u8,
    rest: []const []const u8,
) !void {
    const dir_path = try std.fs.path.join(arena, &.{ home, ".omfx", "sessions" });
    Io.Dir.cwd().createDirPath(io, dir_path) catch |err| {
        log.warn("mkdir {s}: {s}", .{ dir_path, @errorName(err) });
    };
    var sess_dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        try stdout.writeAll("no sessions\n");
        try stdout.flush();
        return;
    };
    defer sess_dir.close(io);

    if (rest.len == 0 or std.mem.eql(u8, rest[0], "list")) {
        const ids = try omfx.session.listIds(sess_dir, io, arena);
        if (ids.len == 0) {
            try stdout.writeAll("no sessions\n");
        } else {
            for (ids) |id| try stdout.print("{s}\n", .{id});
        }
        try stdout.flush();
        return;
    }
    const want = if (std.mem.eql(u8, rest[0], "resume"))
        (if (rest.len > 1) rest[1] else "last")
    else
        rest[0];
    const id = omfx.session.resolveId(want);
    const path = try omfx.session.sessionPath(arena, home, id);
    const blob = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1_000_000)) catch {
        var msg_buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "session not found '{s}'", .{id.bytes}) catch "session not found";
        die(stderr, false, omfx.cli.exit_fail, .{
            .code = "SESSION_NOT_FOUND",
            .message = msg,
            .fix = "omfx session",
        });
    };
    try stdout.writeAll(blob);
    if (blob.len == 0 or blob[blob.len - 1] != '\n') try stdout.writeAll("\n");
    try stdout.flush();
    _ = gpa;
}

test {
    _ = omfx;
}
