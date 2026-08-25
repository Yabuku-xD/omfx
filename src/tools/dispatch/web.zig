const std = @import("std");
const Io = std.Io;
const web = @import("../web.zig");
const settings = @import("../../core/settings.zig");
const cdp = @import("../cdp.zig");
const tool = @import("../../core/tool.zig");
const Args = @import("args.zig").Args;

pub fn run(
    kind: tool.Name,
    io: Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    args: Args,
    args_json: []const u8,
) ![]u8 {
    return switch (kind) {
        .web_fetch => blk: {
            const url = args.str("url") orelse return error.InvalidUrl;
            if (url.len == 0) return error.InvalidUrl;
            break :blk try web.fetch(allocator, io, url);
        },
        .web_scrape => blk: {
            const url = args.str("url") orelse return error.InvalidUrl;
            if (url.len == 0) return error.InvalidUrl;
            break :blk try web.scrape(allocator, io, url);
        },
        .web_search => blk: {
            const q = args.str("query") orelse args.str("q") orelse return error.EmptyQuery;
            if (q.len == 0) return error.EmptyQuery;
            const web_search = @import("../web_search.zig");
            break :blk try web_search.searchFromHome(allocator, io, home, q);
        },
        .browser => blk: {
            var cfg = settings.load(allocator, io, home);
            defer cfg.deinit(allocator);
            break :blk try cdp.run(allocator, io, args_json, settings.cdpPort(cfg));
        },
        else => unreachable,
    };
}
