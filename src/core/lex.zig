const std = @import("std");
const langs = @import("langs.zig");
const Lang = langs.Lang;

/// A delimiter scan driven by `langs.table`, shared by the edit gate and the
/// repo map.
///
/// This is not a parser and does not pretend to be one. It knows where
/// comments and strings are so that brackets inside them do not count, which
/// is exactly enough to catch the failure that matters: an edit that truncated
/// a file or left a block unclosed.
/// Deeper than any real source nests. Reaching it means the scan lost track,
/// so the verdict becomes inconclusive rather than a complaint.
/// Receipt: the deepest nesting in this repo is 11 (src/core/settings.zig).
pub const max_depth: usize = 256;

pub const Complaint = struct {
    line: u32,
    /// The delimiter at fault.
    delim: u8,
    /// What went wrong, already a sentence fragment for the caller to print.
    what: []const u8,
};

/// `inconclusive` is a real answer and the common one on exotic syntax: it
/// means the scan does not know, so the caller must not block on it. Silence
/// beats a false accusation, because a false accusation rejects a good edit.
pub const Verdict = union(enum) {
    ok,
    inconclusive,
    broken: Complaint,
};

const State = enum { code, line_comment, block_comment, string, triple, line_string };

fn closerFor(open: u8) u8 {
    return switch (open) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        else => 0,
    };
}

fn starts(src: []const u8, i: usize, needle: []const u8) bool {
    if (needle.len == 0) return false;
    return std.mem.startsWith(u8, src[i..], needle);
}

/// A character literal, not a string: `'x'`, `'\n'`, `'\u{1F600}'`.
///
/// Anything looser swallows Rust lifetimes (`&'a str`) and reads the rest of
/// the file as one long string, which is how a scan that means to help ends up
/// rejecting correct code.
fn charLit(src: []const u8, i: usize) ?usize {
    if (i + 2 < src.len and src[i + 2] == '\'') return i + 2;
    if (i + 1 < src.len and src[i + 1] == '\\') {
        var j = i + 2;
        const stop = @min(src.len, i + 12);
        while (j < stop) : (j += 1) {
            if (src[j] == '\n') return null;
            if (src[j] == '\'') return j;
        }
    }
    return null;
}

/// Where a Rust raw string's body begins, and how many `#` close it.
///
/// `r"..."`, `r#"..."#`, `br##"..."##`. Everything between is text, so a `{`
/// in there closes nothing.
fn rawStart(src: []const u8, i: usize) ?struct { body: usize, hashes: usize } {
    var j = i;
    if (src[j] == 'b') j += 1;
    if (j >= src.len or src[j] != 'r') return null;
    j += 1;
    var h: usize = 0;
    while (j < src.len and src[j] == '#') : (j += 1) h += 1;
    if (j >= src.len or src[j] != '"') return null;
    return .{ .body = j + 1, .hashes = h };
}

/// The index just past the closing `"###`, or null when it never closes.
fn rawEnd(src: []const u8, body: usize, hashes: usize) ?usize {
    var j = body;
    while (std.mem.indexOfScalarPos(u8, src, j, '"')) |q| {
        var k = q + 1;
        var seen: usize = 0;
        while (k < src.len and src[k] == '#' and seen < hashes) : (k += 1) seen += 1;
        if (seen == hashes) return k;
        j = q + 1;
    }
    return null;
}

fn countNewlines(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// Whether `src` closes every bracket it opens.
pub fn balance(l: *const Lang, src: []const u8) Verdict {
    if (!l.balance) return .inconclusive;

    var stack: [max_depth]struct { ch: u8, line: u32 } = undefined;
    var depth: usize = 0;
    var state: State = .code;
    var quote: u8 = 0;
    var line: u32 = 1;
    var i: usize = 0;

    while (i < src.len) {
        const c = src[i];
        if (c == '\n') {
            line += 1;
            if (state == .line_comment or state == .line_string) state = .code;
            i += 1;
            continue;
        }
        switch (state) {
            .line_comment, .line_string => i += 1,
            .block_comment => {
                if (starts(src, i, l.bclose)) {
                    state = .code;
                    i += l.bclose.len;
                } else i += 1;
            },
            .string => {
                if (c == '\\' and i + 1 < src.len) {
                    i += 2;
                } else if (c == quote) {
                    state = .code;
                    i += 1;
                } else i += 1;
            },
            .triple => {
                if (i + 2 < src.len and src[i] == quote and src[i + 1] == quote and src[i + 2] == quote) {
                    state = .code;
                    i += 3;
                } else i += 1;
            },
            .code => {
                if (starts(src, i, l.line)) {
                    state = .line_comment;
                    i += l.line.len;
                    continue;
                }
                if (starts(src, i, l.line2)) {
                    state = .line_comment;
                    i += l.line2.len;
                    continue;
                }
                if (starts(src, i, l.line_string)) {
                    state = .line_string;
                    i += l.line_string.len;
                    continue;
                }
                if (starts(src, i, l.bopen)) {
                    state = .block_comment;
                    i += l.bopen.len;
                    continue;
                }
                if (l.raw_string and (c == 'r' or c == 'b') and
                    (i == 0 or !isWordByte(src[i - 1])))
                {
                    if (rawStart(src, i)) |st| {
                        const end = rawEnd(src, st.body, st.hashes) orelse return .inconclusive;
                        line += countNewlines(src[i..end]);
                        i = end;
                        continue;
                    }
                }
                if (l.char_lit and c == '\'') {
                    if (charLit(src, i)) |end| {
                        i = end + 1;
                    } else i += 1;
                    continue;
                }
                if (std.mem.indexOfScalar(u8, l.quotes, c) != null) {
                    if (l.triple and i + 2 < src.len and src[i + 1] == c and src[i + 2] == c) {
                        state = .triple;
                        quote = c;
                        i += 3;
                    } else {
                        state = .string;
                        quote = c;
                        i += 1;
                    }
                    continue;
                }
                switch (c) {
                    '(', '[', '{' => {
                        if (depth == max_depth) return .inconclusive;
                        stack[depth] = .{ .ch = c, .line = line };
                        depth += 1;
                    },
                    ')', ']', '}' => {
                        if (depth == 0) return .{ .broken = .{
                            .line = line,
                            .delim = c,
                            .what = "closes nothing",
                        } };
                        depth -= 1;
                        if (closerFor(stack[depth].ch) != c) return .{ .broken = .{
                            .line = line,
                            .delim = c,
                            .what = "does not match the opener",
                        } };
                    },
                    else => {},
                }
                i += 1;
            },
        }
    }

    // Ending mid-string or mid-comment means the scan lost the thread, most
    // often on syntax it does not model. That is not evidence of a broken file.
    if (state == .string or state == .triple or state == .block_comment) return .inconclusive;
    if (depth > 0) return .{ .broken = .{
        .line = stack[depth - 1].line,
        .delim = stack[depth - 1].ch,
        .what = "is never closed",
    } };
    return .ok;
}

/// Keywords that introduce something worth putting in a repo map. `const` and
/// `let` are not among them: most of what they bind is a local or an import,
/// and a map full of `const std = @import("std")` describes nothing.
const strong_heads = [_][]const u8{
    "fn",        "func",      "function", "fun",   "def",    "class",     "struct",   "enum",
    "trait",     "interface", "impl",     "type",  "module", "defmodule", "protocol", "record",
    "namespace", "data",      "newtype",  "union", "sub",    "object",    "actor",    "extension",
    "component", "resource",  "abstract",
};

const skip_heads = [_][]const u8{
    "if", "for", "while", "switch", "return", "catch", "else", "do", "match", "case", "with",
};

const decl_heads = [_][]const u8{
    "pub",      "export",    "public",    "private",   "async",  "fn",        "func",      "fun",
    "function", "def",       "class",     "struct",    "enum",   "interface", "trait",     "impl",
    "type",     "module",    "defmodule", "package",   "object", "protocol",  "extension", "actor",
    "record",   "namespace", "data",      "newtype",   "union",  "sub",       "const",     "let",
    "var",      "val",       "resource",  "component",
};

fn identAt(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '$';
        if (!ok) break;
    }
    return s[0..i];
}

fn word(s: []const u8) []const u8 {
    return identAt(std.mem.trimStart(u8, s, " \t"));
}

/// The name a declaration line declares, or null when the line declares
/// nothing.
///
/// Keyword-led forms first, then the C-family shape (`int main(void) {`) for
/// the languages that need it. Both are heuristics; the repo map they feed is
/// an orientation aid, and a wrong entry there costs a line of budget, not
/// correctness.
pub const Decl = struct {
    name: []const u8,
    /// The keyword that introduced it, for callers that show an outline.
    kind: []const u8,
    /// A definition (a function, a type) rather than a binding. The repo map
    /// spends its lines on these first.
    strong: bool,
};

fn hasWord(t: []const u8, w: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, t, i, w)) |at| {
        i = at + w.len;
        const before_ok = at == 0 or !isWordByte(t[at - 1]);
        const after_ok = i >= t.len or !isWordByte(t[i]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn isWordByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_' or c == '$';
}

/// An import is not a declaration. It names a module the file depends on, and
/// listing those in a repo map spends the budget restating the include block.
fn isImport(t: []const u8) bool {
    if (std.mem.startsWith(u8, t, "import ") or std.mem.startsWith(u8, t, "from ")) return true;
    if (std.mem.startsWith(u8, t, "use ") or std.mem.startsWith(u8, t, "require ")) return true;
    if (std.mem.startsWith(u8, t, "#include")) return true;
    return std.mem.indexOf(u8, t, "@import(") != null or
        std.mem.indexOf(u8, t, "require(") != null;
}

pub fn decl(l: *const Lang, raw: []const u8) ?Decl {
    const t = std.mem.trim(u8, raw, " \t\r");
    if (t.len == 0) return null;
    if (l.line.len > 0 and starts(t, 0, l.line)) return null;
    if (l.line2.len > 0 and starts(t, 0, l.line2)) return null;
    if (l.bopen.len > 0 and starts(t, 0, l.bopen)) return null;
    if (t[0] == '*' or t[0] == '@' or t[0] == '#') return null;

    if (isImport(t)) return null;
    // A line ending in a comma is an item in a list -- the middle of a
    // multi-line `import { type A, type B }` reads as a `type` declaration
    // otherwise, and fills a repo map with fragments of import blocks.
    if (t[t.len - 1] == ',') return null;

    const first = word(t);
    if (first.len == 0) return null;
    for (skip_heads) |s| {
        if (std.mem.eql(u8, first, s)) return null;
    }

    // The C-family shape is checked first because its keywords overlap:
    // `struct node *parse(char *s);` opens with `struct` but declares a
    // function, and the keyword walk below would answer `node`.
    if (l.cstyle) {
        if (cstyleName(t)) |n| return .{ .name = n, .kind = "fn", .strong = true };
    }
    const name = keywordName(t) orelse return null;
    var kind: []const u8 = first;
    var strong = false;
    for (strong_heads) |h| {
        if (!hasWord(t, h)) continue;
        if (!strong) kind = h;
        strong = true;
    }
    return .{ .name = name, .kind = kind, .strong = strong };
}

/// `int main(int argc) {` -- no keyword, so the shape is the signal: a
/// call-looking head that opens a body or ends a prototype.
fn cstyleName(t: []const u8) ?[]const u8 {
    const tail = t[t.len - 1];
    if (tail != '{' and tail != ';') return null;
    if (std.mem.indexOfScalar(u8, t, '=') != null) return null;
    const lp = std.mem.indexOfScalar(u8, t, '(') orelse return null;
    const head = std.mem.trimEnd(u8, t[0..lp], " \t");
    if (head.len == 0) return null;
    const sp = std.mem.lastIndexOfAny(u8, head, " \t*&:") orelse return null;
    const name = identAt(head[sp + 1 ..]);
    return if (name.len > 1) name else null;
}

/// `pub fn`, `export class`, `public static` -- modifiers stack, so walk past
/// every keyword. The first word that is not one is the name.
fn keywordName(t: []const u8) ?[]const u8 {
    for (decl_heads) |h| {
        if (!std.mem.startsWith(u8, t, h)) continue;
        const after = t[h.len..];
        if (after.len == 0 or (after[0] != ' ' and after[0] != '\t')) continue;
        var rest = after;
        while (true) {
            const w = word(rest);
            if (w.len == 0) return null;
            var is_kw = false;
            for (decl_heads) |k| {
                if (std.mem.eql(u8, w, k)) is_kw = true;
            }
            if (!is_kw) return if (w.len > 1) w else null;
            const at = std.mem.indexOf(u8, rest, w).? + w.len;
            rest = rest[at..];
        }
    }
    return null;
}

test "balanced source is ok" {
    const zig = langs.byName("zig").?;
    try std.testing.expectEqual(Verdict.ok, balance(zig, "pub fn a() void {\n    _ = .{};\n}\n"));
}

test "a truncated body names the opener line" {
    const zig = langs.byName("zig").?;
    const v = balance(zig, "pub fn a() void {\n    if (x) {\n");
    try std.testing.expectEqual(@as(u32, 2), v.broken.line);
    try std.testing.expectEqual(@as(u8, '{'), v.broken.delim);
}

test "a stray closer is caught" {
    const zig = langs.byName("zig").?;
    const v = balance(zig, "const a = 1;\n}\n");
    try std.testing.expectEqualStrings("closes nothing", v.broken.what);
}

test "brackets in comments and strings do not count" {
    const zig = langs.byName("zig").?;
    try std.testing.expectEqual(Verdict.ok, balance(zig, "// {\nconst s = \"}}}\";\n"));
    const py = langs.byName("python").?;
    try std.testing.expectEqual(Verdict.ok, balance(py, "s = '''\n}{\n'''\n"));
}

test "zig multiline string literals are text" {
    const zig = langs.byName("zig").?;
    const src = "const s =\n    \\\\ fn broken() {\n;\n";
    try std.testing.expectEqual(Verdict.ok, balance(zig, src));
}

test "rust lifetimes are not strings" {
    const rs = langs.byName("rust").?;
    try std.testing.expectEqual(Verdict.ok, balance(rs, "fn a<'x>(v: &'x str) -> &'x str { v }\n"));
}

test "char literals are skipped" {
    const c = langs.byName("c").?;
    try std.testing.expectEqual(Verdict.ok, balance(c, "char q = '{';\nint m(void) { return 0; }\n"));
}

test "prose is never judged" {
    const md = langs.byName("markdown").?;
    try std.testing.expectEqual(Verdict.inconclusive, balance(md, "see foo( for details\n"));
}

test "an unterminated string is inconclusive not broken" {
    const zig = langs.byName("zig").?;
    try std.testing.expectEqual(Verdict.inconclusive, balance(zig, "const s = \"oops;\n"));
}

test "decl finds keyword-led names" {
    const zig = langs.byName("zig").?;
    try std.testing.expectEqualStrings("build", decl(zig, "pub fn build(b: *B) void {").?.name);
    try std.testing.expectEqualStrings("Lang", decl(zig, "pub const Lang = struct {").?.name);
    try std.testing.expect(decl(zig, "pub const Lang = struct {").?.strong);
    try std.testing.expect(decl(zig, "const std = @import(\"std\");") == null);
    try std.testing.expect(decl(zig, "    return 1;") == null);
    try std.testing.expect(decl(zig, "// pub fn nope() void {") == null);

    const py = langs.byName("python").?;
    try std.testing.expectEqualStrings("run", decl(py, "async def run(self):").?.name);

    const ts = langs.byName("typescript").?;
    try std.testing.expectEqualStrings("Store", decl(ts, "export class Store {").?.name);
    try std.testing.expect(decl(ts, "import { a } from \"b\";") == null);
}

test "decl finds c-family signatures without a keyword" {
    const c = langs.byName("c").?;
    try std.testing.expectEqualStrings("main", decl(c, "int main(int argc, char **argv) {").?.name);
    try std.testing.expectEqualStrings("parse", decl(c, "static struct node *parse(const char *s);").?.name);
    try std.testing.expect(decl(c, "if (x) {") == null);
    try std.testing.expect(decl(c, "    total = sum(a, b);") == null);
}

test "control flow is never a declaration" {
    const ts = langs.byName("typescript").?;
    try std.testing.expect(decl(ts, "for (const x of xs) {") == null);
    try std.testing.expect(decl(ts, "while (go) {") == null);
}

test "rust raw strings hold text, delimiters and all" {
    const rs = langs.byName("rust").?;
    const src =
        "static P: &str = r#\"^\\s*(?:\\[|x)[^\\]]+\"#;\nfn a() {}\n";
    try std.testing.expectEqual(Verdict.ok, balance(rs, src));
    try std.testing.expectEqual(Verdict.ok, balance(rs, "let s = r##\"a\"#b\"##;\n"));
}

test "the scan abstains where a real parser owns the language" {
    // A JavaScript regex literal and a shell `case` label both look like stray
    // delimiters to a scan that does not parse them. Each of these languages
    // carries a parser in `langs.check`, so the scan stays out of the way
    // rather than rejecting correct code. Receipt: with these off, the scan
    // reported zero false positives over 5,454 files in six checkouts.
    const ts = langs.byName("typescript").?;
    try std.testing.expectEqual(Verdict.inconclusive, balance(ts, "const p = /[a-z]{2}/u;\n"));
    const sh = langs.byName("shell").?;
    try std.testing.expectEqual(Verdict.inconclusive, balance(sh, "case $x in\n  a) echo hi ;;\nesac\n"));
    for ([_][]const u8{ "javascript", "typescript", "shell", "zsh", "fish" }) |n| {
        const l = langs.byName(n).?;
        try std.testing.expect(!l.balance);
        try std.testing.expect(l.check.len > 0);
    }
}

test "a list item is not a declaration" {
    const ts = langs.byName("typescript").?;
    try std.testing.expect(decl(ts, "  type OpenAIModelRecord,") == null);
    try std.testing.expectEqualStrings("Store", decl(ts, "export interface Store {").?.name);
}
