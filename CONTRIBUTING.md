# Contributing

Start with [the architecture](CONTEXT.md) and [repository map](docs/README.md).
The [development guide](docs/DEVELOPMENT.md) covers a local build. Agent-specific
instructions live in [AGENTS.md](AGENTS.md); shared project rules are here.

The launcher should get users to **vanilla Minecraft** with reliable setup,
sign-in, updates and recovery. Minecraft keeps its own menus for worlds, packs,
settings and friends. Prefer changes that improve that path.

## Make a change

1. Check the working tree and preserve unrelated work. Use a descriptive branch
   and choose the supported component responsible for the behavior.
2. Reproduce the problem with a fixture or isolated local test where possible.
   Change tracked source; retain upstream fixes as patches against pinned trees.
3. Run relevant checks from [TESTING.md](docs/TESTING.md). Keep expensive builds
   sequential and record what passed, failed, skipped or could not run.
4. Update the affected guide. Add each new public file individually to the
   source export allowlist and regenerate the [inventory](docs/PUBLISHING.md#update-the-source-inventory).
5. Inspect the staged diff and open a PR explaining the problem, result,
   validation and remaining limits. Verify checks on the final commit. If hosted
   CI is unavailable, state that and record the local checks explicitly.

A source merge does not publish an app release. Native acceptance and binary
release work remain in [release readiness](docs/RELEASE.md).

## Protect game data and credentials

- Keep game payloads, worlds, downloaded binaries, credentials and private logs
  out of commits. The explicit source allowlist is the export boundary.
- Preserve existing game/prefix data and conflicting files. Do not reset an
  installation to hide a repair failure. Keep a specific recovery path.
- Save and quit Minecraft normally before replacing its runtime, helper or app.
  Never use broad process kills, global Wine-server termination or socket
  deletion to force access to an ambiguous live session.
- Keep live account/Keychain tests deliberate. The tester enters credentials
  and handles security prompts. Do not weaken TLS, Gatekeeper or Keychain access.
- Tests, builds and source changes do not authorize installation or refreshing
  an existing game/world. Use isolated temporary fixtures for ordinary checks.
- Keep the same authorized helper bytes for repeat-launch prompt tests; a
  rebuilt ad-hoc helper can legitimately request Keychain authorization again.

Source development uses the checkout data root. A packaged app uses
`~/Library/Application Support/Bedrock for Mac/`. They are separate from the
historical CrossOver prefix. See [data ownership](CONTEXT.md#data-and-process-ownership).

## Source and dependencies

`sources/` is generated from exact upstream pins. Keep durable changes in tracked
patches and bootstrap/build configuration, not only an ignored checkout. Retain
license notices, the locked Cargo dependencies, real Microsoft ownership checks
and exact download digests. Do not add game assets or proprietary payloads to
source exports. See [licensing](THIRD_PARTY.md) and [publishing](docs/PUBLISHING.md).

## Checks

Run from the repository root:

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
python3 tools/export-source.py --check
shasum -a 256 -c SOURCE-SHA256.txt
git diff --check
```

Use the [testing guide](docs/TESTING.md) for helper, native launcher, Wine and
packaging checks. Default account fixtures use synthetic backends and private
temporary sockets. Opt-in tests may contact Microsoft or Keychain; never add
`--include-ignored` to routine checks. A source check is not game acceptance.

## Bug reports and review

Use the [bug template](https://github.com/1JRobertson/bedrock-mac/issues/new?template=bug_report.yml).
Include Mac model/chip/memory, macOS, app/source revision, game version, last
visible stage, expected/actual behavior, and whether it is a fresh install,
retry or update. Review excerpts before sharing; omit account tokens, passwords,
email addresses, signed URLs, Keychain exports and full unreviewed logs.

For review findings, give a concrete trigger, impact and file location. Check
existing labels before assigning them. Security reports follow
[SECURITY.md](SECURITY.md); ordinary setup failures belong in Issues.
