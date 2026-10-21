# Synthetic ARM batch experiments

Historical development notes. These commands and observations refer to the
source runtime described in each entry. They do not establish a packaged-app
result or authorize staging into an active installation. See the
[research index](README.md) and [current release gates](../RELEASE.md).

## M4 architecture experiments, October 6

The next investigation targeted the actual M4 Pro: eight performance cores,
four efficiency cores, 24 GiB memory and 128-byte cache lines. A standalone
Rosetta client now sends retained AABB visibility batches to an ARM64 companion
through shared memory and semaphores. Both binaries use identical strict-float
source; 64 fixtures of 65,536 boxes match exactly, including malformed and
boundary inputs. This code has no game hook or runtime integration.

The final 11-pair run measured 43.13 versus 21.45 microseconds for 4,096 boxes,
and 180.77 versus 65.95 microseconds for 16,384, including communication. Batches
of 64 and 256 lost; the 1,024-box result changed sign between runs. These are
elapsed batch times, not aggregate CPU or FPS. Geometry extraction, updates,
draw submission and GPU execution are excluded. Visibility alone saves too
little absolute time to explain a large improvement in the measured game.
Commands and limitations are in [the testing guide](../TESTING.md).
An additional AVX2-targeted Rosetta versus Apple-M4-targeted ARM comparison
preserved the large-batch advantage. AVX2 did not improve this x86 kernel;
compiler target flags alone were not a demonstrated optimization. The stronger
original x86 baseline remains the appropriate comparison for the numbers above.

Two other isolated implementations were rejected for runtime integration:

- Padding 1,088-byte binding strides to 1,152 removed adjacent-worker cache-line
  overlap but produced approximately zero median combined improvement. Its
  larger working set and 16 game patch sites are not justified by these tests.
- Interning repeated binding records reduced synthetic producer-plus-consumer
  time by 14.6–23.9%, but unique records regressed 14.3–18.4%. Recycling/fusing
  clone construction also failed to establish a substantial parallel gain.

The larger remaining hypothesis is to retain unchanged chunk draw packets
before their per-frame reconstruction, then replay them through Metal indirect
command buffers. Game payloads demonstrably mutate before cloning, and a stable
chunk identity plus complete invalidation/lifetime contract is still missing.
Exact-byte recurrence instrumentation can measure potential reuse; recurrence
alone cannot authorize caching. No retained-packet FPS improvement or production
change is claimed. Sanitized results are in
[m4-architecture-results.json](m4-architecture-results.json).

The next measurement tool is built: an opt-in clone-recurrence overlay on the
frame-slab candidate. It calls each original constructor once, observes only
after success and preserves its return/exception behavior. Three selected
callsites have separate 32-entry caches per registered thread, with 2,048-byte
payload limits, approximately 1/64 sampling and a 65,536-call per-thread cap.
Only numeric counters are exported. A fresh separate control mapping starts
disarmed; the normal runtime and launch settings are unchanged.

The overlay and native controller source are retained in
`patches/experimental-bedrock-clone-recurrence.patch` and
`experiments/clone-recurrence-control.c`. The overlay applies **after** the generated exact
frame-slab adapter/manifest in its isolated source tree; it is not a patch for
unmodified upstream Wine and no install command is provided. Build the control
tool with that source directory as its include path, then use
`recurrence-control <control-file> status|arm|stop`. The optional game flags are
`BEDROCK_CLONE_RECURRENCE=1` and a different fresh DOS path in
`BEDROCK_CLONE_RECURRENCE_CONTROL`, alongside the existing frame-slab gates.
CHUNK=0 avoids allocating slabs but leaves frame clocks unknown.

The candidate passed sanitizer, calling-convention, actual private Windows SEH,
shared-mapping and negative executable tests, plus the existing frame-slab
sentinel. Review found and fixed attribution of unrelated frame leases: clocks
now require clone-token equality.

On October 7 the observer ran in the isolated copied world after a normal game
quit and guarded runtime replacement. A bounded 20-second capture recorded
592,545 calls inside verified workers, zero ABI mismatches and zero exceptions.
At the dominant site, 8,862 of 8,902 sampled 528-byte payloads and their metadata
matched an earlier entry; 1,823 matches crossed known frame/scope clocks. The
seed site recorded 155 matches among 189 samples; the third site did not run.
These are sampled cache-window observations, not an unbiased reuse percentage
for every call. The observer then stopped and slabs returned to OFF with all
203 registered scopes retired and zero reserved bytes.

The capture ran while the game was occluded, so it establishes recurrence only.
Foreground FPS attempts failed preflight as focus moved to other applications.
A later attempt held foreground focus but still displayed about 10 frames/s;
no comparison phases ran in that session. Native control subsequently recovered
after the Codex restart, enabling the foreground slab comparison above. No
permission restriction was bypassed. Post-exit decoding of the older clone
session found 512 admitted thread slots and 511 overflow admissions; its bounded
clone observations must not be described as complete process coverage.

Snapshots are coherent per thread, not across the process. Stopping can leave
up to 255 outside-worker observations unpublished per thread. Sampling, the
small cache and independent worker histories can miss reusable state; do not
scale hit rates by 64 or infer that low counts disprove reuse. Observation adds
overhead and is unsuitable for performance comparison. This is an eligibility
probe, not a retained-packet implementation or a proven game optimization.


A separate binding-recurrence profile now measures the three 1,044-byte copy
sites directly. Its source is in
`patches/experimental-bedrock-binding-recurrence.patch`, with native controller
`experiments/binding-recurrence-control.c`. Apply this overlay after the exact frame-slab
adapter/manifest; do not combine it with the clone overlay. It preserves each
original copy and its return/exception behavior, then observes destination bytes.
The original 1,088-byte stride and unused tail remain unchanged.

Each admitted thread has one shared 32-entry history across all three sites and
a total 16,384-call budget. The original cached hash filters candidates; full
1,044-byte equality is required. Counters distinguish historical and consecutive
matches, including opaque source-address equality. They expose no addresses or
payloads. Source equality does not prove encoder identity or resource ownership.
The numeric mapping starts disarmed; stop/arm does not replenish the budget.

Build the native controller against the overlay's headers and use
`binding-control <control-file> status|arm|stop`. An isolated launch requires
`BEDROCK_BINDING_RECURRENCE=1`, a fresh separate DOS path in
`BEDROCK_BINDING_RECURRENCE_CONTROL`, clone recurrence off, and the existing
frame-slab gates. These settings passed the October 7 real-game launch below.
The mapping omits thread-admission counters: captured totals cover admitted
threads only. Decode the separate frame-control registered/overflow thread counts
after normal exit alongside captures; the earlier long-running slab session
exhausted its slots.

Native sanitizer, Rosetta calling-convention and actual Windows SEH fixtures
passed, including every single-byte mutation, forced hash collisions, shared
history, 4,096 differential copies, unchanged tail canaries and the call cap.
The new DLL also passed the frame sentinel in its own private runtime and
rejected unsupported executables and conflicting observer flags. Run the
portable content contract with
`python3 -m unittest discover -s tests -p 'test_bedrock_binding_recurrence.py'`.


The binding observer then completed a nine-second capture in the private
copied world. Nine published threads each reached the 16,384-call cap within
three seconds: 147,456 copies total, all at site0. Of these, 145,881 (98.93%)
matched recent full contents and 145,539 (98.70%) matched the preceding copy.
There were no unexpected sizes, ABI mismatches, exceptions or observed hash
collisions. Site1/site2 did not execute and remain unqualified in gameplay.

The real binding mapping and guarded site0 hook are now exercised. After normal
exit, the separate frame mapping showed 188 registered threads and zero overflow
admissions. These are bounded admitted-thread windows, not an unbiased all-game
reuse rate. All original copies still execute: neither resource ownership nor
safe alias lifetime follows from equal bytes. The observer was disarmed during
performance tests and stopped before save/quit; the normal runtime is unchanged.
