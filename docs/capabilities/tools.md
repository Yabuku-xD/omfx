# Tools

Built-in tools the agent can call. Exact availability depends on permission mode and the provider's tool schema.

## Capabilities

- Read, edit, patch, and search the workspace (`read`, `write`, `edit`, `patch`, `glob`, `grep`, `list`, …)
- Hybrid `semantic_search` — repo reference rank, symbol names, and tokens fused with reciprocal rank fusion (no embeddings, no on-disk index)
- Shell commands (`bash`, `job`) with optional OS sandbox
- Web fetch and web search (via `/web` backends)
- Diagnostics after writes — parse gate, then optional one-shot LSP
- Memory, board, todo, and peer coordination
- Browser relay (Chrome extension + local listener)
- MCP tools when servers are configured
- Compact older turns (ARC cites)

## Parse gate

An edit that leaves a previously parseable file unparseable is undone before the model sees success. Thirty-six languages share one table for outline, balance scan, and parse probes. Explore tools should run before mutating writes when the harness requires it.

The gate only reacts to `diagnostics: findings`. Syntax honesty stays local and fast.

## One-shot LSP

After a clean parse, omfx may spawn that language's stdio language server once — if the binary is already on `PATH` — open the file, collect errors and warnings, and append them under `lsp:`.

- Nothing is bundled; nothing stays running after the request.
- Missing servers are skipped silently.
- Type errors inform the model; they do not undo the edit.
- Budget is capped (about twelve seconds) so a cold server cannot hang the loop.

Examples of servers omfx will try when present: `zls`, `gopls`, `rust-analyzer`, `typescript-language-server`, `pyright-langserver` / `pylsp`, `clangd`, `lua-language-server`, `nil` / `nixd`, and the other rows in the language table.

## Hybrid search

`semantic_search` walks the same ranked map used for orientation: symbol-reference scores, declaration names, and camelCase/snake_case tokens, fused together. Prefer it when the exact symbol is unknown; prefer `grep` / `glob` when you know the string.

## Memory and board

| Tool | Role |
| --- | --- |
| `memory` | Save / list / clear long-lived facts (user store under `~/.omfx`) |
| `board` | Post and read `FACT` / `FAIL` / `PATH` notes for coordination |
| `peer` | Spawn a teammate (harness) |
| `todo` | In-memory task list for the current turn |

Workspace memory also reinjects `.omfx/memory.md` every turn. See [Peers and board](peers.md).

See also [Permissions](../configure/permissions.md), [MCP](mcp.md), and [IDE](ide.md).
