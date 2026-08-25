# Models

Choose and inspect models for the signed-in provider.

## Pick a model

```
/models
/models refresh
/models <id>
```

`/model` is an alias of `/models`.

Bare `/models` lists providers you signed in to. Pick one to see its models. Esc steps back to the provider list.

The list comes from the provider catalog when published, otherwise the built-in table. After you pick a model that declares reasoning levels, omfx offers `auto` plus those levels. Vision-capable models are labelled; image paths in the prompt attach when supported.

Configured providers and free web backends show a leading `✓` in pick menus so the tick survives half-width clipping.

## Effort

```
/effort
/effort auto
/effort <level>
```

Ctrl-t cycles levels for the current model. `auto` is offered by omfx and resolved per prompt from lexical signals (not a fixed provider default). Easy and hard prompts get the floor; the responsive middle gets the budget. Two failed turns route effort down.

## Fast

`/fast on` forces `effort=none` for the session. `/fast off` restores the previous effort.

## Persistence

Last provider and model are stored in `~/.omfx/settings.json`. Launching omfx does not reset them. An optional `models` map keeps a preferred model per provider so switching providers does not clobber the other:

```json
{
  "models": {
    "xai-oauth": "grok-build-0.1",
    "commandcode": "deepseek/deepseek-v4-flash"
  }
}
```

Subscription and API-key logins for the same model may see different context ceilings (`authCap`).
