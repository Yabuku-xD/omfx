const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const json_path: []const u8 = if (args.len > 1) args[1] else "data/models.json";
    const out_path: []const u8 = if (args.len > 2) args[2] else "src/providers/models/table.zig";

    const json_stat = try Io.Dir.cwd().statFile(io, json_path, .{});
    if (Io.Dir.cwd().statFile(io, out_path, .{})) |out_stat| {
        if (out_stat.mtime.toNanoseconds() >= json_stat.mtime.toNanoseconds()) return;
    } else |_| {}

    const json_bytes = try Io.Dir.cwd().readFileAlloc(io, json_path, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(json_bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_bytes, .{});
    defer parsed.deinit();

    const entries = parsed.value.object.get("entries") orelse return error.MissingEntries;
    if (entries != .array) return error.BadEntries;

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("const Model = @import(\"model.zig\").Model;\n\npub const all = [_]Model{\n");
    for (entries.array.items) |entry| {
        const obj = entry.object;
        if (obj.get("section")) |section| {
            try w.print("    // -- {s}\n", .{section.string});
            continue;
        }
        if (obj.get("comment")) |comment| {
            if (comment.string.len != 0) try w.print("    // {s}\n", .{comment.string});
            continue;
        }
        const model_val = obj.get("model") orelse continue;
        const m = model_val.object;
        try w.writeAll("    .{\n");
        try writeStringField(w, "id", m.get("id").?.string);
        try writeStringField(w, "name", m.get("name").?.string);
        try writeStringField(w, "provider", m.get("provider").?.string);
        try writeProtocolField(w, m.get("protocol").?.string);
        try writeStringField(w, "base_url", m.get("base_url").?.string);
        try writeBoolField(w, "reasoning", m.get("reasoning").?.bool);
        try writeIntField(w, "context_window", @intCast(m.get("context_window").?.integer));
        try writeIntField(w, "max_tokens", @intCast(m.get("max_tokens").?.integer));
        try writeStringField(w, "efforts", m.get("efforts").?.string);
        try writeBoolField(w, "vision", m.get("vision").?.bool);
        try w.writeAll("    },\n");
    }
    try w.writeAll("};\n");

    var f = try Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer f.close(io);
    var file_buf: [8192]u8 = undefined;
    var file_w = f.writer(io, &file_buf);
    try file_w.interface.writeAll(aw.written());
    try file_w.interface.flush();
}

fn writeStringField(w: anytype, key: []const u8, value: []const u8) !void {
    try w.print("        .{s} = ", .{key});
    try zigString(w, value);
    try w.writeAll(",\n");
}

fn writeBoolField(w: anytype, key: []const u8, value: bool) !void {
    try w.print("        .{s} = {s},\n", .{ key, if (value) "true" else "false" });
}

fn writeIntField(w: anytype, key: []const u8, value: u32) !void {
    try w.print("        .{s} = {d},\n", .{ key, value });
}

fn writeProtocolField(w: anytype, value: []const u8) !void {
    try w.writeAll("        .protocol = .");
    try w.writeAll(value);
    try w.writeAll(",\n");
}

fn zigString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}
