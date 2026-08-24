# Tools

Built-in tools the agent can call. Exact availability depends on permission mode and the provider's tool schema.

Typical capabilities:

- Read, edit, and search the workspace
- Run shell commands (sandboxed when enabled)
- Web fetch and web search (via `/web` backends)
- Diagnostics / verify after writes
- Memory, board, and peer coordination
- Browser relay (Chrome extension + local listener)
- MCP tools when servers are configured

Edits that leave a previously parseable file broken are undone automatically. Explore tools should run before mutating writes when the harness requires it.

See also [Permissions](../configure/permissions.md) and [Peers](peers.md).
