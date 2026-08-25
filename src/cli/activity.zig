//! What the agent is doing right now, in words, while it does it.
//!
//! The status row above the composer and the terminal tab title render the
//! same headline from the same frame. The words come from the model: a few
//! tokens on the `activity` argument of the tool in flight. The harness does
//! not invent "Generating" or "Reading". When the model has not named the
//! work yet, the fallback is the tool it already chose (`Preparing read...`)
//! or `Waiting for response...` while the stream is quiet.

const std = @import("std");

const Tool = @import("../core/tool.zig");
const paint = @import("../core/ansi.zig");

/// Elapsed is only shown once a turn has lasted long enough for its absence to
/// be a question. Below this, the number is noise that changes every frame.
pub const show_after_ms: i64 = 1_500;

/// One braille step. 10 glyphs × 80ms is 12.5 Hz, a revolution in 800ms.
/// Paint count must not drive this: a token flood would spin it like a fan.
pub const spin_ms: i64 = 80;

/// Braille spinner frames for the tab title. One array, shared by both surfaces.
pub const glyphs = [_][]const u8{ "\u{280b}", "\u{2819}", "\u{2839}", "\u{2838}", "\u{283c}", "\u{2834}", "\u{2826}", "\u{2827}", "\u{2807}", "\u{280f}" };

pub fn glyph(frame: usize) []const u8 {
    return glyphs[frame % glyphs.len];
}

comptime {
    if (spin_ms <= 0) @compileError("spin_ms must advance the spinner");
    if (spin_ms * std.time.ns_per_ms >= std.time.ns_per_s)
        @compileError("spin_ms must fit in timespec.nsec");
}

pub fn frameOf(elapsed_ms: i64) usize {
    if (elapsed_ms <= 0) return 0;
    return @intCast(@divTrunc(elapsed_ms, spin_ms));
}

/// A phrase is built into a caller buffer, never allocated: the status line is
/// repainted on every frame and must not churn the allocator.
pub const max_phrase: usize = 120;

comptime {
    if (max_phrase < 32) @compileError("max_phrase must hold a verb and a subject");
}

/// Deliberately about the *work*, not the tool name: a user watching this wants
/// to know the agent is compiling, not that a function called `bash` was
/// entered.
fn running(name: Tool.Name, detail: []const u8) []const u8 {
    return switch (name) {
        .read, .open_file => "Reading",
        .file_info => "Checking",
        .write => "Writing",
        .edit, .patch => "Editing",
        .bash => bashVerb(detail),
        .glob, .grep => "Searching",
        .semantic_search => "Searching",
        .list => "Listing",
        .web_fetch => "Fetching",
        .web_scrape => "Scraping",
        .web_search => "Searching the web",
        .mcp => "Calling",
        .memory => "Remembering",
        .copy, .mkdir, .delete, .rename => "Changing files",
        .ask_user => "Waiting for you",
        .browser => "Browsing",
        .peer => "Delegating",
        .board => "Posting",
        .compact => "Compacting",
        .todo => "Planning",
        .job => "Checking a job",
        .read_result => "Re-reading a result",
    };
}

fn ran(name: Tool.Name, detail: []const u8) []const u8 {
    return switch (name) {
        .read, .open_file => "Read",
        .file_info => "Checked",
        .write => "Wrote",
        .edit, .patch => "Edited",
        .bash => bashPast(detail),
        .glob, .grep, .semantic_search => "Searched",
        .list => "Listed",
        .web_fetch => "Fetched",
        .web_scrape => "Scraped",
        .web_search => "Searched the web",
        .mcp => "Called",
        .memory => "Remembered",
        .copy, .mkdir, .delete, .rename => "Changed files",
        .ask_user => "Asked",
        .browser => "Browsed",
        .peer => "Delegated",
        .board => "Posted",
        .compact => "Compacted",
        .todo => "Planned",
        .job => "Checked a job",
        .read_result => "Re-read a result",
    };
}

/// A shell command is the one tool whose argument says more than its name.
/// `zig build test` is a test run, not "running a command", and a user who sees
/// the wrong word here will not trust any of the others.
fn bashVerb(command: []const u8) []const u8 {
    const c = std.mem.trimStart(u8, command, " \t");
    if (hasAny(c, &.{ "build test", "cargo test", "go test", "pytest", "npm test", "yarn test", "pnpm test", "bun test", "rspec", "jest", "vitest" })) {
        return "Running the test suite";
    }
    if (hasAny(c, &.{ "cargo check", "tsc ", "--noEmit", "compileall", "ast-check", "node --check" })) return "Type-checking";
    if (hasAny(c, &.{ "zig build", "cargo build", "go build", "make ", "npm run build", "cmake" })) return "Building";
    if (std.mem.startsWith(u8, c, "git ")) return "Running git";
    if (hasAny(c, &.{ "npm install", "yarn install", "pnpm install", "pip install", "cargo add", "bun install" })) return "Installing packages";
    if (hasAny(c, &.{ "fmt", "prettier", "black ", "gofmt" })) return "Formatting";
    return "Running a command";
}

/// The generic shell verb, counted. "Ran a command 4 commands" is what you get
/// from bolting a plural onto a phrase that already contains its own article;
/// a run of unrecognised commands needs its own wording.
fn bashRunPhrase(buf: []u8, command: []const u8, count: usize, past: bool) ?[]const u8 {
    const generic = std.mem.eql(u8, bashVerb(command), "Running a command");
    if (!generic or count < 2) return null;
    var w: usize = 0;
    w += copy(buf[w..], if (past) "Ran " else "Running ");
    w += num(buf[w..], count);
    w += copy(buf[w..], " shell commands");
    return buf[0..w];
}

fn bashPast(command: []const u8) []const u8 {
    const v = bashVerb(command);
    if (std.mem.eql(u8, v, "Running the test suite")) return "Ran the test suite";
    if (std.mem.eql(u8, v, "Type-checking")) return "Type-checked";
    if (std.mem.eql(u8, v, "Building")) return "Built";
    if (std.mem.eql(u8, v, "Running git")) return "Ran git";
    if (std.mem.eql(u8, v, "Installing packages")) return "Installed packages";
    if (std.mem.eql(u8, v, "Formatting")) return "Formatted";
    return "Ran a command";
}

fn hasAny(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, hay, n) != null) return true;
    }
    return false;
}

/// What the agent is doing, as one line.
///
/// `label` is the model's `activity` argument, a few words it already spent
/// tokens on. `tool_name` is the function it called. `count` collapses repeats
/// (`Preparing read (3)...`). `elapsed_ms` is the whole turn.
pub const State = struct {
    label: []const u8 = "",
    tool_name: []const u8 = "",
    tool: ?Tool.Name = null,
    count: usize = 1,
    elapsed_ms: i64 = 0,
    /// True once assistant text has started. "Waiting for response" is a lie
    /// after that: the response is already on screen.
    streaming: bool = false,
    /// Real token count from the provider, never an estimate. Zero until the
    /// wire reports one, so a provider that sends no usage shows nothing
    /// rather than a made-up number.
    tokens: u32 = 0,
    /// The prompt split the way the provider bills it: what it processed
    /// fresh, what it served from cache, and what it stored on the way.
    fresh_input: u32 = 0,
    cache_read: u32 = 0,
    cache_write: u32 = 0,
};

fn tokenText(buf: []u8, n: u32) []const u8 {
    if (n < 1000) return buf[0..num(buf, n)];
    var w: usize = num(buf, n / 1000);
    // A tenth stays meaningful well past ten thousand -- 35.7k is the number
    // people quote. Only past a hundred thousand is it noise.
    if (n < 100_000) {
        const tenth = (n % 1000) / 100;
        if (tenth != 0) {
            w += copy(buf[w..], ".");
            w += num(buf[w..], tenth);
        }
    }
    w += copy(buf[w..], "k");
    return buf[0..w];
}

/// Plural subject for a repeated tool, or empty when one line reads better.
///
/// A verb that already names the work does not take a count: "Running the test
/// suite 2 commands" is worse than "Running the test suite". Only the generic
/// shell verb pluralizes, because only it is ambiguous about what ran.
fn subject(name: Tool.Name, detail: []const u8, count: usize) []const u8 {
    if (count < 2) return "";
    if (name == .bash and !std.mem.eql(u8, bashVerb(detail), "Running a command")) return "";
    return switch (name) {
        .read, .open_file, .file_info => "files",
        .write => "files",
        .edit, .patch => "edits",
        .bash => "commands",
        .glob, .grep, .semantic_search => "searches",
        .web_fetch, .web_scrape, .web_search => "pages",
        .mcp => "tools",
        else => "steps",
    };
}

/// The words both the status row and the tab title show. No elapsed, no tokens:
/// those live on the in-app line only so the tab stays a short match.
pub fn headline(buf: []u8, s: State) []const u8 {
    var w: usize = 0;
    if (s.label.len != 0) {
        w += copy(buf[w..], s.label);
        w += countSuffix(buf[w..], s.count);
        return buf[0..w];
    }
    const name = if (s.tool_name.len != 0) s.tool_name else if (s.tool) |t| t.asSlice() else "";
    if (name.len != 0) {
        if (std.mem.eql(u8, name, "compact")) return buf[0..copy(buf, "Compacting...")];
        w += copy(buf[w..], "Preparing ");
        w += copy(buf[w..], name);
        w += countSuffix(buf[w..], s.count);
        w += copy(buf[w..], "...");
        return buf[0..w];
    }
    if (s.streaming) return buf[0..0];
    return buf[0..copy(buf, "Waiting for response...")];
}

fn countSuffix(buf: []u8, count: usize) usize {
    if (count < 2) return 0;
    var w: usize = 0;
    w += copy(buf[w..], " (");
    w += num(buf[w..], count);
    w += copy(buf[w..], ")");
    return w;
}

/// Elapsed and tokens stay off the tab so it matches the in-app words.
pub fn phrase(buf: []u8, s: State) []const u8 {
    var w: usize = 0;
    var head: [max_phrase]u8 = undefined;
    w += copy(buf[w..], headline(&head, s));
    w += tail(buf[w..], s, w != 0);
    return buf[0..w];
}

/// Elapsed and tokens, the two numbers a waiting user is asking about.
fn tail(buf: []u8, s: State, after_text: bool) usize {
    var w: usize = 0;
    var need_sep = after_text;
    if (s.elapsed_ms >= show_after_ms) {
        if (need_sep) w += copy(buf[w..], " \u{00b7} ");
        need_sep = true;
        w += num(buf[w..], @intCast(@divTrunc(s.elapsed_ms, 1000)));
        w += copy(buf[w..], "s");
    }
    if (s.tokens > 0) {
        var tok: [16]u8 = undefined;
        if (need_sep) w += copy(buf[w..], " \u{00b7} ");
        w += copy(buf[w..], "\u{2193} ");
        w += copy(buf[w..], tokenText(&tok, s.tokens));
        w += copy(buf[w..], " tokens");
    }
    return w;
}

/// Past-tense line for a finished tool, used by the transcript card.
pub fn pastPhrase(buf: []u8, name: Tool.Name, detail: []const u8, count: usize) []const u8 {
    if (name == .bash) {
        var run_buf: [64]u8 = undefined;
        if (bashRunPhrase(&run_buf, detail, count, true)) |p| return buf[0..copy(buf, p)];
    }
    var w: usize = 0;
    w += copy(buf[w..], ran(name, detail));
    const plural = subject(name, detail, count);
    if (plural.len != 0) {
        w += copy(buf[w..], " ");
        w += num(buf[w..], count);
        w += copy(buf[w..], " ");
        w += copy(buf[w..], plural);
    }
    return buf[0..w];
}

fn copy(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

fn num(dst: []u8, v: usize) usize {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return 0;
    return copy(dst, s);
}

pub fn line(buf: []u8, s: State, frame: usize) []const u8 {
    var w: usize = 0;
    w += copy(buf[w..], paint.accent_dim);
    w += copy(buf[w..], glyph(frame));
    w += copy(buf[w..], paint.reset);
    w += copy(buf[w..], " ");
    w += copy(buf[w..], paint.muted);
    var body: [max_phrase]u8 = undefined;
    w += copy(buf[w..], phrase(&body, s));
    w += copy(buf[w..], paint.reset);
    return buf[0..w];
}

test "the model's activity argument is the headline" {
    var buf: [max_phrase]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Format spinner-related files",
        headline(&buf, .{ .label = "Format spinner-related files", .tool_name = "bash" }),
    );
    try std.testing.expectEqualStrings(
        "Format spinner-related files \u{00b7} 8s",
        phrase(&buf, .{ .label = "Format spinner-related files", .tool_name = "bash", .elapsed_ms = 8_000 }),
    );
    try std.testing.expectEqualStrings("Preparing edit...", headline(&buf, .{ .tool_name = "edit" }));
}

test "a real token count is shown, and nothing when there is none" {
    var buf: [max_phrase]u8 = undefined;
    try std.testing.expectEqualStrings("Waiting for response...", phrase(&buf, .{}));
    try std.testing.expectEqualStrings(
        "Waiting for response... \u{00b7} \u{2193} 850 tokens",
        phrase(&buf, .{ .tokens = 850 }),
    );
    try std.testing.expectEqualStrings(
        "Waiting for response... \u{00b7} 4s \u{00b7} \u{2193} 10.3k tokens",
        phrase(&buf, .{ .tokens = 10_300, .elapsed_ms = 4_000 }),
    );
}

test "token counts read compactly" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0", tokenText(&buf, 0));
    try std.testing.expectEqualStrings("999", tokenText(&buf, 999));
    try std.testing.expectEqualStrings("1k", tokenText(&buf, 1000));
    try std.testing.expectEqualStrings("1.2k", tokenText(&buf, 1234));
    try std.testing.expectEqualStrings("35.7k", tokenText(&buf, 35_700));
    try std.testing.expectEqualStrings("128k", tokenText(&buf, 128_400));
}

test "an idle turn still says something" {
    var buf: [max_phrase]u8 = undefined;
    try std.testing.expectEqualStrings("Waiting for response...", headline(&buf, .{}));
}

test "streaming text is not waiting for a response" {
    var buf: [max_phrase]u8 = undefined;
    try std.testing.expectEqualStrings("", headline(&buf, .{ .streaming = true }));
    try std.testing.expectEqualStrings(
        "4s \u{00b7} \u{2193} 850 tokens",
        phrase(&buf, .{ .streaming = true, .elapsed_ms = 4_000, .tokens = 850 }),
    );
    try std.testing.expectEqualStrings(
        "Preparing read...",
        headline(&buf, .{ .streaming = true, .tool_name = "read" }),
    );
}

test "a tool in flight uses the name the model chose" {
    var buf: [max_phrase]u8 = undefined;
    try std.testing.expectEqualStrings("Preparing read...", headline(&buf, .{ .tool_name = "read" }));
    try std.testing.expectEqualStrings("Preparing edit...", headline(&buf, .{ .tool_name = "edit" }));
    try std.testing.expectEqualStrings("Preparing grep...", headline(&buf, .{ .tool_name = "grep" }));
    try std.testing.expectEqualStrings("Compacting...", headline(&buf, .{ .tool_name = "compact" }));
}

test "repeats collapse into a count" {
    var buf: [max_phrase]u8 = undefined;
    try std.testing.expectEqualStrings("Preparing read (3)...", headline(&buf, .{ .tool_name = "read", .count = 3 }));
    try std.testing.expectEqualStrings("Preparing read...", headline(&buf, .{ .tool_name = "read", .count = 1 }));
    try std.testing.expectEqualStrings(
        "Format files (2)",
        headline(&buf, .{ .label = "Format files", .count = 2 }),
    );
}

test "elapsed appears only once it is worth reading" {
    var buf: [max_phrase]u8 = undefined;
    try std.testing.expectEqualStrings("Preparing read...", phrase(&buf, .{ .tool_name = "read", .elapsed_ms = 400 }));
    try std.testing.expectEqualStrings(
        "Preparing read... \u{00b7} 10s",
        phrase(&buf, .{ .tool_name = "read", .elapsed_ms = 10_000 }),
    );
}

test "tab headline matches the in-app words" {
    var a: [max_phrase]u8 = undefined;
    var b: [max_phrase]u8 = undefined;
    const s = State{ .tool_name = "read", .count = 3, .elapsed_ms = 5_000, .tokens = 1200 };
    try std.testing.expectEqualStrings("Preparing read (3)...", headline(&a, s));
    try std.testing.expect(std.mem.startsWith(u8, phrase(&b, s), "Preparing read (3)..."));
    try std.testing.expect(std.mem.indexOf(u8, phrase(&b, s), "tokens") != null);
    try std.testing.expect(std.mem.indexOf(u8, headline(&a, s), "tokens") == null);
}

test "past tense matches the present tense it followed" {
    var buf: [max_phrase]u8 = undefined;
    try std.testing.expectEqualStrings("Ran the test suite", pastPhrase(&buf, .bash, "zig build test", 1));
    try std.testing.expectEqualStrings("Built", pastPhrase(&buf, .bash, "zig build", 1));
    try std.testing.expectEqualStrings("Read 3 files", pastPhrase(&buf, .read, "", 3));
    try std.testing.expectEqualStrings("Ran a command", pastPhrase(&buf, .bash, "./x", 1));
    try std.testing.expectEqualStrings("Ran 4 shell commands", pastPhrase(&buf, .bash, "./x", 4));
}

test "every tool has a verb in both tenses" {
    var buf: [max_phrase]u8 = undefined;
    // An unhandled tool would render as an empty line, which reads as a hang.
    inline for (std.meta.tags(Tool.Name)) |t| {
        try std.testing.expect(running(t, "").len > 0);
        try std.testing.expect(ran(t, "").len > 0);
        try std.testing.expect(phrase(&buf, .{ .tool = t }).len > 0);
    }
}

test "spinner frame follows elapsed time, not paint count" {
    try std.testing.expectEqual(@as(usize, 0), frameOf(0));
    try std.testing.expectEqual(@as(usize, 0), frameOf(spin_ms - 1));
    try std.testing.expectEqual(@as(usize, 1), frameOf(spin_ms));
    try std.testing.expectEqual(@as(usize, 2), frameOf(spin_ms * 2));
    var a_buf: [max_phrase * 2]u8 = undefined;
    var b_buf: [max_phrase * 2]u8 = undefined;
    const a = line(&a_buf, .{ .elapsed_ms = 0 }, frameOf(0));
    const same = line(&b_buf, .{ .elapsed_ms = 0 }, frameOf(0));
    try std.testing.expectEqualStrings(a, same);
    var c_buf: [max_phrase * 2]u8 = undefined;
    const c = line(&c_buf, .{ .elapsed_ms = spin_ms }, frameOf(spin_ms));
    try std.testing.expect(!std.mem.eql(u8, a, c));
    try std.testing.expectEqualStrings(glyph(0), glyphs[0]);
    try std.testing.expect(std.mem.indexOf(u8, a, glyph(0)) != null);
}

test "the line spins and never overruns its buffer" {
    var buf: [max_phrase * 2]u8 = undefined;
    for (0..10) |i| {
        const s = line(&buf, .{ .label = "Format files", .elapsed_ms = 3_000 }, i);
        try std.testing.expect(s.len <= buf.len);
        try std.testing.expect(std.mem.indexOf(u8, s, "Format files") != null);
        try std.testing.expect(std.mem.indexOf(u8, s, glyph(i)) != null);
    }
    var b2: [max_phrase * 2]u8 = undefined;
    const a = line(&buf, .{ .tool_name = "read" }, 0);
    const b = line(&b2, .{ .tool_name = "read" }, 1);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "a long detail cannot overflow the phrase buffer" {
    var small: [16]u8 = undefined;
    const s = phrase(&small, .{ .tool_name = "bash", .elapsed_ms = 99_000 });
    try std.testing.expect(s.len <= small.len);
}
