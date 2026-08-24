# Oh My Fx

A native coding agent for the terminal. Zig core, sticky-footer TUI, your providers.

```sh
curl -fsSL https://raw.githubusercontent.com/Yabuku-xD/omfx/main/install.sh | sh
```

Re-run to upgrade. Or build from source ([Zig 0.16.0+](https://ziglang.org/download/)):

```sh
zig build
./zig-out/bin/omfx
```

## Use

```
omfx                         Interactive session
omfx ask <prompt>            One-shot request
omfx doctor                  Runtime status
omfx version                 Print version
```

Inside a session: `/login` for providers, `/models` for the catalog, `/help` for the rest.

Flags: `--provider`, `--model`, `--effort`, `--yolo`, `--resume`, `-h`, `-V`.

## Docs

- [Quick start](docs/index.md)
- [Documentation index](docs/llms.txt)

## License

See repository license when published.
