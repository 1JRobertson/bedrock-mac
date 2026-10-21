# Historical CrossOver path

These files retain the earlier CrossOver launcher/helper/build implementation.
The supported source entry point is root `Start.command`; current runtime and
account code live under `client/`.

Legacy commands use the separate `bottles/Bedrock-Mac` prefix and historical
Keychain service. They do not migrate current saves or share source preparation
with the native app automatically. Run any documented commands from the project
root, preserve existing data, and do not launch over an active session.

Read [the historical implementation record](../docs/history/CROSSOVER.md) before
using these tools. They remain reference material, not a dependency on CrossOver
for the supported standalone product.
