# NOVA v0.0.72 — Phase 3: JIT block chaining (SHIPPED)

Date: 2026-11-04. Commissioned by Sean 2026-11-04 16:20 ET
("Start the block-chaining optimization"). Design:
agent_notes/v072-chain-design.md. This note is the delivery
record.

## What shipped

NovaJIT.swift only (both copies byte-identical, blob f7015ade).
Compiled blocks now transfer control directly to an already-
compiled successor instead of returning to the Swift trampoline
per block:

- Per-site **chain stubs** for the chainable exits (JMP, JMP32,
  BZ, BNZ, BEQ, BNE, CALL, CALL32 — both exits of the two-exit
  forms — CALLI/RET/JMPI dynamic, LOOP, and the 64-instruction
  cap fallthrough). The target pc travels in x9; the stub checks
  a 48-byte **link-table** slot (entry / target / insnCount /
  generation / endFlags), settles the finished block's accounts
  (cycle, runDelta, stepsUsed mirror, timer-countdown mirror),
  computes the successor's §5.3 limit exactly as the trampoline
  would, and `br`s to the successor's chained entry (just after
  its prologue).
- **Generation-epoch invalidation**: flushCache bumps the link
  generation, so every cache-flushing event (J1 self-modifying
  stores, J4 faults, J5 single-steps, J2 DSPSET/CSPSET, J7 pool
  recycle) instantly stales all links. No link can reach stale
  or recycled code.
- **Pass-through linking**: a chain miss exits .next to the
  trampoline exactly as v0.0.71 did, and the trampoline fills
  the site's slot afterwards — hot edges link within a few
  traversals, no separate profiling pass.
- **Chain cap** 128 blocks per trampoline segment (§5.5
  stop-flag parity), then an ordinary .next exit.
- Exactness machinery: the fold now reports
  lastDelta = runDelta + x20 (whole segment total), so the
  trampoline's timer/budget settle is unchanged in effect; the
  stub maintains mirrors of stepsUsed and the timer countdown
  so chained blocks get the identical limit/limitReason a
  dispatch would have given them; state.exitEndFlags always
  names the block that actually exited, so the trampoline's
  .next handling (flush / re-dispatch / single-step) is
  v0.0.71-exact even mid-chain.

Left on the trampoline path by design: DSPSET/CSPSET exits
(they flush the cache after executing, rule J2), CSRSET and
MRET exits (status writers — the successor's entry conditions
belong to the trampoline), WFI, the non-cap foreign-instruction
fallthrough (the trampoline must single-step it), all faults,
limit exits, MMIO peeks, helper callouts and bails (unchanged
from v0.0.71), plus any not-yet-linked or stale-generation
edge. The v0.0.70 interpreter, the engine probe, silent
fallback, the "Halted — JIT / Halted — Interpreter" status
line, and the D3 console callout are all untouched.

## Gate (final shipped head 7694d4a9)

- Plain gate (interpreter), run 41919098792: 9/9 PASS.
- gate-variant vm-app/NovaVM/VM (shipped JIT), run 41919111133:
  9/9 PASS, engine_active=jit(path: wxTransition) on every
  case, singleSteps=0 on all goldens, **selfmod
  invalidations=2** (identical to v0.0.71), console bytes +
  cycle counts + halt reasons identical under both engines.
- Variant-lane gate at 61fa8533, run 41917366880: also 9/9
  (selfmod invalidations=2) before promotion; the promoted app
  file is the same blob.

## Speed (CI host macos-26-arm64, best of 5, speed-all run 41917385179)

| | v0.0.71 JIT | v0.0.72 chained JIT | v0.0.70 interpreter |
|---|---|---|---|
| bench | 50,514,754 ips | **390,663,255 ips** | 215,558,619 ips |
| galaxy | 2,803,663 ips | **8,346,225 ips** | 7,827,588 ips |

(baseline columns from the v0.0.71 record, run 41901995849;
the chained column is run 41917385179, where the same host
measured the interpreter at 244,591,306 / 10,009,265 ips —
host-to-host variance. On that like-for-like host the chained
JIT is 1.60× the interpreter on bench and 0.83× on galaxy.)

bench is 7.7× the v0.0.71 JIT and now beats the interpreter;
galaxy is 3.0× the v0.0.71 JIT (galaxy remains print-bound —
most of its time is console MMIO, which chaining cannot
remove).

## Delivery

- IPA: NovaVM-v0.0.72.ipa, 1,191,906 bytes, md5
  1623920bed669634b7dbdbd32fcf0a83, staged at
  ~/workspace/your_files/. Verified from the IPA's own
  Info.plist: bundle id com.nova.vm, CFBundleShortVersionString
  0.0.72, UIFileSharingEnabled true. Build run 41919319576 at
  head 7694d4a9.
- Repo: nova-cpu main 7694d4a9 (tree 8f890543, tree-verified);
  chaining commit 61fa8533 (variant + design note), promotion
  commit 7694d4a9 (app copy + version bump). This note lands in
  a follow-up notes commit; the gates above ran on 7694d4a9,
  whose code is identical to the note commit's.
- Device proof still owed by Sean (same as v0.0.71): status
  line reads "Halted — JIT" under StikDebug attach,
  "Halted — Interpreter" without; bench.bin for true iPad
  rates. CI numbers are macOS host claims only.

## Out of scope, unchanged (Sean's separate calls)

- File-MMIO exclusivity bug in the interpreter path (Phase 2
  flag) — not touched.
- DIV/REM of INT64_MIN/−1 host trap — not touched; the JIT
  still bails that operand pair to step(), preserving the
  interpreter's behaviour exactly.
