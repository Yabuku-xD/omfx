const std = @import("std");

/// One table describing every language omfx understands, and the only place a
/// new language is added.
///
/// Three consumers read it: the repo map (which lines are declarations), the
/// edit gate (where comments and strings hide delimiters), and the syntax
/// probe (what to shell out to, when anything).
///
/// Deliberately not tree-sitter. Grammars are the right tool for a refactoring
/// engine and the wrong one for three consumers that each need a single bit
/// per line; they would also be the first C dependency in a repo that has
/// none. What is here is a lexer's worth of knowledge, and it covers the same
/// language list a WASM grammar bundle would.
pub const Lang = struct {
    name: []const u8,
    exts: []const []const u8,
    /// Line comment marker, "" when the language has none.
    line: []const u8 = "",
    /// Second line comment marker (PHP takes both `//` and `#`).
    line2: []const u8 = "",
    bopen: []const u8 = "",
    bclose: []const u8 = "",
    /// String delimiters. Order does not matter; each opens and closes itself.
    quotes: []const u8 = "\"'",
    /// Python-style `"""` and `'''` runs, which span lines and nest quotes.
    triple: bool = false,
    /// A quote-to-end-of-line string, such as Zig's `\\` multiline literal.
    /// Its contents are text, so delimiters inside it do not count.
    line_string: []const u8 = "",
    /// `r"..."` and `r#"..."#` hold text, delimiters included. Rust has no
    /// parser cheap enough for `check`, so the scan is its only gate and has
    /// to get this right.
    raw_string: bool = false,
    /// `'` opens a character literal, not a string. Set for the languages
    /// where it does, because Rust lifetimes (`&'a str`) and Zig labels would
    /// otherwise read as a string that never closes.
    char_lit: bool = false,
    /// A programming language, so its files belong in the repo map. False for
    /// prose, markup, and config, which have no declarations to summarize.
    code: bool = true,
    /// Whether the delimiter scan can be trusted to judge this language.
    ///
    /// False in two cases: prose and markup, where an unclosed bracket is
    /// ordinary text, and languages whose real syntax the scan misreads --
    /// a JavaScript regex literal (`/[a-z]{2}/`) and a shell `case` label
    /// (`Darwin)`) both look like stray delimiters. Each of those has a real
    /// parser in `check`, which answers instead. Measured against 2,385 files
    /// across four checkouts: with these off, the scan reports no false
    /// positives at all.
    balance: bool = true,
    /// Declarations without a leading keyword: `int main(void) {`. Costs a
    /// heuristic, so it is off for languages that do not need it.
    cstyle: bool = false,
    /// What to call the probe when reporting. Defaults to `check[0]`.
    check_label: []const u8 = "",
    /// Config-free, parse-only, fast. The file path is appended. Empty means
    /// the language has no probe that meets that bar, and the edit gate falls
    /// back to the balance scan.
    check: []const []const u8 = &.{},
    /// LSP `languageId` for `textDocument/didOpen`. Empty means no LSP row.
    language_id: []const u8 = "",
    /// Stdio language server argv. Never bundled — must already be on PATH.
    /// One-shot after a clean parse; idle servers are not kept alive.
    lsp: []const []const u8 = &.{},
    /// Fallback when `lsp[0]` is missing from PATH (e.g. pylsp vs pyright).
    lsp_alt: []const []const u8 = &.{},
};

const sh_quotes = "\"'`";

/// `compile()` rather than `py_compile`, which writes a __pycache__ into the
/// user's repo. A probe must not leave anything behind.
const py_parse = "import sys;compile(open(sys.argv[1],'rb').read(),sys.argv[1],'exec')";
const json_parse = "import json,sys;json.load(open(sys.argv[1],'rb'))";

/// Every language pi-lens lists, plus the ones omfx already read.
///
/// A `check` entry earns its place only if it parses without project config,
/// reports syntax alone (never formatting), and returns in well under a
/// second. `rustfmt --check` fails that test -- it exits nonzero on code that
/// merely wants reformatting, which would reject correct edits -- so Rust
/// rides the balance scan and `cargo check` at verify time instead.
pub const table = [_]Lang{
    .{
        .name = "zig",
        .quotes = "\"",
        .char_lit = true,
        .exts = &.{".zig"},
        .line = "//",
        .line_string = "\\\\",
        .check = &.{ "zig", "ast-check" },
        .check_label = "zig ast-check",
        .language_id = "zig",
        .lsp = &.{"zls"},
    },
    .{
        .name = "javascript",
        .balance = false,
        .exts = &.{ ".js", ".mjs", ".cjs", ".jsx" },
        .line = "//",
        .bopen = "/*",
        .bclose = "*/",
        .quotes = "\"'`",
        .check = &.{ "node", "--check" },
        .check_label = "node --check",
        .language_id = "javascript",
        .lsp = &.{ "typescript-language-server", "--stdio" },
    },
    .{
        .name = "typescript",
        .balance = false,
        .exts = &.{ ".ts", ".tsx", ".mts", ".cts" },
        .line = "//",
        .bopen = "/*",
        .bclose = "*/",
        .quotes = "\"'`",
        // Node 22.6+ parses TypeScript by stripping types. Older runtimes
        // reject the flag, which `probe` reads as "no checker here" rather
        // than as a syntax error.
        .check = &.{ "node", "--experimental-strip-types", "--check" },
        .check_label = "node --check (types stripped)",
        .language_id = "typescript",
        .lsp = &.{ "typescript-language-server", "--stdio" },
    },
    .{
        .name = "python",
        .exts = &.{ ".py", ".pyi" },
        .line = "#",
        .triple = true,
        .check = &.{ "python3", "-c", py_parse },
        .check_label = "python parse",
        .language_id = "python",
        .lsp = &.{ "pyright-langserver", "--stdio" },
        .lsp_alt = &.{"pylsp"},
    },
    .{
        .name = "ruby",
        .exts = &.{ ".rb", ".rake", ".gemspec" },
        .line = "#",
        .check = &.{ "ruby", "-c" },
        .check_label = "ruby -c",
        .language_id = "ruby",
        .lsp = &.{ "solargraph", "stdio" },
    },
    .{
        .name = "php",
        .exts = &.{".php"},
        .line = "//",
        .line2 = "#",
        .bopen = "/*",
        .bclose = "*/",
        .check = &.{ "php", "-l" },
        .check_label = "php -l",
        .language_id = "php",
        .lsp = &.{ "intelephense", "--stdio" },
    },
    .{
        .name = "go",
        .char_lit = true,
        .exts = &.{".go"},
        .line = "//",
        .bopen = "/*",
        .bclose = "*/",
        .quotes = "\"`",
        // Exits 2 and writes the position to stderr on a parse error; a merely
        // unformatted file still exits 0.
        .check = &.{ "gofmt", "-e" },
        .check_label = "gofmt -e",
        .language_id = "go",
        .lsp = &.{"gopls"},
    },
    .{
        .name = "rust",
        .quotes = "\"",
        .raw_string = true,
        .char_lit = true,
        .exts = &.{".rs"},
        .line = "//",
        .bopen = "/*",
        .bclose = "*/",
        .language_id = "rust",
        .lsp = &.{"rust-analyzer"},
    },
    .{
        .name = "shell",
        .balance = false,
        .exts = &.{ ".sh", ".bash" },
        .line = "#",
        .quotes = sh_quotes,
        .check = &.{ "bash", "-n" },
        .check_label = "bash -n",
        .language_id = "shellscript",
        .lsp = &.{ "bash-language-server", "start" },
    },
    .{
        .name = "zsh",
        .balance = false,
        .exts = &.{".zsh"},
        .line = "#",
        .quotes = sh_quotes,
        .check = &.{ "zsh", "-n" },
        .check_label = "zsh -n",
        .language_id = "shellscript",
        .lsp = &.{ "bash-language-server", "start" },
    },
    .{
        .name = "fish",
        .balance = false,
        .exts = &.{".fish"},
        .line = "#",
        .quotes = sh_quotes,
        .check = &.{ "fish", "--no-execute" },
        .check_label = "fish --no-execute",
        .language_id = "fish",
        .lsp = &.{ "fish-lsp", "start" },
    },
    .{
        .name = "lua",
        .exts = &.{".lua"},
        .line = "--",
        .bopen = "--[[",
        .bclose = "]]",
        .check = &.{ "luac", "-p" },
        .check_label = "luac -p",
        .language_id = "lua",
        .lsp = &.{"lua-language-server"},
    },
    .{
        .name = "swift",
        .quotes = "\"",
        .char_lit = true,
        .exts = &.{".swift"},
        .line = "//",
        .bopen = "/*",
        .bclose = "*/",
        .check = &.{ "swiftc", "-parse" },
        .check_label = "swiftc -parse",
        .language_id = "swift",
        .lsp = &.{"sourcekit-lsp"},
    },
    .{
        .name = "c",
        .quotes = "\"",
        .char_lit = true,
        .exts = &.{ ".c", ".h" },
        .line = "//",
        .bopen = "/*",
        .bclose = "*/",
        .cstyle = true,
        .language_id = "c",
        .lsp = &.{"clangd"},
    },
    .{
        .name = "cpp",
        .quotes = "\"",
        .char_lit = true,
        .exts = &.{ ".cc", ".cpp", ".cxx", ".hh", ".hpp", ".hxx" },
        .line = "//",
        .bopen = "/*",
        .bclose = "*/",
        .cstyle = true,
        .language_id = "cpp",
        .lsp = &.{"clangd"},
    },
    .{
        .name = "java",
        .quotes = "\"",
        .char_lit = true,
        .exts = &.{".java"},
        .line = "//",
        .bopen = "/*",
        .bclose = "*/",
        .cstyle = true,
        .language_id = "java",
        .lsp = &.{"jdtls"},
    },
    .{
        .name = "csharp",
        .quotes = "\"",
        .char_lit = true,
        .exts = &.{".cs"},
        .line = "//",
        .bopen = "/*",
        .bclose = "*/",
        .cstyle = true,
        .language_id = "csharp",
        .lsp = &.{"csharp-ls"},
        .lsp_alt = &.{ "omnisharp", "-lsp" },
    },
    .{
        .name = "fsharp",
        .exts = &.{ ".fs", ".fsi", ".fsx" },
        .line = "//",
        .bopen = "(*",
        .bclose = "*)",
        .language_id = "fsharp",
        .lsp = &.{ "fsautocomplete", "--adaptive-lsp-server-enabled" },
    },
    .{
        .name = "kotlin",
        .quotes = "\"",
        .char_lit = true,
        .exts = &.{ ".kt", ".kts" },
        .line = "//",
        .bopen = "/*",
        .bclose = "*/",
        .language_id = "kotlin",
        .lsp = &.{"kotlin-language-server"},
    },
    .{
        .name = "scala",
        .quotes = "\"",
        .char_lit = true,
        .exts = &.{ ".scala", ".sc" },
        .line = "//",
        .bopen = "/*",
        .bclose = "*/",
        .language_id = "scala",
        .lsp = &.{"metals"},
    },
    .{
        .name = "dart",
        .exts = &.{".dart"},
        .line = "//",
        .bopen = "/*",
        .bclose = "*/",
        .language_id = "dart",
        .lsp = &.{ "dart", "language-server", "--protocol=lsp" },
    },
    .{
        .name = "haskell",
        .quotes = "\"",
        .char_lit = true,
        .exts = &.{ ".hs", ".lhs" },
        .line = "--",
        .bopen = "{-",
        .bclose = "-}",
        .language_id = "haskell",
        .lsp = &.{ "haskell-language-server-wrapper", "--lsp" },
    },
    .{
        .name = "elixir",
        .exts = &.{ ".ex", ".exs" },
        .line = "#",
        .triple = true,
        .language_id = "elixir",
        .lsp = &.{"language_server.sh"},
        .lsp_alt = &.{"elixir-ls"},
    },
    .{
        .name = "erlang",
        .exts = &.{ ".erl", ".hrl" },
        .line = "%",
        .language_id = "erlang",
        .lsp = &.{"erlang_ls"},
    },
    .{
        .name = "gleam",
        .exts = &.{".gleam"},
        .line = "//",
        .language_id = "gleam",
        .lsp = &.{ "gleam", "lsp" },
    },
    .{
        .name = "ocaml",
        .quotes = "\"",
        .char_lit = true,
        .exts = &.{ ".ml", ".mli" },
        .bopen = "(*",
        .bclose = "*)",
        .language_id = "ocaml",
        .lsp = &.{"ocamllsp"},
    },
    .{
        .name = "clojure",
        .exts = &.{ ".clj", ".cljs", ".cljc", ".edn" },
        .line = ";",
        .language_id = "clojure",
        .lsp = &.{"clojure-lsp"},
    },
    .{
        .name = "perl",
        .exts = &.{ ".pl", ".pm" },
        .line = "#",
        .language_id = "perl",
        .lsp = &.{ "perlnavigator", "--stdio" },
    },
    .{
        .name = "powershell",
        .exts = &.{ ".ps1", ".psm1", ".psd1" },
        .line = "#",
        .bopen = "<#",
        .bclose = "#>",
        .language_id = "powershell",
        .lsp = &.{"powershell-editor-services"},
    },
    .{
        .name = "nix",
        .exts = &.{".nix"},
        .line = "#",
        .bopen = "/*",
        .bclose = "*/",
        .language_id = "nix",
        .lsp = &.{"nil"},
        .lsp_alt = &.{"nixd"},
    },
    .{
        .name = "terraform",
        .exts = &.{ ".tf", ".tfvars", ".hcl" },
        .line = "#",
        .line2 = "//",
        .bopen = "/*",
        .bclose = "*/",
        .language_id = "terraform",
        .lsp = &.{ "terraform-ls", "serve" },
    },
    .{
        .name = "prisma",
        .exts = &.{".prisma"},
        .line = "//",
        .language_id = "prisma",
        .lsp = &.{ "prisma-language-server", "--stdio" },
    },
    .{
        .name = "cue",
        .exts = &.{".cue"},
        .line = "//",
        .language_id = "cue",
        .lsp = &.{ "cue", "lsp", "stdio" },
    },
    .{
        .name = "sql",
        .exts = &.{".sql"},
        .line = "--",
        .bopen = "/*",
        .bclose = "*/",
        .language_id = "sql",
        .lsp = &.{ "sql-language-server", "up", "--method", "stdio" },
    },
    .{
        .name = "vue",
        .code = false,
        .exts = &.{".vue"},
        .line = "//",
        .bopen = "<!--",
        .bclose = "-->",
        .quotes = "\"'`",
        .balance = false,
        .language_id = "vue",
        .lsp = &.{ "vue-language-server", "--stdio" },
    },
    .{
        .name = "svelte",
        .code = false,
        .exts = &.{".svelte"},
        .line = "//",
        .bopen = "<!--",
        .bclose = "-->",
        .quotes = "\"'`",
        .balance = false,
        .language_id = "svelte",
        .lsp = &.{ "svelteserver", "--stdio" },
    },
    .{
        .name = "css",
        .code = false,
        .exts = &.{ ".css", ".scss", ".less", ".sass" },
        .line = "//",
        .bopen = "/*",
        .bclose = "*/",
        .language_id = "css",
        .lsp = &.{ "vscode-css-language-server", "--stdio" },
    },
    .{
        .name = "html",
        .code = false,
        .exts = &.{ ".html", ".htm", ".xhtml" },
        .bopen = "<!--",
        .bclose = "-->",
        .balance = false,
        .language_id = "html",
        .lsp = &.{ "vscode-html-language-server", "--stdio" },
    },
    .{
        .name = "xml",
        .code = false,
        .exts = &.{ ".xml", ".xsd", ".svg" },
        .bopen = "<!--",
        .bclose = "-->",
        .balance = false,
        .language_id = "xml",
        .lsp = &.{"lemminx"},
    },
    .{
        .name = "json",
        .code = false,
        .exts = &.{ ".json", ".jsonc" },
        .quotes = "\"",
        .check = &.{ "python3", "-c", json_parse },
        .check_label = "json parse",
        .language_id = "json",
        .lsp = &.{ "vscode-json-language-server", "--stdio" },
    },
    .{
        .name = "yaml",
        .code = false,
        .exts = &.{ ".yaml", ".yml" },
        .line = "#",
        // Block scalars carry arbitrary text, so a stray bracket in one is not
        // a syntax error and must not read as one.
        .balance = false,
        .language_id = "yaml",
        .lsp = &.{ "yaml-language-server", "--stdio" },
    },
    .{
        .name = "toml",
        .code = false,
        .exts = &.{".toml"},
        .line = "#",
        .balance = false,
        .language_id = "toml",
        .lsp = &.{ "taplo", "lsp", "stdio" },
    },
    .{
        .name = "markdown",
        .code = false,
        .exts = &.{ ".md", ".markdown", ".mdx" },
        .bopen = "<!--",
        .bclose = "-->",
        .balance = false,
        .language_id = "markdown",
        .lsp = &.{ "marksman", "server" },
    },
    .{
        .name = "dockerfile",
        .code = false,
        .exts = &.{".dockerfile"},
        .line = "#",
        .balance = false,
        .language_id = "dockerfile",
        .lsp = &.{ "docker-langserver", "--stdio" },
    },
    .{
        .name = "make",
        .code = false,
        .exts = &.{".mk"},
        .line = "#",
        .balance = false,
        .language_id = "makefile",
        .lsp = &.{"autotools-language-server"},
    },
};

/// Files whose language is decided by name rather than extension.
const by_name = [_]struct { name: []const u8, lang: []const u8 }{
    .{ .name = "Dockerfile", .lang = "dockerfile" },
    .{ .name = "Makefile", .lang = "make" },
    .{ .name = "GNUmakefile", .lang = "make" },
    .{ .name = "Gemfile", .lang = "ruby" },
    .{ .name = "Rakefile", .lang = "ruby" },
    .{ .name = "CMakeLists.txt", .lang = "make" },
};

comptime {
    if (table.len == 0) @compileError("langs.table must describe at least one language");
    for (table) |l| {
        if (l.exts.len == 0) @compileError("every language needs at least one extension");
        if ((l.bopen.len == 0) != (l.bclose.len == 0))
            @compileError("block comment needs both delimiters or neither");
    }
}

/// What to print when naming this language's probe.
pub fn label(l: *const Lang) []const u8 {
    if (l.check_label.len > 0) return l.check_label;
    if (l.check.len > 0) return l.check[0];
    return l.name;
}

pub fn byName(name: []const u8) ?*const Lang {
    for (&table) |*l| {
        if (std.mem.eql(u8, l.name, name)) return l;
    }
    return null;
}

/// Extension first, then the handful of files that carry no extension.
pub fn byPath(path: []const u8) ?*const Lang {
    const base = std.fs.path.basename(path);
    const ext = std.fs.path.extension(base);
    if (ext.len > 1) {
        for (&table) |*l| {
            for (l.exts) |e| {
                if (std.ascii.eqlIgnoreCase(ext, e)) return l;
            }
        }
    }
    for (by_name) |n| {
        if (std.mem.eql(u8, base, n.name)) return byName(n.lang);
    }
    return null;
}

/// Whether this path is worth putting in the repo map. Data and prose files
/// have no declarations to summarize, so they would spend the map's budget
/// without adding to it.
pub fn isSource(path: []const u8) bool {
    const l = byPath(path) orelse return false;
    return l.code;
}

test "byPath covers extension and bare-name files" {
    try std.testing.expectEqualStrings("zig", byPath("src/main.zig").?.name);
    try std.testing.expectEqualStrings("typescript", byPath("a/b/c.tsx").?.name);
    try std.testing.expectEqualStrings("dockerfile", byPath("deploy/Dockerfile").?.name);
    try std.testing.expectEqualStrings("ruby", byPath("Gemfile").?.name);
    try std.testing.expect(byPath("notes.unknownext") == null);
}

test "prose and data are not repo-map sources" {
    try std.testing.expect(!isSource("README.md"));
    try std.testing.expect(!isSource("ci.yaml"));
    try std.testing.expect(isSource("lib.rs"));
    try std.testing.expect(isSource("main.c"));
}

test "every language name is unique" {
    for (&table, 0..) |*a, i| {
        for (table[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}

test "no extension is claimed by two languages" {
    for (&table, 0..) |*a, i| {
        for (a.exts) |ea| {
            for (table[i + 1 ..]) |b| {
                for (b.exts) |eb| {
                    try std.testing.expect(!std.ascii.eqlIgnoreCase(ea, eb));
                }
            }
        }
    }
}

test "a language the scan cannot judge has a parser to fall back on" {
    // Turning `balance` off is only safe where `check` answers instead.
    // Otherwise the language would have no gate at all.
    for (&table) |*l| {
        if (l.balance or !l.code) continue;
        try std.testing.expect(l.check.len > 0);
    }
}

test "every language with an lsp row names a languageId" {
    for (&table) |*l| {
        if (l.lsp.len == 0 and l.lsp_alt.len == 0) continue;
        try std.testing.expect(l.language_id.len > 0);
        try std.testing.expect(l.lsp.len > 0 or l.lsp_alt.len > 0);
    }
}

test "every language is either code or data, and code can be outlined" {
    try std.testing.expect(byName("typescript").?.code);
    try std.testing.expect(byName("rust").?.code);
    try std.testing.expect(!byName("yaml").?.code);
    try std.testing.expect(!byName("markdown").?.code);
}
