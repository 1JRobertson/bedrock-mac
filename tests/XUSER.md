The XUser tests compile against the actual private Wine headers installed by
the standalone patches. They use synthetic claims and URLs, require no account,
and run in `runtime/standalone-wine-prefix`, separate from the game bottle.

After building standalone Wine, run from the client directory:

```sh
bash tests/run-xuser-tests.sh
```

`xuser-claims.c` checks exact privilege membership, genuine denial, missing and
malformed claims, integer overflow, token expiry, and strict UTC expiry parsing.
`xuser-realms.c` checks the three exact HTTPS Realms hosts, case and port handling,
and rejects lookalike hosts and hostnames embedded in paths, queries, or userinfo.
`xuser-refresh.c` checks expiry boundaries, proactive renewal, audience changes,
and forced renewal against the runtime's actual cache-decision functions.
The route selects the original `https://pocket.realms.minecraft.net/` XSTS audience
for the current Realms API hosts. Token issuance and access remain server checked.

Logs are written to `build/standalone-wine/xuser-*-test.log`. These parser tests
do not prove account access or multiplayer connectivity. The separate
`runtime-privilege-probe` checks the signed-in runtime, and the game must still
complete its normal online handshake.

After building a candidate runtime, the signed-in account can also test actual
refresh requests without changing the installed runtime or running game:

```sh
bash tests/run-xuser-refresh-live.sh
```

This uses an APFS clone under `build/standalone-wine/refresh-runtime` and the
separate `runtime/standalone-refresh-prefix`. It requires the existing helper,
owned game metadata, and local Microsoft threading DLL. The probe generates its
private structure layout from the candidate source and only expires timestamps
inside its own process. It then verifies normal cache reuse, forced XSTS renewal,
expired XSTS renewal, silent parent-token renewal, and policy/age renewal through
the public APIs. All replacement tokens and permissions come from the services;
the system clock and game process are untouched. It prints booleans and status
codes only. Logs stay under `build/standalone-wine/refresh-probes`.

`bash tests/run-xuser-rta-live.sh` checks an authenticated RTA WebSocket and
subscribes to the normal MPSD `/connections/` resource in the isolated candidate
runtime. A real `ConnectionId` response is required; a normal WebSocket close
is a failure. The socket closes immediately after the check. This reproduced
the original user-only authentication failure (close code 1000), and passed
after forwarding the helper's real device RPS token and obtaining signed Xbox
device/title tokens. It does not establish that a game world loaded.
