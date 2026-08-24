# MCP

Model Context Protocol servers configured for omfx.

```
/mcp
/mcp <name>
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
    }
  ]
}
```

You can configure many servers (tripwire cap 128). Each server may pass up to 32 argv entries. Call tools as `server/tool` when more than one server is listed.

omfx lists servers and invokes them over stdio. It does not ship a remote MCP gateway.

Keep MCP config out of the repository. Prefer user-level settings so clones stay free of secrets.
