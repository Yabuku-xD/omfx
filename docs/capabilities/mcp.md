# MCP

Model Context Protocol servers configured for omfx.

```
/mcp
/mcp <name>
/mcp add <name> <command> [args...]
/mcp add --transport http <name> <url>
```

## Settings

Add servers to `~/.omfx/settings.json`:

```json
{
  "mcp": [
    {
      "name": "fs",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "."]
    },
    {
      "name": "remote",
      "url": "https://example.com/mcp"
    }
  ]
}
```

You can configure many servers (tripwire cap 128). Each stdio server may pass up to 32 argv entries. Call tools as `server/tool` when more than one server is listed.

omfx lists servers and invokes them over stdio or Streamable HTTP (`url`). It does not ship a remote MCP gateway.

Keep MCP config out of the repository. Prefer user-level settings so clones stay free of secrets.
