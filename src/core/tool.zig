const std = @import("std");

/// Built-in tools. Exhaustive switch at dispatch, permissions, and collect.
pub const Name = enum {
    read,
    write,
    edit,
    bash,
    glob,
    grep,
    list,
    copy,
    mkdir,
    delete,
    rename,
    file_info,
    open_file,
    semantic_search,
    web_fetch,
    web_scrape,
    web_search,
    ask_user,
    memory,
    browser,
    peer,
    board,
    mcp,
    patch,
    compact,
    todo,
    job,

    pub fn fromSlice(s: []const u8) ?Name {
        inline for (std.meta.tags(Name)) |tag| {
            if (std.mem.eql(u8, s, @tagName(tag))) return tag;
        }
        return null;
    }

    pub fn asSlice(self: Name) []const u8 {
        return @tagName(self);
    }

    pub fn isExplore(self: Name) bool {
        return switch (self) {
            .read, .list, .grep, .glob, .semantic_search, .file_info, .board, .todo, .job => true,
            .write, .edit, .bash, .copy, .mkdir, .delete, .rename, .open_file, .web_fetch, .web_scrape, .web_search, .ask_user, .memory, .browser, .peer, .mcp, .patch, .compact => false,
        };
    }

    pub fn isSensitive(self: Name) bool {
        return switch (self) {
            .read, .glob, .grep, .web_fetch, .web_scrape, .web_search, .ask_user, .list, .file_info, .semantic_search, .memory, .open_file, .browser, .board, .todo, .job => false,
            .write, .edit, .bash, .copy, .mkdir, .delete, .rename, .peer, .mcp, .patch => true,
            .compact => false,
        };
    }

    pub fn blockedInPlan(self: Name) bool {
        return switch (self) {
            .read, .list, .grep, .glob, .semantic_search, .file_info, .board, .web_fetch, .web_scrape, .web_search, .ask_user, .memory, .bash, .todo, .job => false,
            .write, .edit, .copy, .mkdir, .delete, .rename, .open_file, .browser, .peer, .mcp, .patch => true,
            .compact => false,
        };
    }

    pub fn isRoutineWrite(self: Name) bool {
        return switch (self) {
            .write, .edit, .copy, .mkdir, .patch => true,
            .read, .bash, .glob, .grep, .list, .delete, .rename, .file_info, .open_file, .semantic_search, .web_fetch, .web_scrape, .web_search, .ask_user, .memory, .browser, .peer, .board, .mcp, .compact, .todo, .job => false,
        };
    }

    pub fn needsVerify(self: Name) bool {
        return switch (self) {
            .write, .edit, .patch => true,
            .read, .bash, .glob, .grep, .list, .copy, .mkdir, .delete, .rename, .file_info, .open_file, .semantic_search, .web_fetch, .web_scrape, .web_search, .ask_user, .memory, .browser, .peer, .board, .mcp, .compact, .todo, .job => false,
        };
    }

    pub fn needsAttach(self: Name) bool {
        return switch (self) {
            .read, .write, .edit, .patch => true,
            .bash, .glob, .grep, .list, .copy, .mkdir, .delete, .rename, .file_info, .open_file, .semantic_search, .web_fetch, .web_scrape, .web_search, .ask_user, .memory, .browser, .peer, .board, .mcp, .compact, .todo, .job => false,
        };
    }

    pub const slices = blk: {
        const tags = std.meta.tags(Name);
        var names: [tags.len][]const u8 = undefined;
        for (tags, 0..) |t, i| names[i] = @tagName(t);
        break :blk names;
    };
};

test "fromSlice round trip" {
    try std.testing.expectEqual(Name.read, Name.fromSlice("read").?);
    try std.testing.expectEqual(Name.file_info, Name.fromSlice("file_info").?);
    try std.testing.expect(Name.fromSlice("activate_tools") == null);
    try std.testing.expectEqual(Name.compact, Name.fromSlice("compact").?);
    try std.testing.expect(!Name.compact.isSensitive());
}

test "explore vs write" {
    try std.testing.expect(Name.grep.isExplore());
    try std.testing.expect(!Name.write.isExplore());
    try std.testing.expect(Name.write.isSensitive());
    try std.testing.expect(!Name.read.isSensitive());
    try std.testing.expect(Name.mkdir.isRoutineWrite());
    try std.testing.expect(!Name.read.blockedInPlan());
    try std.testing.expect(Name.write.blockedInPlan());
    try std.testing.expect(!Name.bash.blockedInPlan());
    try std.testing.expect(Name.patch.needsVerify());
    try std.testing.expect(!Name.read.needsVerify());
    try std.testing.expect(Name.read.needsAttach());
    try std.testing.expect(!Name.bash.needsAttach());
}
