# NOVA v0.0.70 — Phase 1 optimization summary (FINAL)

Date: 2026-11-04. Release: v0.0.70. This note records the whole Phase 1
pass: the V1 core/app optimizations, the variant measurement round, and
the promotion of the winning variant into the shipping core.

---

## 1. V1 changes (landed before the variant round)

### VM core (`vm-app/NovaVM/VM/NovaMemory.swift`, `NovaCPU.swift`) — lane OPT-CORE

- **Memory fast path:** `read16/32/64` / `write16/32/64` (and the
  `read8/write8` guards) went from a three-part guard plus up to 8
  individually bounds-checked byte accesses to **one comparison per
  access** (`addr <= totalSize - n`, precomputed as
  `maxStart16/32/64` in `init`) followed by a single constant-size
  `memcpy`. Range equivalence with the old guard was model-checked
  exhaustively over boundary addresses plus 200k random addresses per
  size; fault behaviour, atomicity, little-endian byte order and MMIO
  routing are unchanged. The private `checkRead/checkWrite` helpers
  were removed (zero remaining references); no public/internal
  signature changed.
- **Fetch/dispatch:** `step()` resolves `let mem: NovaMemory = memory`
  once at the top; the timer check, opcode fetch and all 51 `memory.`
  accesses go through that one reference instead of re-unwrapping the
  implicitly-unwrapped property per access. The switch, per-case
  `pc &+=` amounts, `tval` assignments, trap vectors, MMIO range tests
  and the one-cycle-per-instruction accounting are unchanged.
- **Bulk host↔guest helpers:** `NovaMemory` gained
  `storeHostBytes(_:at:)` (both `[UInt8]` and `Data` forms) and
  `loadHostBytes(from:count:)`, reproducing the old byte-at-a-time
  MMIO payload loops exactly (in-RAM prefix copied, out-of-RAM bytes
  silently dropped, never routed to `mmioWrite`), for the app lane's
  file/net handlers to adopt.

### Console batching (`NovaVMEngine.swift`) — lane OPT-APP

- Before: every console character scheduled its own
  `DispatchQueue.main.async { consoleText += s; cap-check }` — one
  main-thread hop and one SwiftUI publish per character, each publish
  triggering a full-string ANSI re-render (O(n²) per screenful).
- After: `consoleOutput` calls `enqueueConsole(_:)` on the VM thread,
  which appends to a non-published `consoleBuffer` under an `NSLock`.
  `flushConsoleBuffer()` publishes the whole buffer in one
  `consoleText += chunk` on the main queue. Flush triggers: a timer
  every **100 ms** (`consoleFlushInterval = 0.1`), or immediately when
  the buffer reaches **16,384 characters**
  (`consoleFlushThreshold`); an ASAP-pending flag coalesces repeat
  requests, and halt/stop paths flush before clearing.
- **Exact cap simulation:** the 100,000 / 90,000 cap rule produces
  byte-identical final console text to the old per-character path.
  Instead of simulating per character, the flush computes the final
  keep-count with pure integer arithmetic
  (`cappedConsoleLength(existing:appending:)` — repeat
  "if count > 100,000 drop to suffix 90,000" in O(number of trims)),
  verified against the per-character reference on cap-boundary cases
  (99,999+4,096; 90,000+10,001/10,002; 100,000+1; 0+250,000;
  50,000+3×60,000) plus 300 randomized cases.

### Version bump

- `MARKETING_VERSION` 1.0 → **0.0.70** in both build configurations of
  `vm-app/NovaVM.xcodeproj/project.pbxproj` (this is the version the
  built IPA actually carries, since the project generates its
  Info.plist), and `CFBundleShortVersionString` 0.0.6 → **0.0.70** in
  the physical `vm-app/NovaVM/Info.plist` so the repo no longer
  misreports the version even though that file is currently orphaned.

### Deliberately unchanged: the `applyConfig` allocation peak

`applyConfig` still allocates the new `NovaMemory` before releasing
the old one (transient old+new peak, up to ~2 GB at the 1 GB setting).
**Left unchanged because a drop-first restructure is not provably
safe: `applyConfig` swaps memory live while the VM may be running —
`memory` is a non-optional var and `cpu.memory` is dereferenced
continuously by the VM thread, so dropping first would need a
placeholder instance plus a behaviour change and a device test.**

---

## 2. Variant measurement round

All variants were built on the V1 core and measured in harness
`speed-all` run **41873106273** (instructions/sec; bench and galaxy):

| Variant | bench ips | galaxy ips |
|---|---|---|
| baseline (pre-V1 snapshot) | 12,862,467 | 4,990,021 |
| current (V1, shipped before this promotion) | 13,542,521 | 5,290,933 |
| dispatch | 27,606,832 | 6,597,381 |
| **hotloop** | **252,384,105** | **9,307,316** |
| predecode | 17,501,584 | 3,608,612 |

Golden-gate runs — **all variants passed all 9 goldens, including
selfmod**:

| Variant | Gate run |
|---|---|
| current (V1) | 41879611979 |
| dispatch | 41874588943 |
| predecode | 41880721411 |
| hotloop | 41883442168 |

Headline gains for the promoted core vs the pre-Phase-1 baseline:
bench ≈ 19.6×, galaxy ≈ 1.87×.

---

## 3. Promotion decision

**PROMOTED: hotloop.** Fastest on both workloads by a wide margin, with
exact cycle counts everywhere, including bench at exactly 50,476,369
cycles. Its design: `run()` drives a non-throwing hot loop
(`hotRun`) that holds all hot CPU state in locals for the whole run,
accesses guest RAM through `NovaMemory.withHotBuffer` (the one method
hotloop's memory adds over V1) with each checked accessor's own range
comparison reproduced before every raw access, syncs object state on
every exit and every 8192 instructions, caches the timer fields in
locals with flush/reload around MMIO, and executes the one bail opcode
(ROLL, 0x0F) through the unchanged throwing `step()`. The public
`step()` itself is verbatim V1.

Promotion (this commit): `tools/harness/variants/hotloop/NovaCPU.swift`
→ `vm-app/NovaVM/VM/NovaCPU.swift` and
`tools/harness/variants/hotloop/NovaMemory.swift` →
`vm-app/NovaVM/VM/NovaMemory.swift`, byte-identical copies. Diff of the
promoted files against the previous shipping (V1) files is exactly the
variant delta and nothing else:

- `NovaCPU.swift` (520 → 1294 lines): variant banner comment; one
  added section (763 lines: `HotOutcome`, `handleTrapAfterStep` —
  V1 run()'s catch block factored out verbatim — and `hotRun`);
  `run()` rewritten to drive `hotRun` with identical trap handling and
  step accounting. `step()` untouched.
- `NovaMemory.swift` (447 → 486 lines): variant banner comment; one
  added method, `withHotBuffer`, plus its safety comment. Nothing else.

**REJECTED: dispatch.** Dominated by hotloop on both workloads (bench
27.6M vs 252.4M ips; galaxy 6.60M vs 9.31M ips), and it showed an
unexplained 23-cycle bench divergence (50,476,346 cycles vs the exact
50,476,369) — noted, not promoted.

**REJECTED: predecode.** Dominated by hotloop on both workloads, and
its galaxy ips (3,608,612) regress **below V1** (5,290,933) because
MMIO stores force cache flushes in its predecoded representation.

---

## 4. DIAG findings: two pre-existing example-program bugs (not core bugs)

The DIAG pass over the goldens found two bugs in the example
**programs**, not in the VM core; the core executes both exactly as
written, and the goldens pin the as-written behaviour:

- **fib.nova** — an argument bug around `ENTER`/`STORL`: the program
  passes/stores a value with the wrong argument arrangement, so it
  computes with the operand it actually supplied, not the one its
  author intended.
- **examples galaxy template** — a stray `SWAP` in the template source
  exchanges the top two stack values once more than intended; the
  generated program runs with the swapped order.

Both are program bugs to fix in the program sources if desired; no
core change is warranted, and neither affects the v0.0.70 gate.

---

## 5. What ships in v0.0.70

- V1 core fast paths + console batching + version bump (already on
  `main` before this commit).
- The hotloop core, promoted verbatim by this commit.
- This summary note.
