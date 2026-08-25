const std = @import("std");
const Io = std.Io;
const fs = @import("../fs.zig");
const bash = @import("../bash.zig");
const settings = @import("../../core/settings.zig");
const deadline = @import("../deadline.zig");
const jobs = @import("../jobs.zig");
const recall = @import("../../core/recall.zig");
const hooks = @import("../../core/hooks.zig");
const tool = @import("../../core/tool.zig");
const Args = @import("args.zig").Args;

pub fn run(
    kind: tool.Name,
    dir: Io.Dir,
    io: Io,
    allocator: std.mem.Allocator,
    workspace: []const u8,
    home: []const u8,
    args: Args,
) ![]u8 {
    return switch (kind) {
        .bash => blk: {
            const command = args.str("command") orelse return error.EmptyCommand;
            // Detached by default for anything that does not end: a dev server
            // or a watcher would otherwise burn the whole budget and return
            // nothing. The model can force either mode.
            if (args.flag("background") orelse bash.looksUnbounded(command)) {
                break :blk try bash.runBackground(allocator, io, workspace, command);
            }
            var cfg = settings.load(allocator, io, home);
            defer cfg.deinit(allocator);
            const secs: u32 = if (args.usize_("timeout")) |t| @intCast(@min(t, 100_000)) else deadline.default_secs;
            break :blk try bash.runFor(allocator, io, workspace, command, !settings.sandboxOff(cfg), secs);
        },
        .job => blk: {
            const id = args.usize_("id") orelse return error.MissingPath;
            if (args.flag("kill") orelse false) {
                break :blk try std.fmt.allocPrint(allocator, "{s}\n", .{
                    if (jobs.kill(id)) "killed" else "no such job",
                });
            }
            break :blk try jobs.poll(allocator, io, workspace, id);
        },
        .read_result => blk: {
            // id forms: "r3" / "3" (recall), "job:5" (background log).
            const id_s = args.str("id") orelse return error.MissingPath;
            if (std.mem.startsWith(u8, id_s, "job:")) {
                const n = std.fmt.parseInt(usize, id_s["job:".len..], 10) catch
                    break :blk try allocator.dupe(u8, "read_result: bad job id\n");
                const path = try jobs.logRel(allocator, n);
                defer allocator.free(path);
                const raw = fs.read(dir, io, allocator, workspace, path) catch
                    break :blk try std.fmt.allocPrint(allocator, "read_result: no job log for {d}\n", .{n});
                defer allocator.free(raw);
                if (hooks.hasSecret(raw)) {
                    break :blk try allocator.dupe(u8, "read_result: sensitive; not shown\n");
                }
                break :blk try hooks.mask(allocator, raw);
            }
            var digits = id_s;
            if (digits.len > 0 and (digits[0] == 'r' or digits[0] == 'R')) digits = digits[1..];
            const n = std.fmt.parseInt(u16, digits, 10) catch
                break :blk try allocator.dupe(u8, "read_result: id is rN or job:N\n");
            const body = recall.load(allocator, dir, io, @enumFromInt(n)) catch
                break :blk try std.fmt.allocPrint(allocator, "read_result: no archive r{d}\n", .{n});
            defer allocator.free(body);
            // Hand-edited archives can still hold secrets; never replay them.
            if (hooks.hasSecret(body)) {
                break :blk try allocator.dupe(u8, "read_result: sensitive; not shown\n");
            }
            break :blk try hooks.mask(allocator, body);
        },
        else => unreachable,
    };
}
