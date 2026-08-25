const std = @import("std");
const Io = std.Io;
const config = @import("../config.zig");
const settings = @import("../settings.zig");
const peer_router = @import("../peer_router.zig");
const dispatch = @import("../../tools/dispatch.zig");
const diag = @import("../../tools/diag.zig");
const gate = @import("../../tools/gate.zig");
const undo = @import("../../tools/undo.zig");
const sse = @import("../../providers/sse.zig");
const types = @import("../../providers/types.zig");
const Tool = @import("../tool.zig");
const isolate = @import("../../tools/isolate.zig");
const permissions = @import("../permissions.zig");
const turn_loop = @import("turn_loop.zig");
const setup = @import("setup.zig");
const reflect = @import("reflect.zig");
const compact = @import("../../core/compact.zig");
const hooks = @import("../../core/hooks.zig");
const recall = @import("../../core/recall.zig");
const trim = @import("../../core/trim.zig");

pub const doom_after: usize = 3;

pub const ChatOnceFn = *const fn (
    std.mem.Allocator,
    Io,
    Io.Dir,
    []const u8,
    types.Endpoint,
    []const u8,
    setup.Run,
) setup.ChatError![]u8;

pub const AdmitOutcome = union(enum) {
    stop: []u8,
    result: []u8,
};

pub const AdmitArgs = struct {
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    workspace: []const u8,
    endpoint: types.Endpoint,
    home: []const u8,
    mode: config.PermissionMode,
    has_tty: bool,
    reads: *setup.Reads,
    depth: u8,
    depth_cap: u8,
    allow_peer: bool,
    host: @import("../sink.zig").Host,
    trace: ?*setup.Trace,
    plan: setup.Plan,
    cfg: settings.File,
    lookup: @import("../env.zig").Lookup,
    auth_json: []const u8,
    explored: bool,
    same: usize,
    asst_text: []u8,
    tool_name: []u8,
    tool_args: []u8,
    path: ?[]const u8,
    thread: *std.ArrayList(@import("../../providers/client.zig").Message),
    chat_once: ChatOnceFn,
};

/// Runs an admitted tool: doom, peer, ask_user, compact, verify-gated writes, or dispatch.
pub fn executeAdmitted(a: AdmitArgs) !AdmitOutcome {
    const allocator = a.allocator;
    if (a.same >= doom_after) {
        allocator.free(a.asst_text);
        const msg = try std.fmt.allocPrint(
            allocator,
            "doom_loop: same tool {d} times with identical input (doom_after={d}); not a clean verdict.\n",
            .{ a.same, doom_after },
        );
        var doom_detail_buf: [permissions.max_command]u8 = undefined;
        a.host.toolOut(a.tool_name, turn_loop.toolDetail(&doom_detail_buf, a.tool_args), true, msg);
        allocator.free(a.tool_name);
        allocator.free(a.tool_args);
        return .{ .stop = msg };
    }

    const tool_name = a.tool_name;
    const tool_args = a.tool_args;
    const path = a.path;
    var result: []u8 = undefined;
    if (Tool.Name.fromSlice(tool_name) == .peer) {
        if (a.depth >= a.depth_cap) {
            result = try allocator.dupe(u8, "peer: nested peer denied; post to board so other peers can read it\n");
        } else if (!a.allow_peer) {
            result = try allocator.dupe(u8, "peer: auto delegation is off for this task; manual /peers still works\n");
        } else {
            const goal = sse.argString(allocator, tool_args, "goal") orelse
                sse.argString(allocator, tool_args, "query") orelse "";
            const nested = try reflect.peerTask(allocator, goal);
            defer allocator.free(nested);
            var place = try isolate.forPeer(allocator, a.dir, a.io, a.workspace, a.depth + 1);
            defer place.deinit(allocator);
            const opened = isolate.open(place, a.io, a.dir);
            defer opened.deinit(a.io);
            const peer_ws = place.workspace(a.workspace);
            var peer_ep = peer_router.endpoint(
                allocator,
                a.io,
                a.home,
                a.lookup,
                a.auth_json,
                a.endpoint,
                goal,
            ) catch |err| blk: {
                if (err == error.NoCredential) break :blk a.endpoint;
                return err;
            };
            const peer_owned = !std.mem.eql(u8, peer_ep.base_url, a.endpoint.base_url) or
                !std.mem.eql(u8, peer_ep.api_key, a.endpoint.api_key) or
                !std.mem.eql(u8, peer_ep.model, a.endpoint.model);
            defer if (peer_owned) peer_router.deinitEndpoint(allocator, &peer_ep);
            result = a.chat_once(allocator, a.io, opened.dir(), peer_ws, peer_ep, nested, .{
                .mode = a.mode,
                .has_tty = a.has_tty,
                .home = a.home,
                .reads = a.reads,
                .depth = a.depth + 1,
                .trace = a.trace,
                .plan = a.plan,
                .host = a.host,
                .max_peer_depth = a.depth_cap,
                .lookup = a.lookup,
                .auth_json = a.auth_json,
            }) catch |err|
                try std.fmt.allocPrint(allocator, "Note (kept):\n(FAIL peer {s})\n", .{@errorName(err)});
        }
    } else if (Tool.Name.fromSlice(tool_name) == .ask_user) {
        const q = sse.argString(allocator, tool_args, "question") orelse "confirm?";
        result = try permissions.askText(a.io, allocator, q);
    } else if (Tool.Name.fromSlice(tool_name) == .compact) {
        result = try allocator.dupe(u8, switch (try setup.compactThread(allocator, a.thread)) {
            .applied => "compacted. ARC cites at .omfx/recall/rN.txt; never encrypted. continue from the kept tail.\n",
            .skipped => "compact skipped: under turn/char budget.\n",
        });
    } else if (blk: {
        const n = Tool.Name.fromSlice(tool_name) orelse break :blk false;
        break :blk n.needsVerify() and path != null;
    }) {
        const p = path.?;
        const exists = setup.fileExists(a.dir, a.io, allocator, p);
        const need_read = Tool.Name.fromSlice(tool_name) == .edit or exists;
        if (!a.explored) {
            result = try setup.exploreBlock(allocator, tool_name);
        } else if (need_read and !a.reads.guard.mayEdit(p)) {
            result = try setup.Guard.blockMessage(allocator, tool_name, p);
        } else {
            const mark = undo.depth(allocator, a.dir, a.io);
            result = dispatch.run(a.dir, a.io, allocator, a.workspace, tool_name, tool_args, a.home) catch |err| blk: {
                break :blk try std.fmt.allocPrint(allocator, "tool error: {s}", .{@errorName(err)});
            };
            a.reads.guard.record(p);
            const note = diag.afterWrite(allocator, a.io, a.workspace, a.dir, p) catch
                try diag.unavailable(allocator, "checker failed");
            defer allocator.free(note);
            if (gate.rejectIfNewlyBroken(allocator, a.io, a.workspace, a.dir, p, mark, note) catch null) |rejected| {
                allocator.free(result);
                result = rejected;
            } else {
                const diff = diag.afterDiff(allocator, a.io, a.workspace, p) catch
                    try allocator.dupe(u8, "review: unavailable (git diff failed); not a clean verdict\n");
                defer allocator.free(diff);
                var llm_review: []const u8 = "";
                if (settings.reviewLlm(a.cfg)) {
                    llm_review = try billedReview(allocator, a.io, a.endpoint, diff);
                }
                defer if (llm_review.len > 0) allocator.free(llm_review);
                const joined = try std.fmt.allocPrint(allocator, "{s}\n{s}{s}{s}", .{ result, note, diff, llm_review });
                allocator.free(result);
                result = joined;
            }
        }
    } else {
        result = dispatch.run(a.dir, a.io, allocator, a.workspace, tool_name, tool_args, a.home) catch |err| blk: {
            break :blk try std.fmt.allocPrint(allocator, "tool error: {s}", .{@errorName(err)});
        };
        if (path) |p| {
            if (Tool.Name.fromSlice(tool_name) == .read) a.reads.guard.record(p);
        }
    }
    return .{ .result = result };
}

pub fn bumpRepeat(
    same: *usize,
    prev_name: []const u8,
    prev_args: []const u8,
    name: []const u8,
    args: []const u8,
) usize {
    if (std.mem.eql(u8, prev_name, name) and std.mem.eql(u8, prev_args, args)) {
        same.* += 1;
    } else {
        same.* = 1;
    }
    return same.*;
}

pub fn presentResult(
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    io: Io,
    tool_name: []const u8,
    path: ?[]const u8,
    follow_raw: []const u8,
    archive_src: []const u8,
) ![]u8 {
    const trimmed = try trim.apply(allocator, follow_raw);
    const secret = hooks.hasSecret(archive_src);
    if (follow_raw.len <= compact.result_budget and !secret) return trimmed;
    defer allocator.free(trimmed);
    if (!secret and exploreSkipRecall(tool_name)) {
        return compact.capResult(allocator, trimmed);
    }
    const target: recall.Target = if (path) |p| .{ .path = p } else .none;
    const body = if (secret) archive_src else follow_raw;
    const id = recall.put(dir, io, tool_name, target, body) catch {
        return compact.capResult(allocator, trimmed);
    };
    const stub = try recall.cite(allocator, .{
        .id = id,
        .tool = tool_name,
        .target = target,
        .chars = body.len,
    });
    defer allocator.free(stub);
    const joined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ stub, trimmed });
    defer allocator.free(joined);
    return compact.capResult(allocator, joined);
}

fn exploreSkipRecall(tool_name: []const u8) bool {
    const n = Tool.Name.fromSlice(tool_name) orelse return false;
    return switch (n) {
        .list, .glob, .grep, .semantic_search, .file_info, .bash, .job, .web_search, .web_fetch, .web_scrape => true,
        else => false,
    };
}

fn billedReview(
    allocator: std.mem.Allocator,
    io: Io,
    endpoint: types.Endpoint,
    diff: []const u8,
) ![]u8 {
    const pclient = @import("../../providers/client.zig");
    const sys = diag.reviewPrompt(diff);
    const user = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ sys, diff });
    defer allocator.free(user);
    const msgs = [_]pclient.Message{.{ .role = "user", .content = user }};
    var rev = try pclient.postChatMsgs(allocator, io, endpoint, &msgs, sys);
    defer rev.deinit(allocator);
    return std.fmt.allocPrint(allocator, "review: llm\n{s}", .{rev.textSlice()});
}

test "presentResult archives secret-shaped bodies as placeholder" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const raw = "api_key=sk-secret-e2e-not-for-disk\n";
    const follow = "Tool bash result:\napi_key***\nContinue.";
    const out = try presentResult(a, tmp.dir, io, "bash", null, follow, raw);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "cite r") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sk-secret-e2e") == null);
    const body = try recall.load(a, tmp.dir, io, @enumFromInt(1));
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "(sensitive; not saved)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "sk-secret-e2e") == null);
}

test "doom_loop trips on the third identical call" {
    var same: usize = 0;
    try std.testing.expectEqual(@as(usize, 1), bumpRepeat(&same, "", "", "read", "{}"));
    try std.testing.expectEqual(@as(usize, 1), bumpRepeat(&same, "read", "{}", "write", "{}"));
    try std.testing.expectEqual(@as(usize, 2), bumpRepeat(&same, "write", "{}", "write", "{}"));
    try std.testing.expectEqual(@as(usize, 3), bumpRepeat(&same, "write", "{}", "write", "{}"));
    try std.testing.expect(same >= doom_after);
}
