# Check a fresh source installation

This is a planned manual test of `Start.command`, not a completed qualification
or a packaged-app test. The tester deliberately installs prerequisites and the
owned game, enters their own credentials and handles macOS security prompts.

## Choose the starting state

Best evidence comes from another compatible Apple Silicon Mac with macOS 15+
that has not run this project. Record whatever build tools or Rosetta are already
installed; an independent Mac is not automatically free of prerequisites.
An already-present prerequisite does not count as testing its installer.

Without another Mac, a new checkout in a separate macOS user account is a useful
first-run smoke test. Homebrew, Rosetta and developer tools can still be shared
across users, so this does not establish clean-machine bootstrap. Keep that
qualification open until an independently recorded installation passes.
Do not erase an existing setup or Keychain to manufacture a clean state. A VM
does not establish this Wine/DXMT path's behavior on a real Mac GPU.

## Tester recipe

1. Agree on one **full public source commit SHA**. Use its GitHub ZIP, for example
   `https://github.com/1JRobertson/bedrock-mac/archive/<full-SHA>.zip`, so getting
   the source does not require Git before Command Line Tools are installed.
   Record that URL and SHA; do not substitute moving `main` halfway through.
2. Extract into a new, permanent folder you control, such as
   `~/git/bedrock-mac-clean-check`, only if the entire expanded path meets the
   [build path rules](DEVELOPMENT.md#build-paths). Preserve any existing checkout.
   This folder will hold the test game and worlds; do not treat it as temporary.
3. Before setup, record Mac model/chip/RAM, macOS, free disk space, and whether
   Command Line Tools, Homebrew, Python, Rust/rustup and Rosetta are present,
   absent or unknown. Use a tester-owned account entitled to Minecraft for
   Windows. Quit existing Minecraft/launcher sessions normally and let their
   helpers stop before testing.
4. Follow the [public source instructions](../README.md#start-from-source),
   starting only this checkout's `Start.command`. Keep Terminal open. Record
   prerequisite prompts, manual interventions, first failure and elapsed time.
   Do not copy an existing runtime, helper, game or prefix to get past a failure;
   that would change the scenario. Keep certificate and macOS protections intact.
5. Complete sign-in and the owned-game download. If practical, interrupt the
   **new test download** once with Control-C, then reopen the same `Start.command`
   and check retry. Interrupted downloads restart. Record this as skipped if
   repeating the download is impractical; never interrupt another installation.
6. Reach Minecraft, record the displayed game version, and create a disposable
   world. Make an obvious change, save and quit normally, reopen with the same
   `Start.command`, and verify the change remains. Record final free space and
   setup/play times. Preserve the checkout and test world until results are reviewed.

Stop at a failure rather than resetting data or silently applying a workaround.
Record a workaround separately if later investigated. Source setup passing does
not certify a downloaded app, signing, updates, multiplayer or other Mac models.

## Share a short result

Copy this record into an issue or maintainer report. Mark every scenario
**pass / fail / skipped** and include the observed result, not just a checkmark.

```text
Date:
Full source SHA and source ZIP URL:
Mac / chip / RAM / macOS:
Starting state: independent Mac or same-Mac smoke test; prior project use:
Initially present / absent / unknown prerequisites:
Free disk before / after; elapsed prerequisite setup / build / download:
Prerequisite prompts and any manual interventions:
Sign-in and download — result:
Interrupt/retry — result or reason skipped:
Minecraft version; first launch — result:
Disposable world save / quit / reopen — result:
First failure, last visible stage and safe error code, if any:
Remaining limits / separate workarounds:
```

Share only reviewed, relevant diagnostic excerpts. Omit account identifiers,
tokens, passwords, auth headers, signed URLs, Keychain data and full logs.
Results update [release readiness](RELEASE.md); this unfilled recipe is not evidence.
