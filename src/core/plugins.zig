const std = @import("std");
const Io = std.Io;
const settings = @import("settings.zig");

const log = std.log.scoped(.plugins);

pub fn githubRawUrl(allocator: std.mem.Allocator, owner_repo: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, owner_repo, '/')) |_| {
        return std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/main/.claude-plugin/marketplace.json", .{owner_repo});
    }
    return error.InvalidMarketplace;
}

pub fn fetchManifest(allocator: std.mem.Allocator, io: Io, owner_repo: []const u8) ![]u8 {
    const url = try githubRawUrl(allocator, owner_repo);
    defer allocator.free(url);
    const web = @import("../tools/web.zig");
    return web.fetch(allocator, io, url);
}

fn appendMarketplace(allocator: std.mem.Allocator, io: Io, home: []const u8, id: []const u8) !void {
    try settings.addPluginMarketplace(allocator, io, home, id);
}

pub fn listCatalog(allocator: std.mem.Allocator, io: Io, home: []const u8) ![]u8 {
    var cfg = settings.load(allocator, io, home);
    defer cfg.deinit(allocator);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "plugin marketplaces:\n");
    if (cfg.plugin_marketplaces.len == 0) {
        try out.appendSlice(allocator, "  (none)\n  add: /plugin marketplace add owner/repo\n");
        try out.appendSlice(allocator, "  e.g. anthropics/claude-plugins-official\n");
        return out.toOwnedSlice(allocator);
    }
    for (cfg.plugin_marketplaces) |m| {
        try out.appendSlice(allocator, "  ");
        try out.appendSlice(allocator, m);
        try out.append(allocator, '\n');
        const manifest = fetchManifest(allocator, io, m) catch |err| {
            try out.print(allocator, "    fetch failed: {s}\n", .{@errorName(err)});
            continue;
        };
        defer allocator.free(manifest);
        var count: usize = 0;
        var at: usize = 0;
        while (std.mem.indexOf(u8, manifest[at..], "\"name\"")) |hit| {
            count += 1;
            at += hit + 6;
            if (count >= 24) break;
        }
        try out.print(allocator, "    ~{d} entries in manifest\n", .{count});
    }
    try out.appendSlice(allocator, "\n/plugin marketplace add owner/repo\n");
    try out.appendSlice(allocator, "/plugin install name@marketplace (install pass next)\n");
    return out.toOwnedSlice(allocator);
}

pub fn run(allocator: std.mem.Allocator, io: Io, home: []const u8, rest: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "list")) {
        return listCatalog(allocator, io, home);
    }
    if (std.mem.startsWith(u8, trimmed, "marketplace ")) {
        const sub = std.mem.trim(u8, trimmed["marketplace ".len..], " \t");
        if (std.mem.startsWith(u8, sub, "add ")) {
            const id = std.mem.trim(u8, sub["add ".len..], " \t");
            if (id.len == 0) return allocator.dupe(u8, "usage: /plugin marketplace add owner/repo\n");
            try appendMarketplace(allocator, io, home, id);
            return std.fmt.allocPrint(allocator, "added marketplace {s}\n", .{id});
        }
        return allocator.dupe(u8, "usage: /plugin marketplace add owner/repo\n");
    }
    if (std.mem.startsWith(u8, trimmed, "install ")) {
        return allocator.dupe(u8, "plugin install will copy marketplace entries into ~/.omfx/plugins/ (next pass)\n");
    }
    return allocator.dupe(u8, "usage: /plugin | marketplace add <owner/repo> | install <name>@<market>\n");
}
