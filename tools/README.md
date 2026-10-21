# Build and maintenance tools

Bootstrap, dependency/runtime builders, source startup, packaging, notice
collection and the explicit source exporter live here. Run commands from the
repository root; generated outputs remain in ignored root `build/`, `sources/`
and `runtime/` directories.

```sh
python3 tools/export-source.py --check
python3 tools/bootstrap-sources.py --check  # after sources have been fetched
```

These are read-only checks. The regular source entry point is `Start.command`;
it calls `tools/start.py`. Build/staging commands can modify generated components
and require the relevant process/data safeguards. See
[development](../docs/DEVELOPMENT.md), [testing](../docs/TESTING.md) and
[publishing](../docs/PUBLISHING.md). A build does not authorize installation.
