# Agent guidance

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the shared development, safety and
review rules, then [CONTEXT.md](CONTEXT.md) for the current architecture. The
[documentation index](docs/README.md) routes detailed work. This is a source
preview, not a released notarized app.

## Before editing

- Inspect `git status`; preserve unrelated work and generated artifacts.
- Choose the supported component before reading research or legacy code.
  The product opens vanilla Minecraft; keep setup and recovery copy brief.
- Do not start agents or coordinate other chats unless the user authorizes it.
- Use local development. Do not publish a hosted test app.
- Use descriptive branches; avoid `Codex/*` and `codex/*` names.

## Installed data and process safety

Testing or building does not authorize installation, runtime staging or world
refreshes. Honor a no-install instruction throughout the task. Follow the
[shared safety rules](CONTRIBUTING.md#protect-game-data-and-credentials).

- Never print credentials, content keys, signed URLs, private account identifiers
  or unreviewed logs. Let the user handle sign-in and macOS security prompts.
- Do not reset Keychain permissions, weaken TLS or disable Gatekeeper.
- Do not replace a mapped runtime/helper. Ask the user to quit Minecraft normally
  before an authorized replacement; cleanup must target only owned processes.
- Preserve the native Play action's one-helper lifetime across download,
  preparation and gameplay. Do not create a second account session to simplify
  an implementation or test.
- Do not quit ChatGPT/Codex or kill unrelated processes to recover memory.
  In a workspace with a resource guard, use it for heavy tests, builds and native
  QA. Stop only owned jobs if memory pressure becomes unsafe.

## Finish the change

Use the [validation guide](docs/TESTING.md) and [source inventory recipe](docs/PUBLISHING.md#update-the-source-inventory).
Add public files individually to the exporter; never replace its allowlist with
recursive copying. Stage exact paths and inspect the staged diff.

Update architecture or user instructions when behavior/ownership changes.
Record the actual commands, source/artifact identity, outcomes and limitations.
Fixture tests, compilation, a live launch and clean-machine acceptance establish
different things. Do not rebuild or reinstall a live app for documentation work.
Respect the user's scope for pushing, opening PRs, merging and releases.
