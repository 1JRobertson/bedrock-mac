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
The route selects the original `https://pocket.realms.minecraft.net/` XSTS audience
for the current Realms API hosts. Token issuance and access remain server checked.

Logs are written to `build/standalone-wine/xuser-*-test.log`. These parser tests
do not prove account access or multiplayer connectivity. The separate
`runtime-privilege-probe` checks the signed-in runtime, and the game must still
complete its normal online handshake.
