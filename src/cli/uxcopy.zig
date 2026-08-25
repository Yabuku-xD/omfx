//! Plain-language labels for permission asks (tool names stay technical).

const std = @import("std");
const Tool = @import("../core/tool.zig");

pub fn actionTitle(name: []const u8) []const u8 {
    const tool = Tool.Name.fromSlice(name) orelse return "Do something";
    return switch (tool) {
        .bash => "Run a command",
        .read => "Read a file",
        .write => "Write a file",
        .edit, .patch => "Change a file",
        .grep => "Search in files",
        .glob => "Find files by name",
        .list => "List a folder",
        .copy => "Copy a file",
        .mkdir => "Make a folder",
        .delete => "Delete a file",
        .rename => "Rename a file",
        .file_info => "Check a file",
        .open_file => "Open a file",
        .semantic_search => "Search the project",
        .web_search => "Search the web",
        .web_fetch, .web_scrape => "Open a web page",
        .ask_user => "Ask you a question",
        .todo => "Update the task list",
        .peer => "Ask a teammate",
        .board => "Write on the board",
        .memory => "Remember something",
        .browser => "Use the browser",
        .mcp => "Use a connected tool",
        .compact => "Shorten the chat",
        .job => "Check a background job",
        .read_result => "Read a past result",
    };
}

pub fn missingDetail(name: []const u8) []const u8 {
    const tool = Tool.Name.fromSlice(name) orelse return "No details were given.";
    return switch (tool) {
        .bash => "No command was given.",
        .read, .write, .edit, .patch, .copy, .delete, .rename, .file_info, .open_file => "No file was named.",
        .mkdir, .list => "No folder was named.",
        .web_fetch, .web_scrape => "No web address was given.",
        .web_search, .grep, .glob, .semantic_search => "Nothing to search for.",
        else => "No details were given.",
    };
}

test "every tool name has a plain title" {
    inline for (std.meta.tags(Tool.Name)) |tag| {
        const title = actionTitle(@tagName(tag));
        try std.testing.expect(title.len > 0);
        try std.testing.expect(!std.mem.eql(u8, title, @tagName(tag)));
    }
    try std.testing.expectEqualStrings("Change a file", actionTitle("edit"));
    try std.testing.expectEqualStrings("Run a command", actionTitle("bash"));
}

test "missing details stay plain" {
    try std.testing.expectEqualStrings("No command was given.", missingDetail("bash"));
    try std.testing.expectEqualStrings("No file was named.", missingDetail("write"));
    try std.testing.expectEqualStrings("No details were given.", missingDetail("not-a-tool"));
}
