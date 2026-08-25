//! Lightweight syntax colour for fenced code. Keywords only — enough to read
//! a plate without dragging a highlighter framework into the session.

const std = @import("std");
const paint = @import("../core/ansi.zig");

const Lang = enum { none, zig, js, py, json, sh, rust, go, c };

fn langOf(raw: []const u8) Lang {
    if (raw.len == 0) return .none;
    if (std.ascii.eqlIgnoreCase(raw, "zig") or std.ascii.eqlIgnoreCase(raw, "zon")) return .zig;
    if (std.ascii.eqlIgnoreCase(raw, "js") or std.ascii.eqlIgnoreCase(raw, "javascript") or
        std.ascii.eqlIgnoreCase(raw, "ts") or std.ascii.eqlIgnoreCase(raw, "typescript")) return .js;
    if (std.ascii.eqlIgnoreCase(raw, "py") or std.ascii.eqlIgnoreCase(raw, "python")) return .py;
    if (std.ascii.eqlIgnoreCase(raw, "json")) return .json;
    if (std.ascii.eqlIgnoreCase(raw, "sh") or std.ascii.eqlIgnoreCase(raw, "bash") or
        std.ascii.eqlIgnoreCase(raw, "shell") or std.ascii.eqlIgnoreCase(raw, "zsh")) return .sh;
    if (std.ascii.eqlIgnoreCase(raw, "rs") or std.ascii.eqlIgnoreCase(raw, "rust")) return .rust;
    if (std.ascii.eqlIgnoreCase(raw, "go")) return .go;
    if (std.ascii.eqlIgnoreCase(raw, "c") or std.ascii.eqlIgnoreCase(raw, "h") or
        std.ascii.eqlIgnoreCase(raw, "cpp") or std.ascii.eqlIgnoreCase(raw, "cc")) return .c;
    return .none;
}

fn keywords(lang: Lang) []const []const u8 {
    return switch (lang) {
        .none => &.{},
        .zig => &.{ "const", "var", "fn", "pub", "try", "catch", "return", "if", "else", "while", "for", "switch", "defer", "errdefer", "struct", "enum", "error", "test", "import", "comptime", "inline", "async", "await", "true", "false", "null", "undefined", "break", "continue" },
        .js => &.{ "const", "let", "var", "function", "return", "if", "else", "for", "while", "class", "import", "export", "from", "async", "await", "try", "catch", "throw", "new", "this", "true", "false", "null", "undefined", "typeof", "of", "in" },
        .py => &.{ "def", "class", "return", "if", "elif", "else", "for", "while", "import", "from", "as", "try", "except", "raise", "with", "async", "await", "True", "False", "None", "and", "or", "not", "in", "is", "lambda", "yield", "pass", "break", "continue" },
        .json => &.{ "true", "false", "null" },
        .sh => &.{ "if", "then", "else", "fi", "for", "do", "done", "while", "case", "esac", "function", "return", "export", "local", "true", "false" },
        .rust => &.{ "fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "return", "if", "else", "match", "loop", "while", "for", "in", "async", "await", "true", "false", "self", "Self", "crate", "super" },
        .go => &.{ "func", "var", "const", "return", "if", "else", "for", "range", "switch", "case", "type", "struct", "interface", "package", "import", "go", "defer", "true", "false", "nil", "map", "chan" },
        .c => &.{ "int", "void", "char", "return", "if", "else", "for", "while", "switch", "case", "struct", "typedef", "const", "static", "sizeof", "true", "false", "NULL", "include" },
    };
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

fn isIdent(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

fn isKeyword(lang: Lang, word: []const u8) bool {
    for (keywords(lang)) |k| {
        if (std.mem.eql(u8, k, word)) return true;
    }
    return false;
}

pub fn paintLine(out: *std.ArrayList(u8), a: std.mem.Allocator, lang_raw: []const u8, line: []const u8) !void {
    const lang = langOf(lang_raw);
    if (lang == .none or line.len == 0) {
        try out.appendSlice(a, line);
        return;
    }
    var i: usize = 0;
    while (i < line.len) {
        if ((lang == .zig or lang == .js or lang == .rust or lang == .go or lang == .c or lang == .sh) and
            i + 1 < line.len and line[i] == '/' and line[i + 1] == '/')
        {
            try out.appendSlice(a, paint.muted);
            try out.appendSlice(a, line[i..]);
            try out.appendSlice(a, paint.reset);
            try out.appendSlice(a, paint.code_bg);
            try out.appendSlice(a, paint.code_fg);
            return;
        }
        if (lang == .py and line[i] == '#') {
            try out.appendSlice(a, paint.muted);
            try out.appendSlice(a, line[i..]);
            try out.appendSlice(a, paint.reset);
            try out.appendSlice(a, paint.code_bg);
            try out.appendSlice(a, paint.code_fg);
            return;
        }
        if (line[i] == '"' or line[i] == '\'') {
            const q = line[i];
            var j = i + 1;
            while (j < line.len) : (j += 1) {
                if (line[j] == '\\' and j + 1 < line.len) {
                    j += 1;
                    continue;
                }
                if (line[j] == q) {
                    j += 1;
                    break;
                }
            }
            try out.appendSlice(a, paint.add_fg);
            try out.appendSlice(a, line[i..j]);
            try out.appendSlice(a, paint.reset);
            try out.appendSlice(a, paint.code_bg);
            try out.appendSlice(a, paint.code_fg);
            i = j;
            continue;
        }
        if (std.ascii.isDigit(line[i])) {
            var j = i + 1;
            while (j < line.len and (std.ascii.isAlphanumeric(line[j]) or line[j] == '.' or line[j] == '_')) : (j += 1) {}
            try out.appendSlice(a, paint.hunk);
            try out.appendSlice(a, line[i..j]);
            try out.appendSlice(a, paint.reset);
            try out.appendSlice(a, paint.code_bg);
            try out.appendSlice(a, paint.code_fg);
            i = j;
            continue;
        }
        if (isIdentStart(line[i])) {
            var j = i + 1;
            while (j < line.len and isIdent(line[j])) : (j += 1) {}
            const word = line[i..j];
            if (isKeyword(lang, word)) {
                try out.appendSlice(a, paint.accent_dim);
                try out.appendSlice(a, word);
                try out.appendSlice(a, paint.reset);
                try out.appendSlice(a, paint.code_bg);
                try out.appendSlice(a, paint.code_fg);
            } else {
                try out.appendSlice(a, word);
            }
            i = j;
            continue;
        }
        try out.append(a, line[i]);
        i += 1;
    }
}

test "keywords colour" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try paintLine(&out, std.testing.allocator, "zig", "const x = 1;");
    try std.testing.expect(std.mem.indexOf(u8, out.items, "const") != null);
    try std.testing.expect(out.items.len > "const x = 1;".len);
}
