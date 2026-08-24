# Skills

Skills are discovered, not hard-coded into a fixed product list.

omfx walks known agent skill roots under your home directory (one and two levels deep), dedupes by inode then name, and exposes each skill as a slash command. The skill's `description:` front matter is the help text.

```
/reload
```

rescans. Several skills may apply to one prompt; built-in system commands still own the slash line when they match first.

Workspace and home `skills/` directories participate. A sample skill ships at `skills/hello-omfx/` in this repository.
