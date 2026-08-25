const std = @import("std");
const Io = std.Io;
const pathing = @import("../tools/pathing.zig");
const fs = @import("../tools/fs.zig");
const types = @import("../providers/types.zig");

const log = std.log.scoped(.vision);

pub const Mime = types.Mime;
pub const Image = types.Image;

pub const max_images: usize = 4;
pub const max_urls: usize = 8;
pub const max_bytes: usize = 2_000_000;

comptime {
    if (max_images == 0) @compileError("max_images must attach at least one image");
    if (max_urls == 0) @compileError("max_urls must keep at least one url");
    if (max_bytes == 0) @compileError("max_bytes must hold one image");
}

const Class = enum { text, image_file, image_url, url };

pub fn free(allocator: std.mem.Allocator, images: []const Image) void {
    for (images) |im| switch (im) {
        .file => |f| allocator.free(@constCast(f.b64)),
        .url => |u| allocator.free(@constCast(u)),
    };
    if (images.len > 0) allocator.free(@constCast(images));
}

fn freeOwned(allocator: std.mem.Allocator, im: Image) void {
    switch (im) {
        .file => |f| allocator.free(f.b64),
        .url => |u| allocator.free(u),
    }
}

pub fn mimeFromPath(path: []const u8) ?[]const u8 {
    return if (Mime.fromExt(std.fs.path.extension(path))) |m| m.asSlice() else null;
}

pub fn mimeFromMagic(bytes: []const u8) ?Mime {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return .png;
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) return .jpeg;
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return .gif;
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return .webp;
    if (bytes.len >= 2 and bytes[0] == 0x42 and bytes[1] == 0x4d) return .bmp;
    return null;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn stripToken(raw: []const u8) []const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) {
        s = s[1 .. s.len - 1];
    }
    while (s.len > 0) {
        const c = s[s.len - 1];
        if (c == '.' or c == ',' or c == ';' or c == ')' or c == ']' or c == '"' or c == '\'') {
            s = s[0 .. s.len - 1];
            continue;
        }
        break;
    }
    return s;
}

pub fn isHttpUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "https://") or std.mem.startsWith(u8, s, "http://");
}

fn urlStem(s: []const u8) []const u8 {
    var t = s;
    if (std.mem.indexOfScalar(u8, t, '?')) |q| t = t[0..q];
    if (std.mem.indexOfScalar(u8, t, '#')) |h| t = t[0..h];
    return t;
}

fn already(items: []const []const u8, s: []const u8) bool {
    for (items) |p| {
        if (std.mem.eql(u8, p, s)) return true;
    }
    return false;
}

fn fileLooksLikeImage(dir: Io.Dir, io: Io, allocator: std.mem.Allocator, path: []const u8) bool {
    if (pathing.isSecret(path)) return false;
    if (Mime.fromExt(std.fs.path.extension(path)) == null) return false;
    const head = dir.readFileAlloc(io, path, allocator, .limited(max_bytes)) catch return false;
    defer allocator.free(head);
    return mimeFromMagic(head) != null;
}

fn classify(dir: Io.Dir, io: Io, allocator: std.mem.Allocator, tok: []const u8) Class {
    const s = stripToken(tok);
    if (s.len == 0) return .text;
    if (isHttpUrl(s)) {
        if (Mime.fromExt(std.fs.path.extension(urlStem(s))) != null) return .image_url;
        return .url;
    }
    if (fileLooksLikeImage(dir, io, allocator, s)) return .image_file;
    return .text;
}

const Label = enum {
    image,
    url,

    fn word(self: Label) []const u8 {
        return switch (self) {
            .image => "Image",
            .url => "URL",
        };
    }
};

fn appendLabel(out: *std.ArrayList(u8), allocator: std.mem.Allocator, kind: Label, n: usize) !void {
    try out.append(allocator, '[');
    try out.appendSlice(allocator, kind.word());
    try out.append(allocator, ' ');
    var buf: [8]u8 = undefined;
    const ns = try std.fmt.bufPrint(&buf, "{d}", .{n});
    try out.appendSlice(allocator, ns);
    try out.append(allocator, ']');
}

/// Footer/transcript form: `[Image 1] [Image 2] [URL 1]`.
pub fn display(
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    io: Io,
    workspace: []const u8,
    prompt_text: []const u8,
) ![]u8 {
    _ = workspace;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var img_n: usize = 0;
    var url_n: usize = 0;
    var i: usize = 0;
    while (i < prompt_text.len) {
        const ws_start = i;
        while (i < prompt_text.len and isSpace(prompt_text[i])) i += 1;
        if (i > ws_start) try out.appendSlice(allocator, prompt_text[ws_start..i]);
        if (i >= prompt_text.len) break;
        const tok_start = i;
        while (i < prompt_text.len and !isSpace(prompt_text[i])) i += 1;
        const tok = prompt_text[tok_start..i];
        switch (classify(dir, io, allocator, tok)) {
            .image_file, .image_url => {
                if (img_n < max_images) {
                    img_n += 1;
                    try appendLabel(&out, allocator, .image, img_n);
                } else {
                    try out.appendSlice(allocator, tok);
                }
            },
            .url => {
                if (url_n < max_urls) {
                    url_n += 1;
                    try appendLabel(&out, allocator, .url, url_n);
                } else {
                    try out.appendSlice(allocator, tok);
                }
            },
            .text => try out.appendSlice(allocator, tok),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn encodeB64(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const n = std.base64.standard.Encoder.calcSize(bytes.len);
    const buf = try allocator.alloc(u8, n);
    _ = std.base64.standard.Encoder.encode(buf, bytes);
    return buf;
}

/// Image files and image URLs named in the prompt. The provider accepts or rejects vision.
pub fn attach(
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    io: Io,
    workspace: []const u8,
    prompt_text: []const u8,
) ![]Image {
    _ = workspace;
    var store: [max_images]Image = undefined;
    var seen: [max_images][]const u8 = undefined;
    var n: usize = 0;
    errdefer {
        for (store[0..n]) |im| freeOwned(allocator, im);
    }
    var it = std.mem.tokenizeAny(u8, prompt_text, " \t\n\r");
    while (it.next()) |tok| {
        if (n >= max_images) break;
        const path = stripToken(tok);
        if (path.len == 0) continue;
        if (already(seen[0..n], path)) continue;
        switch (classify(dir, io, allocator, path)) {
            .image_url => {
                store[n] = .{ .url = try allocator.dupe(u8, path) };
                seen[n] = path;
                n += 1;
            },
            .image_file => {
                if (pathing.isSecret(path)) continue;
                const body = dir.readFileAlloc(io, path, allocator, .limited(max_bytes + 1)) catch |err| {
                    log.debug("skip {s}: {s}", .{ path, @errorName(err) });
                    continue;
                };
                defer allocator.free(body);
                if (body.len > max_bytes) {
                    log.warn("image: max_bytes={d}, asked for {d} ({s})", .{ max_bytes, body.len, path });
                    continue;
                }
                const mime = mimeFromMagic(body) orelse continue;
                const b64 = encodeB64(allocator, body) catch continue;
                store[n] = .{ .file = .{ .mime = mime, .b64 = b64 } };
                seen[n] = path;
                n += 1;
            },
            .url, .text => {},
        }
    }
    if (n == 0) return &.{};
    return allocator.dupe(Image, store[0..n]);
}

test "mime from extension and magic" {
    try std.testing.expectEqual(Mime.png, Mime.fromExt(".PNG").?);
    try std.testing.expectEqualStrings("image/jpeg", mimeFromPath("/tmp/a.jpeg").?);
    try std.testing.expect(mimeFromPath("notes.txt") == null);
    const png = "\x89PNG\r\n\x1a\nxxxx";
    try std.testing.expectEqual(Mime.png, mimeFromMagic(png).?);
    try std.testing.expect(mimeFromMagic("hello") == null);
}

test "attach picks image paths from the prompt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const png = "\x89PNG\r\n\x1a\n" ++ "0123456789";
    try fs.write(tmp.dir, io, std.testing.allocator, .{ .workspace = "ws" }, "shot.png", png);
    const images = try attach(std.testing.allocator, tmp.dir, io, "ws", "look at shot.png and README.md");
    defer free(std.testing.allocator, images);
    try std.testing.expectEqual(@as(usize, 1), images.len);
    try std.testing.expectEqual(Mime.png, images[0].file.mime);
    try std.testing.expect(images[0].file.b64.len > 0);
}

test "attach skips non-images and secrets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try fs.write(tmp.dir, io, std.testing.allocator, .{ .workspace = "ws" }, "notes.txt", "hello");
    const images = try attach(std.testing.allocator, tmp.dir, io, "ws", "read notes.txt and .env");
    defer free(std.testing.allocator, images);
    try std.testing.expectEqual(@as(usize, 0), images.len);
}

test "attach keeps image urls" {
    const images = try attach(std.testing.allocator, Io.Dir.cwd(), std.testing.io, "ws", "see https://ex.com/a.png");
    defer free(std.testing.allocator, images);
    try std.testing.expectEqual(@as(usize, 1), images.len);
    try std.testing.expectEqualStrings("https://ex.com/a.png", images[0].url);
}

test "display uses Image and URL placeholders" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const png = "\x89PNG\r\n\x1a\n" ++ "0123456789";
    try fs.write(tmp.dir, io, std.testing.allocator, .{ .workspace = "ws" }, "shot.png", png);
    try fs.write(tmp.dir, io, std.testing.allocator, .{ .workspace = "ws" }, "other.png", png);
    const shown = try display(
        std.testing.allocator,
        tmp.dir,
        io,
        "ws",
        "look at shot.png other.png and https://news.ycombinator.com",
    );
    defer std.testing.allocator.free(shown);
    try std.testing.expectEqualStrings("look at [Image 1] [Image 2] and [URL 1]", shown);
}

test "display image url is Image not URL" {
    const shown = try display(
        std.testing.allocator,
        Io.Dir.cwd(),
        std.testing.io,
        "ws",
        "https://cdn.example/a.png https://example.com",
    );
    defer std.testing.allocator.free(shown);
    try std.testing.expectEqualStrings("[Image 1] [URL 1]", shown);
}
