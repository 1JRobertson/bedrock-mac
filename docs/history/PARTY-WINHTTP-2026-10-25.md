# Party creation and WinHTTP — October 25, 2026

Minecraft's **Social → Party → Create party** repeatedly failed with
“Unable to create party” / “Failed to create party” on the source checkout.
Invites reached the user's phone but were absent in this instance. The user
had not previously created a party successfully in this Mac installation.

## Root cause and causal check

Authentication and the game's Xbox realtime connections succeeded. PlayFab's
`ConnectToLobbyCompleted` state change returned `0x89236209`, documented as
[failed to parse JSON](https://learn.microsoft.com/en-us/gaming/playfab/multiplayer/lobby/playfabmultiplayerreference-cpp/pfmultiplayererrors).
The parser failed at byte one on an HTML response to a PlayFab HTTP request.

Metadata-only observation established that the SDK issued six full
`WinHttpWriteData(..., length, NULL)` calls for a request declaring
Content-Length 307, and then six for one declaring Content-Length 61. The first
response was HTTP 200 JSON; the next was HTTP 400 HTML. These excess bytes
corrupted the reused HTTP connection. No request bodies, authentication headers,
tokens or account identifiers are included in this record.

The SDK calls `WinHttpWriteData` before advancing its send offset and reducing
the remaining byte count. Wine delivers WRITE_COMPLETE inline inside the active
completion callback. The nested SDK callback sees the old offset and sends the
same bytes again, until Wine's recursion cap queues the next completion.

A temporary in-process correction deferred nested write completions until the
outer callback returned. In the same running session the user confirmed
**“Party creation worked.”** The observer counted two deferred completions.
This bounded probe changed no installed files and expired after five minutes;
normal game exit clears its remaining forwarding callbacks.

This is a Wine–bundled-PlayFab SDK compatibility defect. Microsoft's
[WinHttpWriteData documentation](https://learn.microsoft.com/en-us/windows/win32/api/winhttp/nf-winhttp-winhttpwritedata)
permits synchronous completion with WINHTTP_FLAG_ASYNC. The evidence does not
establish a violation of the Windows API contract or require all asynchronous
writes to complete on another thread.

## Retained fix

`patches/standalone-wine-winhttp-write-callbacks.patch` queues asynchronous writes
issued inside status callbacks on Wine's existing per-request task queue.
Writes from SENDREQUEST_COMPLETE or WRITE_COMPLETE run after the active queued
callback unwinds, allowing the SDK to advance its offset first. Synchronous
writes and asynchronous writes outside callbacks retain their existing path.
Existing task ownership, cancellation and error delivery are reused.

The standalone builder already discovers these patches. The release runtime
profile explicitly includes the new patch and its digest. No helper,
authentication, TLS, launcher or graphics changes are part of this fix.

## Artifact identity

The live diagnosis used source base
`35fce7db3b56e209000ef18ecbd4f33d0be46070`, WineGDK revision
`b5d23b074cfd5e28e79acceaaefaf41a26ce6272` (Wine 11.8, x86_64), and game package
1.26.5203.0 on macOS 26.6.2 (MacBookPro18,4, 32 GiB). The compiled candidate
uses that same pinned Wine tree plus the retained patch. Its verified patched
tree is `841a0331d05e08428e13112f0115b6f66fab21dc`.

| Artifact | SHA-256 |
| --- | --- |
| Minecraft.Windows.exe | `4a92bfa3ce2428b40ee517b7c1125d9f6f79274382de03846351992663b2e2e4` |
| Installed xgameruntime.dll during diagnosis | `d6fae609ff6f81a7c0080ee041b15043e78d3cee03129259cff865ef5009190d` |
| Unpatched WinHTTP DLL | `823bf0745e6199e625e9560bc0db3856ed2730d2e34a719a49773a6c6dab0905` |
| Restored compiled candidate WinHTTP DLL | `c3a9e48025f6cce0421bbac92834c1a610c5734e2e2641bef6da516501973ded` |

## Validation and limits

`tests/run-winhttp-write-tests.py` compiles the native client, clones Wine into a
new output directory, and runs exact synthetic 307-byte and 61-byte POSTs over a
single loopback connection in a new prefix. No Microsoft services or account
helper are involved. It records candidate/client digests, compiler arguments,
individual client logs and wire-validation results under the output directory.
Only that new prefix's Wine server is stopped during cleanup.

Before the fix, the synchronous and async-outside-callback cases both passed.
The SDK-pattern case sent its first 307-byte body six times: 1,842 bytes, six
write completions, five nested completions. The server detected body bytes
before the next POST. This is the regression's required failing baseline.

The WinHTTP-only build passed. All three isolated candidate cases passed: two
exact POSTs per case; the SDK-pattern case reported one write/completion per
body and zero nested completions. Inverting the new condition in generated
source made that case fail while both controls passed. Restoring the reviewed
source, rebuilding, re-verifying its pinned patched tree, and running the fixture
again passed. The client compilation emits one unused-parameter warning from
upstream Wine's inline `fwide` in `msvcrt/wchar.h`.

Commands used from the checkout root (native commands ran sequentially under
`tools/qa_resource_guard.py`):

```sh
python3 tools/verify-wine-source.py --source build/standalone-wine/source \
  --output build/party-debug/winhttp-candidate-source.json
python3 tools/qa_resource_guard.py --log build/party-debug/winhttp-before-final-run.log -- \
  python3 tests/run-winhttp-write-tests.py \
  --winhttp runtime/standalone/wine/lib/wine/x86_64-windows/winhttp.dll \
  --output build/party-debug/winhttp-before-final
python3 tools/qa_resource_guard.py --log build/party-debug/winhttp-candidate-build.log -- \
  env PATH="$PWD/build/standalone-wine/toolbin:/opt/homebrew/opt/llvm/bin:/usr/bin:/bin" \
  make -C build/standalone-wine -j2 dlls/winhttp/all
python3 tools/qa_resource_guard.py --log build/party-debug/winhttp-candidate-final-run.log -- \
  python3 tests/run-winhttp-write-tests.py \
  --winhttp build/standalone-wine/dlls/winhttp/x86_64-windows/winhttp.dll \
  --output build/party-debug/winhttp-candidate-final
```

The before command deliberately exits 1 for the reproduced defect. Each output
directory must be new. The private mutation controller was
`python3 build/party-debug/check-write-mutation.py`, also guarded; it inverted
`!request->hdr.recursion_count`, built/tested, restored source in `finally`,
rebuilt, verified the source receipt, and retested. Generated controllers and
logs stay outside the public source export.

Offline source validation passed: `tools/bootstrap-sources.py --check`, the
271-file exporter/inventory checks, changed-document link checks and
`git diff --check`. The full Python suite passed **383 tests** from the explicit
source-only export:

```sh
python3 tools/export-source.py build/party-debug/pr-source-check
python3 tools/qa_resource_guard.py --log build/party-debug/pr-export-python-tests.log -- \
  python3 -m unittest discover -s build/party-debug/pr-source-check/tests -p 'test_*.py'
```

The first full-suite run in the development checkout ran 383 tests and failed
only the unchanged `test_status_does_not_install_or_launch`: it mocks
`installed()` to false but leaves ROOT pointing at the real, existing game,
so the worker correctly reports `update` instead of its expected `new`. The
clean export contains no game and passes. No launcher behavior or unrelated
fixture was changed to hide that checkout-specific result. Installed WinHTTP
and account-helper hashes matched their pre-change values after validation.

The temporary probe's live success does not qualify the compiled DLL in
Minecraft. Restart, party recreate/leave, invite reception, party joining and
friend-world joining still require deliberate game acceptance of that artifact.
No rebuilt runtime, helper or app was installed for this source change.
