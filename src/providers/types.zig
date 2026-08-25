const std = @import("std");
const ids = @import("../core/ids.zig");

pub const Event = union(enum) {
    text: []const u8,
    tool_call: ToolCall,
    done,
    err: ProviderError,
};

pub const ToolCall = struct {
    id: ids.ToolCallId,
    name: []const u8,
    arguments_json: []const u8,
};

pub const OAuth = struct {
    access: []const u8,
    refresh: []const u8,
    expires_at: i64 = 0,
    token_endpoint: []const u8 = "",

    pub fn stale(self: OAuth, now: i64) bool {
        return self.expires_at != 0 and now >= self.expires_at;
    }

    pub fn keepRefresh(self: OAuth, new_refresh: []const u8) []const u8 {
        return if (new_refresh.len > 0) new_refresh else self.refresh;
    }
};

pub const Credential = union(enum) {
    api_key: []const u8,
    oauth: OAuth,

    pub const Kind = enum { oauth, api_key };

    pub fn kind(self: Credential) Kind {
        return switch (self) {
            .oauth => .oauth,
            .api_key => .api_key,
        };
    }

    pub fn token(self: Credential) []const u8 {
        return switch (self) {
            .api_key => |k| k,
            .oauth => |o| o.access,
        };
    }
};

test "oauth stale uses expires_at" {
    const fresh = OAuth{ .access = "a", .refresh = "r", .expires_at = 100 };
    try std.testing.expect(!fresh.stale(99));
    try std.testing.expect(fresh.stale(100));
    try std.testing.expectEqualStrings("old", (OAuth{ .access = "a", .refresh = "old" }).keepRefresh(""));
    try std.testing.expectEqualStrings("new", (OAuth{ .access = "a", .refresh = "old" }).keepRefresh("new"));
}

pub const ChatOutcome = union(enum) {
    text: []u8,
    tool: struct {
        preamble: []u8,
        name: []u8,
        args: []u8,
    },

    pub fn deinit(self: ChatOutcome, allocator: std.mem.Allocator) void {
        switch (self) {
            .text => |t| allocator.free(t),
            .tool => |t| {
                allocator.free(t.preamble);
                allocator.free(t.name);
                allocator.free(t.args);
            },
        }
    }

    pub fn textSlice(self: ChatOutcome) []const u8 {
        return switch (self) {
            .text => |t| t,
            .tool => |t| t.preamble,
        };
    }
};

pub const ProviderError = struct {
    kind: Kind,
    vendor: []const u8,
    message: []const u8,
    status: ?u16 = null,

    pub const Kind = enum {
        authentication,
        rate_limited,
        unavailable,
        protocol,
    };
};

pub const Protocol = enum {
    openai_compat,
    anthropic,
    openai_responses,
};

pub const Vendor = enum {
    openai,
    anthropic,
    google,
    xai,
    custom,

    pub fn protocol(self: Vendor) Protocol {
        return switch (self) {
            .anthropic => .anthropic,
            .openai, .google, .xai, .custom => .openai_compat,
        };
    }

    pub fn envKey(self: Vendor) ?[]const u8 {
        return switch (self) {
            .openai => "OPENAI_API_KEY",
            .anthropic => "ANTHROPIC_API_KEY",
            .google => "GEMINI_API_KEY",
            .xai => "XAI_API_KEY",
            .custom => null,
        };
    }

    pub fn defaultBaseUrl(self: Vendor) []const u8 {
        return switch (self) {
            .openai => "https://api.openai.com/v1",
            .anthropic => "https://api.anthropic.com",
            .google => "https://generativelanguage.googleapis.com/v1beta/openai",
            .xai => "https://api.x.ai/v1",
            .custom => "",
        };
    }

    pub fn asSlice(self: Vendor) []const u8 {
        return switch (self) {
            .openai => "openai",
            .anthropic => "anthropic",
            .google => "google",
            .xai => "xai",
            .custom => "custom",
        };
    }
};

pub const Endpoint = struct {
    id: []const u8 = "",
    vendor: Vendor,
    protocol: Protocol = .openai_compat,
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    /// Empty = protocol default path.
    path: []const u8 = "",
    /// Empty or "none" omits reasoning_effort. Changing this must not change `model`.
    effort: []const u8 = "",
    max_output_tokens: u32 = 1024,
    context_window: u32 = 0,
};

pub fn classifyHttpStatus(status: u16) ProviderError.Kind {
    return switch (status) {
        401, 403 => .authentication,
        429 => .rate_limited,
        else => .unavailable,
    };
}

test "vendor protocol mapping" {
    try std.testing.expectEqual(Protocol.openai_compat, Vendor.openai.protocol());
    try std.testing.expectEqual(Protocol.anthropic, Vendor.anthropic.protocol());
    try std.testing.expectEqual(Protocol.openai_compat, Vendor.google.protocol());
    try std.testing.expectEqual(Protocol.openai_compat, Vendor.xai.protocol());
}

test "401 is authentication" {
    try std.testing.expectEqual(ProviderError.Kind.authentication, classifyHttpStatus(401));
    try std.testing.expectEqual(ProviderError.Kind.rate_limited, classifyHttpStatus(429));
}

pub const Mime = enum {
    png,
    jpeg,
    gif,
    webp,
    bmp,

    pub fn fromExt(ext: []const u8) ?Mime {
        if (std.ascii.eqlIgnoreCase(ext, ".png")) return .png;
        if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return .jpeg;
        if (std.ascii.eqlIgnoreCase(ext, ".gif")) return .gif;
        if (std.ascii.eqlIgnoreCase(ext, ".webp")) return .webp;
        if (std.ascii.eqlIgnoreCase(ext, ".bmp")) return .bmp;
        return null;
    }

    pub fn asSlice(self: Mime) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .gif => "image/gif",
            .webp => "image/webp",
            .bmp => "image/bmp",
        };
    }
};

pub const Image = union(enum) {
    file: struct { mime: Mime, b64: []const u8 },
    url: []const u8,
};

pub const Channel = enum { text, think };

/// HTTP-side stream callbacks. Ask/tool chrome stays on `sink.Host`.
pub const Stream = struct {
    ctx: ?*anyopaque = null,
    on_text: ?*const fn (ctx: ?*anyopaque, chunk: []const u8) void = null,
    on_think: ?*const fn (ctx: ?*anyopaque, chunk: []const u8) void = null,
    /// `read` and `write` stay apart because the useful number is the share of
    /// the prompt that came from cache, and a write is the opposite of that:
    /// it is the part that had to be processed fresh and then stored.
    on_usage: ?*const fn (ctx: ?*anyopaque, input: u32, output: u32, read: u32, write: u32) void = null,
    on_tick: ?*const fn (ctx: ?*anyopaque) void = null,
    cancel: ?*std.atomic.Value(bool) = null,
    poll_key: ?*const fn () bool = null,
    /// Transcript pane height for PageUp/Down while a turn owns stdin.
    page_rows: u16 = 20,

    pub fn cancelled(self: Stream) bool {
        return if (self.cancel) |c| c.load(.acquire) else false;
    }

    pub fn push(self: Stream, channel: Channel, chunk: []const u8) void {
        if (chunk.len == 0) return;
        switch (channel) {
            .text => if (self.on_text) |f| f(self.ctx, chunk),
            .think => if (self.on_think) |f| f(self.ctx, chunk),
        }
    }

    pub fn text(self: Stream, chunk: []const u8) void {
        self.push(.text, chunk);
    }

    pub fn think(self: Stream, chunk: []const u8) void {
        self.push(.think, chunk);
    }

    pub fn usage(self: Stream, input: u32, output: u32, read: u32, write: u32) void {
        if (self.on_usage) |f| f(self.ctx, input, output, read, write);
    }

    pub fn pollCancel(self: Stream) void {
        const flag = self.cancel orelse return;
        if (self.poll_key) |f| {
            if (f()) flag.store(true, .release);
        }
    }
};
