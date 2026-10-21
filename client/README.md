# Supported client

This directory contains the standalone game session, account helper, verified
game/component acquisition, GameInput preparation and picker registration.
The native interface/worker live in `launcher/`.

Run from the repository root:

```sh
./Start.command
python3 client/standalone-setup.py --check
```

`--check` is read-only and does not access Microsoft or Keychain. Setup/play use
the checkout data root unless a lower-level CLI command explicitly selects
`BEDROCK_HOME`; packaged apps use Application Support. Source files here are
not the game, prefix or saves. See [architecture](../CONTEXT.md),
[CLI reference](../docs/CLI.md) and [user files](../docs/USER_GUIDE.md#your-files-backups-and-updates).
