# MCP

Model Context Protocol servers configured for omfx.

```
/mcp
/mcp <name>
```

Server definitions are stored privately under `~/.omfx` (see settings / MCP entries). omfx lists servers and can invoke them; it does not ship a remote MCP gateway.

Keep MCP config out of the repository. Prefer user-level settings so clones stay free of secrets.
