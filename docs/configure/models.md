# Models

Choose and inspect models for the signed-in provider.

## Pick a model

```
/models
/models refresh
/models <id>
```

`/model` is an alias of `/models`. The list comes from the provider catalog when published, otherwise the built-in table. After you pick a model that declares reasoning levels, omfx offers `auto` plus those levels.

## Effort

```
/effort
/effort auto
/effort <level>
```

Ctrl-t cycles levels for the current model. `auto` is offered by omfx and resolved per prompt (not a provider default).

## Fast

`/fast on` forces `effort=none` for the session. `/fast off` restores the previous effort.

## Persistence

Last provider and model are stored in `~/.omfx/settings.json`. Launching omfx does not reset them.
