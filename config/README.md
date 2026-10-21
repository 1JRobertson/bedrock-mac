# Reviewed build configuration

- `native-dependencies.lock.json` pins source archives/digests and build inputs
  for the standalone native dependency prefix.
- `release-runtime-profile.json` selects exact upstream revisions, patches,
  tool versions and source inputs for release-runtime reconstruction.

These describe build inputs, not the user's installed game version or saves.
Builders run from the repository root and write ignored output elsewhere.
Changing a pin requires source/provenance review, relevant checks and updated
inventory; never relax a digest or ownership check to silence a failure.
See [dependency/build instructions](../docs/DEVELOPMENT.md),
[source publishing](../docs/PUBLISHING.md) and [component licenses](../THIRD_PARTY.md).
