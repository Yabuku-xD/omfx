# Plugins

Claude-compatible plugin marketplaces. Skills and hooks from other agent CLIs remain discoverable without a marketplace; this surface is for curated catalogs.

## Commands

```
/plugin
/plugin list
/plugin marketplace add owner/repo
/plugin install name@marketplace
```

| Form | Behaviour |
| --- | --- |
| `/plugin` or `/plugin list` | Show configured marketplaces and a rough plugin count |
| `/plugin marketplace add owner/repo` | Register a GitHub repo that publishes `.claude-plugin/marketplace.json` |
| `/plugin install …` | Install into `~/.omfx/plugins/` (install pass lands next; marketplace add/list work now) |

## Manifest

A marketplace is a git repo with `.claude-plugin/marketplace.json` (Claude Code's shape) listing plugins and sources. You can also point at an `.omfx-plugin/` layout when publishing for omfx specifically.

Suggested starting catalog:

```
/plugin marketplace add anthropics/claude-plugins-official
```

## Settings

Registered marketplaces are stored in `~/.omfx/settings.json` as `plugin_marketplaces`.

## Skills without a marketplace

Most day-to-day skills need no plugin install. omfx already walks skill roots from Claude, Codex, Pi, and others. See [Skills](skills.md).
